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

private final class CameraReadyFrame: NSObject {
    let image: NSImage
    let sourceVersion: String
    let fullExtent: CGRect
    private var observers: [DispatchSourceFileSystemObject] = []
    init(image: NSImage, sourceVersion: String, fullExtent: CGRect, urls: [URL], invalidate: @escaping @Sendable () -> Void) {
        self.image = image; self.sourceVersion = sourceVersion; self.fullExtent = fullExtent
        for url in urls {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: invalidate)
            source.setCancelHandler { close(descriptor) }
            observers.append(source); source.resume()
        }
    }
    deinit { observers.forEach { $0.cancel() } }
}

/// Only small camera proxies; no native neighbor pixels. Identity uses immutable scan metadata.
private final class CameraReadyCache: @unchecked Sendable {
    let frames = CameraReadyMemory()
}

/// Hard bounds rather than NSCache's advisory eviction; resident warm proxies are
/// deterministic even when the separate large native cache triggers memory pressure.
private final class CameraReadyMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NSString: (frame: CameraReadyFrame, cost: Int)] = [:]
    private var order: [NSString] = []
    private var bytes = 0
    func object(forKey key: NSString) -> CameraReadyFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.frame
    }
    func removeObject(forKey key: NSString) {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost }
        order.removeAll { $0 == key }
    }
    func setObject(_ frame: CameraReadyFrame, forKey key: NSString, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
        order.removeAll { $0 == key }
        guard cost <= 96 * 1024 * 1024 else { return }
        entries[key] = (frame, cost); bytes += cost; order.append(key)
        while entries.count > 12 || bytes > 96 * 1024 * 1024 {
            let first = order.removeFirst()
            if let old = entries.removeValue(forKey: first) { bytes -= old.cost }
        }
    }
}

