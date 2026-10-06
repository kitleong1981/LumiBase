import Foundation
import AppKit
import CoreImage
import ImageIO

private final class CameraPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class CameraNativeCache: @unchecked Sendable {
    // NSCache is thread-safe; mutation is additionally confined to nativeQueue.
    let images = NSCache<NSString, NSImage>()
    init() { images.countLimit = 2; images.totalCostLimit = 512 * 1024 * 1024 }
}

/// High-performance thumbnail extractor utilizing ImageIO embedded JPEG previews
public actor ThumbnailLoader {
    public static let shared = ThumbnailLoader()
    
    private let cache = ThumbnailCacheManager.shared
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    // ImageIO may synchronously wait for RawCamera's own dispatch work. Running
    // many such calls on Swift's cooperative pool can starve that work and every
    // pending foreground load. A serial GCD queue bounds blocking decodes to one;
    // callers suspend at a continuation rather than occupying cooperative workers.
    private nonisolated static let decodeQueue = DispatchQueue(
        label: "com.lumibase.thumbnail.decode", qos: .userInitiated)
    private nonisolated static let renderContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Returns only an already resident thumbnail; safe for the synchronous selection handoff.
    public nonisolated static func cachedMemoryThumbnail(for asset: PhotoAsset, maxPixelSize: Int = 1600) -> NSImage? {
        let cache = ThumbnailCacheManager.shared
        return cache.memoryImage(forKey: cacheKey(for: asset, maxPixelSize: maxPixelSize))
    }

    /// The single key path used by insertion/loading and synchronous handoff.
    static func cacheKey(for asset: PhotoAsset, maxPixelSize: Int) -> String {
        ThumbnailCacheManager.shared.cacheKey(for: asset.fileURL, maxPixelSize: maxPixelSize,
            dateModified: asset.dateModified, developTag: "highlights-1.6.2|" + asset.xmp.thumbnailDevelopCacheIdentity)
    }
    
    /// Loads a thumbnail asynchronously with memory/disk caching and request deduplication
    public func loadThumbnail(for asset: PhotoAsset, maxPixelSize: Int = 400) async -> NSImage? {
        let key = Self.cacheKey(for: asset, maxPixelSize: maxPixelSize)
        
        // Check cache first
        if let cached = cache.image(forKey: key) {
            return cached
        }
        
        // Deduplicate in-flight requests
        if let existingTask = inFlightTasks[key] {
            return await existingTask.value
        }
        
        let targetAsset = asset
        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            await withCheckedContinuation { continuation in
                Self.decodeQueue.async {
                    let image = autoreleasepool {
                        Self.createThumbnail(for: targetAsset, maxPixelSize: maxPixelSize)
                    }
                    continuation.resume(returning: image)
                }
            }
        }
        
        inFlightTasks[key] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: key)
        
        if let thumbnail = result {
            cache.store(image: thumbnail, forKey: key)
        }
        
        return result
    }
    
    /// Camera-preview-only path. RAW never uses CreateThumbnailFromImageAlways or a
    /// CIRAWFilter fallback: absence of an embedded JPEG is an explicit unavailable state.
    public func loadCameraPreview(for asset: PhotoAsset, maxPixelSize: Int = 1600) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let versions = ([asset.fileURL] + asset.companionURLs).map { url in
            // URL.resourceValues can retain an old stat across in-place companion edits.
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (info?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(url.standardizedFileURL.path):\(modified):\(size)"
        }.joined(separator: "|")
        let key = cache.cacheKey(for: asset.fileURL, maxPixelSize: maxPixelSize,
            dateModified: asset.dateModified, developTag: "camera-jpeg-only-v2|" + versions)
        if let image = cache.image(forKey: key) { return image }
        let cancellation = CameraPreviewCancellation()
        let image: NSImage? = await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            Self.decodeQueue.async {
                guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                let result: NSImage? = autoreleasepool {
                    func extract(_ url: URL, embeddedOnly: Bool) -> NSImage? {
                        let options: [CFString: Any] = [
                            kCGImageSourceShouldCache: false,
                            kCGImageSourceCreateThumbnailFromImageAlways: !embeddedOnly,
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                    if let embedded = extract(asset.fileURL, embeddedOnly: asset.isRaw) { return embedded }
                    // FolderScanner's pair plus matching basename is required. Arbitrary
                    // neighboring JPEGs cannot stand in for a missing RAW preview.
                    for url in asset.companionURLs where ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) &&
                        url.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent &&
                        url.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent() {
                        if let image = extract(url, embeddedOnly: false) { return image }
                    }
                    return nil
                }
                continuation.resume(returning: result)
            }
          }
        } onCancel: { cancellation.cancel() }
        guard !Task.isCancelled else { return nil }
        if let image { cache.store(image: image, forKey: key) }
        return image
    }

    // Native camera pixels have a separate bounded memory-only cache and queue:
    // foreground inspection must not sit behind hundreds of grid thumbnails.
    private nonisolated static let nativeQueue = DispatchQueue(label: "com.lumibase.camera.native", qos: .userInitiated)
    private nonisolated static let nativeCache = CameraNativeCache()

    /// Native JPEG pixels only. Prefer the scanner's matching companion. An
    /// embedded preview is accepted only if it matches the source dimensions;
    /// a 1600px proxy is never advertised as native and RAW is never decoded.
    public func loadNativeCameraJPEG(for asset: PhotoAsset) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let cancellation = CameraPreviewCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.nativeQueue.async {
                    let image: NSImage? = autoreleasepool {
                        guard !cancellation.isCancelled else { return nil }
                        let companions = asset.companionURLs.filter {
                            ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) &&
                            $0.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent &&
                            $0.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent()
                        }
                        for url in companions + [asset.fileURL] {
                            guard !cancellation.isCancelled else { return nil }
                            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
                            let key = "native-jpeg-v1|\(url.path)|\((info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(info?[.size] as? NSNumber ?? 0)" as NSString
                            if let cached = Self.nativeCache.images.object(forKey: key) { return cached }
                            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                                  let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { continue }
                            let embeddedOnly = url == asset.fileURL && asset.isRaw
                            let options: [CFString: Any] = [
                                kCGImageSourceShouldCacheImmediately: true,
                                kCGImageSourceCreateThumbnailFromImageAlways: !embeddedOnly,
                                kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
                            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                                  max(cg.width, cg.height) == max(width, height),
                                  min(cg.width, cg.height) == min(width, height), !cancellation.isCancelled else { continue }
                            let result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                            Self.nativeCache.images.setObject(result, forKey: key, cost: cg.bytesPerRow * cg.height)
                            return result
                        }
                        return nil
                    }
                    continuation.resume(returning: cancellation.isCancelled ? nil : image)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Synchronously creates a thumbnail from disk using CIRAWFilter draft mode (for exact preview match) or ImageIO
    private nonisolated static func createThumbnail(for asset: PhotoAsset, maxPixelSize: Int) -> NSImage? {
        // 1. For RAW assets with develop edits, use CIRAWFilter draft mode to get identical color science as Loupe View
        if asset.isRaw && asset.xmp.hasDevelopEdits {
            if let rawFilter = CIRAWFilter(imageURL: asset.fileURL) {
                rawFilter.isDraftModeEnabled = true
                if let baseCI = rawFilter.outputImage {
                    let processed = AdobeColorPipeline.shared.process(
                        image: baseCI,
                        cameraModel: asset.cameraMetadata.model,
                        xmp: asset.xmp
                    )
                    let extent = processed.extent
                    let maxDim = max(extent.width, extent.height)
                    let scale = maxDim > CGFloat(maxPixelSize) ? CGFloat(maxPixelSize) / maxDim : 1.0
                    let scaledCI = scale < 1.0 ? processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : processed
                    
                    if let renderedCG = Self.renderContext.createCGImage(scaledCI, from: scaledCI.extent) {
                        let size = NSSize(width: renderedCG.width, height: renderedCG.height)
                        return NSImage(cgImage: renderedCG, size: size)
                    }
                }
            }
            // An edited RAW may display only a completed processed render. Never relabel its
            // embedded, unedited JPEG as though it reflected the active develop settings.
            return nil
        }
        
        // 2. Standard fast path using ImageIO embedded preview
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}
