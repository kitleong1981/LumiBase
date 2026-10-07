import Foundation
import AppKit
import ImageIO

/// Opt-in JPEG ±1. Full decode happens in a short-lived native helper, never nativeCache.
/// Its exit releases ImageIO backing. Parent providers own only tightly packed ROI pixels.
final class LibraryJPEGROICache: @unchecked Sendable {
    struct Geometry: Equatable { let center: CGPoint; let viewport: CGSize; let backing: CGFloat }
    struct Frame {
        let image: CGImage; let sourceRect: CGRect; let fullExtent: CGRect; let orientation: Int
        var preview: NSImage? = nil
        var previewBytes = 0
        var roiBytes: Int { image.bytesPerRow * image.height }
        var cost: Int { roiBytes + previewBytes }
    }
    private struct Entry { let assetID: String; let snapshot: String; let version: String; let geometry: Geometry; let frame: Frame }
    static let shared = LibraryJPEGROICache()
    private static let ownershipLock = NSLock()
    private static var owned = 0
    static var ownedBytes: Int { ownershipLock.lock(); defer { ownershipLock.unlock() }; return owned }
    private static func account(_ delta: Int) { ownershipLock.lock(); owned += delta; ownershipLock.unlock() }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lumibase.library.jpeg-roi.experimental", qos: .utility)
    private let budget: Int
    private var entries: [Entry] = []
    private var generation: UInt64 = 0
    private var hitCount = 0
    private var activeWorker = false
    init(budget: Int = 64 * 1024 * 1024) { self.budget = budget }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return entries.reduce(0) { $0 + $1.frame.cost } }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return hitCount }
    var workerActive: Bool { lock.lock(); defer { lock.unlock() }; return activeWorker }
    private func worker(_ active: Bool) { lock.lock(); activeWorker = active; lock.unlock() }
    func cancel(clear: Bool = false) { lock.lock(); generation &+= 1; if clear { entries.removeAll() }; lock.unlock() }
    private func token() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    private func current(_ value: UInt64) -> Bool { token() == value }
    private func contains(_ asset: PhotoAsset, version: String, geometry: Geometry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains { $0.assetID == asset.id && $0.version == version && $0.geometry == geometry }
    }
    private static func snapshot(_ asset: PhotoAsset) -> String {
        "\(asset.id)|\(asset.dateModified.timeIntervalSinceReferenceDate)|\(asset.fileSize)|\(asset.companionURLs.map(\.path).joined(separator: "|"))"
    }
    /// Body-safe proxy only, with the same scanner snapshot contract as camera handoff.
    /// Native ROI publication still validates the actual JPEG file version in match().
    func readyPreview(_ asset: PhotoAsset) -> ThumbnailLoader.ReadyCameraGeometry? {
        let snapshot = Self.snapshot(asset)
        lock.lock(); defer { lock.unlock() }
        guard let frame = entries.first(where: { $0.assetID == asset.id && $0.snapshot == snapshot })?.frame,
              let preview = frame.preview else { return nil }
        return ThumbnailLoader.ReadyCameraGeometry(image: preview, fullExtent: frame.fullExtent)
    }
    static func jpegURL(_ asset: PhotoAsset) -> URL? {
        let candidates = asset.companionURLs.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent == asset.fileURL.deletingPathExtension().lastPathComponent && $0.deletingLastPathComponent() == asset.fileURL.deletingLastPathComponent() }
        return candidates.first ?? (["jpg", "jpeg"].contains(asset.fileURL.pathExtension.lowercased()) ? asset.fileURL : nil)
    }
    private static func version(_ asset: PhotoAsset) -> String? {
        guard let url = jpegURL(asset), let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return "library-jpeg-roi-v1|\(asset.id)|\(asset.dateModified.timeIntervalSinceReferenceDate)|\(asset.fileSize)|\(url.path)|\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(a[.size] ?? "")"
    }
    func match(_ asset: PhotoAsset, geometry: Geometry) -> Frame? {
        guard let version = Self.version(asset) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.assetID == asset.id && $0.version == version && $0.geometry == geometry }) else { return nil }
        let entry = entries.remove(at: index); entries.append(entry); hitCount += 1
        return entry.frame
    }
    func preload(_ assets: [PhotoAsset], geometry: Geometry) async {
        guard !Task.isCancelled else { return }
        cancel()
        let revision = token()
        for asset in assets.prefix(2) {
            guard !Task.isCancelled, current(revision) else { return }
            guard let version = Self.version(asset) else { continue }
            if contains(asset, version: version, geometry: geometry) { continue }
            // Retain a bounded selected-asset fallback with the ROI. Forward-only
            // handoff prefetch need not contain the previous neighbor, and its LRU
            // can evict a proxy before the user pans outside the crop.
            guard let preview = await ThumbnailLoader.shared.loadCameraPreview(for: asset, maxPixelSize: 1600),
                  !Task.isCancelled, current(revision),
                  let previewCG = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let previewExtent = ThumbnailLoader.readyCameraFullExtent(for: asset)
            let previewBytes = previewCG.bytesPerRow * previewCG.height
            let frame: Frame? = await withCheckedContinuation { continuation in
                queue.async {
                    self.worker(true)
                    defer { self.worker(false) }
                    let result: Frame? = autoreleasepool {
                        guard self.current(revision), let url = Self.jpegURL(asset) else { return nil }
                        return Self.decode(url, geometry: geometry, budget: self.budget)
                    }
                    continuation.resume(returning: result)
                }
            }
            guard !Task.isCancelled, current(revision), Self.version(asset) == version, let frame else { continue }
            guard frame.fullExtent == previewExtent else { continue }
            var complete = frame; complete.preview = preview; complete.previewBytes = previewBytes
            store(complete, asset: asset, version: version, geometry: geometry, revision: revision)
        }
    }
    private func store(_ frame: Frame, asset: PhotoAsset, version: String, geometry: Geometry, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard generation == revision, frame.cost <= budget else { return }
        entries.removeAll { $0.assetID == asset.id }
        entries.append(Entry(assetID: asset.id, snapshot: Self.snapshot(asset), version: version, geometry: geometry, frame: frame))
        while entries.count > 2 || entries.reduce(0, { $0 + $1.frame.cost }) > budget { entries.removeFirst() }
    }
    private static func decode(_ url: URL, geometry: Geometry, budget: Int) -> Frame? {
        guard geometry.viewport.width > 1, geometry.viewport.height > 1 else { return nil }
        let helper: URL
        if let override = ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_HELPER"] { helper = URL(fileURLWithPath: override) }
        else { helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LumiBaseJPEGROIHelper") }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let child = Process(), pipe = Pipe()
        child.executableURL = helper
        child.qualityOfService = .utility
        child.arguments = [url.path, String(Double(geometry.center.x)), String(Double(geometry.center.y)), String(Double(geometry.viewport.width)), String(Double(geometry.viewport.height)), String(Double(geometry.backing))]
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return nil }
        // Read directly into the final owned allocation: Foundation's large pipe
        // Data buffers retained ~48 MB/cycle in the isolated parent RSS probe.
        defer {
            try? pipe.fileHandleForReading.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        func readExact(_ pointer: UnsafeMutableRawPointer, _ size: Int) -> Bool {
            var offset = 0
            while offset < size {
                let n = Darwin.read(pipe.fileHandleForReading.fileDescriptor, pointer.advanced(by: offset), size - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        var fields = [Int64](repeating: 0, count: 7)
        guard fields.withUnsafeMutableBytes({ readExact($0.baseAddress!, 56) }),
              fields.allSatisfy({ $0 >= 0 && $0 <= 100_000 }), fields[0] > 0, fields[1] > 0,
              (1...8).contains(fields[6]) else { return nil }
        let w = Int(fields[0]), h = Int(fields[1]), stride = w * 4, cost = stride * h
        guard cost <= budget, let memory = malloc(cost) else { return nil }
        guard readExact(memory, cost) else { free(memory); return nil }
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { free(memory); return nil }
        let extent = CGRect(x: 0, y: 0, width: Int(fields[4]), height: Int(fields[5]))
        let rect = CGRect(x: Int(fields[2]), y: Int(fields[3]), width: w, height: h)
        guard rect == InspectionROI.sourceRect(extent: extent, center: geometry.center, viewport: geometry.viewport, backing: geometry.backing) else { free(memory); return nil }
        account(cost)
        guard let provider = CGDataProvider(dataInfo: nil, data: memory, size: cost, releaseData: { _, pointer, size in
            LibraryJPEGROICache.account(-size)
            free(UnsafeMutableRawPointer(mutating: pointer))
        }) else { account(-cost); free(memory); return nil }
        guard let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return Frame(image: image, sourceRect: rect, fullExtent: extent, orientation: Int(fields[6]))
    }
}