/// High-performance thumbnail extractor utilizing ImageIO embedded JPEG previews
public actor ThumbnailLoader {
    public static let shared = ThumbnailLoader()
    
    private let cache = ThumbnailCacheManager.shared
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]
    private var editedTail: Task<Void, Never>?

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
            dateModified: asset.dateModified, developTag: "accurate-library-v2|\(asset.fileSize)|\(NativeHighlightsService.isEnabled)|" + asset.xmp.thumbnailDevelopCacheIdentity)
    }
    
    /// Loads a thumbnail asynchronously with memory/disk caching and request deduplication
    public func loadThumbnail(for asset: PhotoAsset, maxPixelSize: Int = 400) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
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
        let predecessor = asset.xmp.hasDevelopEdits ? editedTail : nil
        let cancellation = CameraPreviewCancellation()
        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            if targetAsset.xmp.hasDevelopEdits {
                // Logical serial queue: queued cancelled cells skip RAW preparation entirely.
                await predecessor?.value
                guard !cancellation.isCancelled else { return nil }
                guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: targetAsset.fileURL,
                    xmp: targetAsset.xmp, useSharedCache: false, priority: .utility),
                    !cancellation.isCancelled else { return nil }
                return await withCheckedContinuation { continuation in
                    Self.decodeQueue.async {
                        let image: NSImage? = autoreleasepool {
                            guard let processed = RAWImageLoader.shared.renderProcessed(baseHolder: holder,
                                cameraModel: targetAsset.cameraMetadata.model, xmp: targetAsset.xmp,
                                isCurrent: { !cancellation.isCancelled }),
                                let cg = processed.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                            let scale = min(1, Double(maxPixelSize) / Double(max(cg.width, cg.height)))
                            let width = max(1, Int(Double(cg.width) * scale)), height = max(1, Int(Double(cg.height) * scale))
                            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                            context.interpolationQuality = .high
                            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                            guard !cancellation.isCancelled, let result = context.makeImage() else { return nil }
                            return NSImage(cgImage: result, size: NSSize(width: width, height: height))
                        }
                        continuation.resume(returning: image)
                    }
                }
            }
            return await withCheckedContinuation { continuation in
                Self.decodeQueue.async {
                    let image = autoreleasepool {
                        guard !cancellation.isCancelled else { return nil as NSImage? }
                        return Self.createThumbnail(for: targetAsset, maxPixelSize: maxPixelSize)
                    }
                    continuation.resume(returning: image)
                }
            }
        }
        
        inFlightTasks[key] = task
        if asset.xmp.hasDevelopEdits { editedTail = Task { _ = await task.value } }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { cancellation.cancel() }
        inFlightTasks.removeValue(forKey: key)
        
        if let thumbnail = result {
            cache.store(image: thumbnail, forKey: key)
        }
        
        return result
    }
    
    private nonisolated static let cameraReady = CameraReadyCache()
    private nonisolated static func cameraReadyKey(_ asset: PhotoAsset, maxPixelSize: Int) -> NSString {
        "\(asset.id)|\(asset.dateModified.timeIntervalSinceReferenceDate)|\(asset.fileSize)|\(asset.companionURLs.map(\.path).joined(separator: "|"))|\(maxPixelSize)" as NSString
    }
    /// Body-safe: no stat, disk read, actor hop, RAW or native decode.
    public nonisolated static func readyCameraPreview(for asset: PhotoAsset, maxPixelSize: Int = 1600) -> NSImage? {
        cameraReady.frames.object(forKey: cameraReadyKey(asset, maxPixelSize: maxPixelSize))?.image
    }
    struct ReadyCameraGeometry {
        let image: NSImage
        let fullExtent: CGRect
    }
    nonisolated static func readyCameraGeometry(for asset: PhotoAsset, maxPixelSize: Int = 1600) -> ReadyCameraGeometry? {
        guard let frame = cameraReady.frames.object(forKey: cameraReadyKey(asset, maxPixelSize: maxPixelSize)) else { return nil }
        return ReadyCameraGeometry(image: frame.image, fullExtent: frame.fullExtent)
    }
    /// Resident source geometry travels with the same versioned, bounded proxy.
    public nonisolated static func readyCameraFullExtent(for asset: PhotoAsset, maxPixelSize: Int = 1600) -> CGRect {
        cameraReady.frames.object(forKey: cameraReadyKey(asset, maxPixelSize: maxPixelSize))?.fullExtent ?? .zero
    }
    /// Metadata only, on decodeQueue. Match native JPEG preference and orientation.
    private nonisolated static func cameraFullExtent(for asset: PhotoAsset) -> CGRect {
        let companions = asset.companionURLs.filter {
            ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) &&
            $0.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent &&
            $0.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent()
        }
        for url in companions + [asset.fileURL] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { continue }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            let swaps = (5...8).contains(orientation)
            return CGRect(x: 0, y: 0, width: swaps ? height : width, height: swaps ? width : height)
        }
        return .zero
    }
    private nonisolated static func publishCameraReady(_ image: NSImage, asset: PhotoAsset, maxPixelSize: Int, version: String) async {
        // The handoff LRU is for Loupe's 1600px proxies. Grid/filmstrip sizes use
        // their existing thumbnail cache and must not evict selected/native handoffs.
        guard maxPixelSize == 1600 else { return }
        let key = cameraReadyKey(asset, maxPixelSize: maxPixelSize)
        if let existing = cameraReady.frames.object(forKey: key), existing.sourceVersion == version, existing.image === image { return }
        let extent: CGRect = await withCheckedContinuation { continuation in
            decodeQueue.async { continuation.resume(returning: cameraFullExtent(for: asset)) }
        }
        guard !Task.isCancelled, cameraSourceVersion(for: asset) == version else { return }
        let frame = CameraReadyFrame(image: image, sourceVersion: version, fullExtent: extent, urls: [asset.fileURL] + asset.companionURLs) {
            cameraReady.frames.removeObject(forKey: key)
        }
        cameraReady.frames.setObject(frame, forKey: key, cost: Int(image.size.width * image.size.height * 4))
    }

    /// Camera-preview-only path. RAW never uses CreateThumbnailFromImageAlways or a
    /// CIRAWFilter fallback: absence of an embedded JPEG is an explicit unavailable state.
    private nonisolated static func cameraSourceVersion(for asset: PhotoAsset) -> String {
        ([asset.fileURL] + asset.companionURLs).map { url in
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = (info?[.size] as? NSNumber)?.int64Value ?? 0
            return "\(url.path):\(modified):\(size)"
        }.joined(separator: "|")
    }

    public func loadCameraPreview(for asset: PhotoAsset, maxPixelSize: Int = 1600) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let versions = Self.cameraSourceVersion(for: asset)
        let key = cache.cacheKey(for: asset.fileURL, maxPixelSize: maxPixelSize,
            dateModified: asset.dateModified, developTag: "camera-jpeg-only-v2|" + versions)
        let readyKey = Self.cameraReadyKey(asset, maxPixelSize: maxPixelSize)
        if let ready = Self.cameraReady.frames.object(forKey: readyKey), ready.sourceVersion != versions {
            Self.cameraReady.frames.removeObject(forKey: readyKey)
        }
        if let image = cache.image(forKey: key) {
            await Self.publishCameraReady(image, asset: asset, maxPixelSize: maxPixelSize, version: versions)
            return image
        }
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
        guard !Task.isCancelled, Self.cameraSourceVersion(for: asset) == versions else { return nil }
        if let image {
            cache.store(image: image, forKey: key)
            await Self.publishCameraReady(image, asset: asset, maxPixelSize: maxPixelSize, version: versions)
        }
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
        // Validate fresh source versions on the loader actor, then do a memory-only
        // hit before entering the serial decode queue (which may hold a cold decode).
        let companions = asset.companionURLs.filter {
            ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) &&
            $0.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent &&
            $0.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent()
        }
        for url in companions + [asset.fileURL] {
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = "native-jpeg-v1|\(url.path)|\((info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(info?[.size] as? NSNumber ?? 0)" as NSString
            if let cached = Self.nativeCache.images.object(forKey: key) { return Task.isCancelled ? nil : cached }
        }
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

    /// Selected-score-only utility path. Never queues on native presentation and
    /// never inserts a new full bitmap into the native cache. Caller owns its lifetime.
    nonisolated static func sharpnessCameraFullImage(for asset: PhotoAsset, isCurrent: () -> Bool) -> NSImage? {
        let companions = asset.companionURLs.filter {
            ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) &&
            $0.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent &&
            $0.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent()
        }
        for url in companions + [asset.fileURL] {
            guard isCurrent() else { return nil }
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = "native-jpeg-v1|\(url.path)|\((info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(info?[.size] as? NSNumber ?? 0)" as NSString
            if let cached = nativeCache.images.object(forKey: key) {
                ImageWorkDiagnostics.record("sharpnessNativeReuse"); return cached
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 2, height > 2, width <= 32768, height <= 32768,
                  width * height <= 128 * 1024 * 1024 else { continue }
            let embeddedOnly = url == asset.fileURL && asset.isRaw
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailFromImageAlways: !embeddedOnly,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  max(cg.width, cg.height) == max(width, height),
                  min(cg.width, cg.height) == min(width, height), isCurrent() else { continue }
            ImageWorkDiagnostics.record("sharpnessFullJPEGDecode")
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
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
