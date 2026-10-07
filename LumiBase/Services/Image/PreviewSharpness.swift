import Foundation
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import Darwin

/// Scalar cache entries never retain source bitmaps/CI graphs.
private struct FullSharpnessResult: Sendable {
    let score: Double
    let width: Int
    let height: Int
    let source: String
    let wall: Double
    let cpu: Double
    let loadWall: Double
    let pixelBytes: Int
}

/// One active selected source + latest pending metadata, never a folder queue.
private final class SharpnessWorker: @unchecked Sendable {
    struct Job {
        let token: UUID; let key: String; let asset: PhotoAsset; let processed: Bool
        // Explicit full-frame test seam; never used by AppState.
        let testFullImage: NSImage?
        let complete: @Sendable (UUID, FullSharpnessResult?, Double) -> Void
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lumibase.sharpness.full", qos: .utility)
    // Do not populate the foreground CIContext's full-size intermediate cache.
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    private var pending: Job?
    private var running = false
    private var active: Task<Void, Never>?
    private var currentToken = UUID()
    private var cache: [String: FullSharpnessResult] = [:]
    private var order: [String] = []
    private func cpuMilliseconds() -> Double {
        var value = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec)*1000 + Double(value.tv_nsec)/1_000_000
    }
    func cancel() { lock.lock(); currentToken = UUID(); pending = nil; active?.cancel(); lock.unlock() }
    func isCurrent(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return currentToken == token }
    func submit(_ job: Job) {
        lock.lock(); currentToken = job.token; pending = job; active?.cancel()
        let start = !running; running = true; lock.unlock()
        if start { Task.detached(priority: .utility) { await self.drain() } }
    }
    private func next() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard let job = pending else { running = false; active = nil; return nil }
        pending = nil; return job
    }
    private func install(_ task: Task<Void, Never>, token: UUID) {
        lock.lock(); active = task; if token != currentToken { task.cancel() }; lock.unlock()
    }
    private func drain() async {
        while let job = next() {
            let work = Task.detached(priority: .utility) { await self.perform(job) }
            install(work, token: job.token); await work.value
        }
    }
    private func onQueue<T>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: autoreleasepool(invoking: operation)) }
        }
    }
    private func sourceVersion(_ asset: PhotoAsset) -> String {
        ([asset.fileURL] + asset.companionURLs).map { url in
            let info = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\(url.path)|\((info?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(info?[.size] as? NSNumber ?? 0)"
        }.joined(separator: "|")
    }
    private func perform(_ job: Job) async {
        // Display publication is never waiting for scoring. Cancellable idle grace
        // lets a foreground native request win before selected-source work starts.
        if job.testFullImage == nil {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
        }
        guard isCurrent(job.token), !Task.isCancelled else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let version = await onQueue { self.sourceVersion(job.asset) }
        let cacheKey = job.key + "|" + version
        if let hit = await onQueue({ self.cache[cacheKey] }) {
            guard isCurrent(job.token), !Task.isCancelled else { return }
            ImageWorkDiagnostics.record("sharpnessScalarHit")
            let cached = FullSharpnessResult(score: hit.score, width: hit.width, height: hit.height, source: hit.source, wall: 0, cpu: 0, loadWall: 0, pixelBytes: 0)
            job.complete(job.token, cached, (ProcessInfo.processInfo.systemUptime-began)*1000); return
        }
        let loaded: NSImage?
        var source = job.processed ? "Processed" : "Native JPEG"
        if let testFull = job.testFullImage { loaded = testFull; source = "Test full frame" }
        else if !job.processed {
            loaded = await onQueue { ThumbnailLoader.sharpnessCameraFullImage(for: job.asset, isCurrent: { self.isCurrent(job.token) }) }
        } else { loaded = nil }
        var pixels = loaded
        if pixels == nil && (job.processed || job.asset.isRaw) {
            guard isCurrent(job.token), !Task.isCancelled else { return }
            let withinBudget = await onQueue { () -> Bool in
                guard let source = CGImageSourceCreateWithURL(job.asset.fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return false }
                return w > 2 && h > 2 && w <= 32768 && h <= 32768 && w * h <= 128 * 1024 * 1024
            }
            guard withinBudget else { job.complete(job.token, nil, (ProcessInfo.processInfo.systemUptime-began)*1000); return }
            // Selected immutable edit snapshot. No speculative neighbors, shared
            // base insertion or eviction. Blocking decode runs on GCD, not Swift's pool.
            guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: job.asset.fileURL,
                xmp: job.asset.xmp, useSharedCache: false, priority: .utility),
                holder.supportsNativeInspection, holder.fullExtent.width > 2, holder.fullExtent.height > 2,
                holder.fullExtent.width <= 32768, holder.fullExtent.height <= 32768,
                holder.fullExtent.width * holder.fullExtent.height <= 128 * 1024 * 1024,
                isCurrent(job.token), !Task.isCancelled else {
                if isCurrent(job.token) { job.complete(job.token, nil, (ProcessInfo.processInfo.systemUptime-began)*1000) }; return
            }
            source = job.processed ? "Processed" : "Native RAW"
            pixels = await onQueue {
                RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: job.asset.cameraMetadata.model,
                    xmp: job.asset.xmp, fullResolution: true, sourceRect: nil, background: true, contextOverride: self.renderContext, isCurrent: { self.isCurrent(job.token) })
            }
        }
        let loadWall = (ProcessInfo.processInfo.systemUptime-began)*1000
        guard isCurrent(job.token), !Task.isCancelled else { return }
        let fullImage = pixels, sourceLabel = source
        let result: FullSharpnessResult? = await onQueue {
            guard self.isCurrent(job.token), let fullImage,
                  let cg = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let start = ProcessInfo.processInfo.systemUptime, cpu = self.cpuMilliseconds()
            guard let score = PreviewSharpness.compute(cg, isCurrent: { self.isCurrent(job.token) }),
                  self.isCurrent(job.token), self.sourceVersion(job.asset) == version else { return nil }
            ImageWorkDiagnostics.record("sharpnessCompute")
            let value = FullSharpnessResult(score: score, width: cg.width, height: cg.height, source: sourceLabel,
                wall: (ProcessInfo.processInfo.systemUptime-start)*1000, cpu: self.cpuMilliseconds()-cpu,
                loadWall: loadWall, pixelBytes: cg.bytesPerRow*cg.height + cg.width*cg.height)
            self.cache[cacheKey] = value; self.order.removeAll { $0 == cacheKey }; self.order.append(cacheKey)
            if self.order.count > 256 { self.cache.removeValue(forKey: self.order.removeFirst()) }
            return value
        }
        // No pixels are captured by MainActor completion or cached scalar result.
        guard isCurrent(job.token), !Task.isCancelled else { return }
        job.complete(job.token, result, (ProcessInfo.processInfo.systemUptime-began)*1000)
    }
}

@MainActor final class PreviewSharpnessState: ObservableObject {
    @Published private(set) var score: Double?
    @Published private(set) var assetID: String?
    @Published private(set) var sourceDescription = ""
    @Published private(set) var unavailable = false
    private(set) var identity: String?
    private(set) var computeMilliseconds: Double = 0
    private(set) var computeCPUMilliseconds: Double = 0
    private(set) var sourceLoadMilliseconds: Double = 0
    private(set) var totalMilliseconds: Double = 0
    private(set) var fullPixelWidth = 0
    private(set) var fullPixelHeight = 0
    /// Last job's explicit bitmap + grayscale allocation, not retained RSS.
    private(set) var ownedPixelBytes = 0
    private var token = UUID()
    private let worker = SharpnessWorker()
    func clear() {
        token = UUID(); worker.cancel(); score = nil; assetID = nil; identity = nil
        unavailable = false; sourceDescription = ""; ownedPixelBytes = 0
    }
    func submit(asset: PhotoAsset, revision: UInt64, processed: Bool) {
        enqueue(asset: asset, revision: revision, processed: processed, kind: processed ? "processed" : "camera", testFullImage: nil)
    }
    /// Test-only full-frame injection; production never submits a displayed bitmap.
    func submit(_ fullImage: NSImage, asset: PhotoAsset, revision: UInt64, previewKind: String) {
        enqueue(asset: asset, revision: revision, processed: false, kind: "test-" + previewKind, testFullImage: fullImage)
    }
    private func enqueue(asset: PhotoAsset, revision: UInt64, processed: Bool, kind: String, testFullImage: NSImage?) {
        let key = "\(PreviewSharpness.algorithm)|\(asset.id)|\(asset.dateModified.timeIntervalSinceReferenceDate)|\(asset.fileSize)|\(asset.companionURLs.map(\.path).joined(separator: ";"))|\(revision)|\(asset.xmp.thumbnailDevelopCacheIdentity)|\(NativeHighlightsService.isEnabled)|\(kind)"
        // Repeated proxy/native publications cannot cancel the same queued score.
        if identity == key { return }
        token = UUID(); let captured = token
        score = nil; unavailable = false; sourceDescription = ""; assetID = asset.id; identity = key
        worker.submit(.init(token: captured, key: key, asset: asset, processed: processed, testFullImage: testFullImage,
            complete: { [weak self] ticket, result, total in
            Task { @MainActor in
                guard let self, self.token == ticket, self.identity == key else { return }
                self.score = result?.score; self.unavailable = result == nil; self.totalMilliseconds = total
                self.computeMilliseconds = result?.wall ?? 0; self.computeCPUMilliseconds = result?.cpu ?? 0
                self.sourceLoadMilliseconds = result?.loadWall ?? 0
                self.fullPixelWidth = result?.width ?? 0; self.fullPixelHeight = result?.height ?? 0
                self.ownedPixelBytes = result?.pixelBytes ?? 0
                self.sourceDescription = result.map { "\($0.source) \($0.width)×\($0.height)" } ?? "full source unavailable"
            }
        }))
    }
}

struct PreviewSharpnessInfo: View {
    @ObservedObject var state: PreviewSharpnessState
    let selectedID: String?
    var body: some View {
        Text(state.assetID == selectedID && state.score != nil
            ? String(format: "Sharpness · Full resolution: %.1f · %@", state.score!, state.sourceDescription)
            : "Sharpness · Full resolution: " + (state.assetID == selectedID && state.unavailable ? "unavailable" : "preparing"))
            .font(.system(size: 10, design: .monospaced))
            .accessibilityIdentifier("previewSharpnessScore")
            .help("Relative whole-frame native-pixel metric (top 10% of 64px Laplacian blocks), not focus confidence. Processed means full edited output including crop, never a viewport ROI. Selected-source decode/render adds CPU and transient memory; noise and sharpening bias the score. No automatic rejection.")
    }
}

/// Relative native-pixel metric, not RAW focus confidence or a ROI classifier.
enum PreviewSharpness {
    static let algorithm = "laplacian-top10-block64-srgb-full-v2"
    static func compute(_ image: CGImage, isCurrent: () -> Bool = { true }) -> Double? {
        guard isCurrent(), image.width > 2, image.height > 2 else { return nil }
        // Native whole-frame pixels. No resampling; the worker never feeds an ROI.
        let w = image.width, h = image.height
        guard w <= 32768, h <= 32768, w * h <= 128 * 1024 * 1024 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(data: pixels.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, isCurrent() else { return nil }
        let block = 64, cols = max(1, w / 64), rows = max(1, h / 64)
        var variances: [Double] = []; variances.reserveCapacity(cols * rows)
        for by in 0..<rows {
            guard isCurrent() else { return nil }
            for bx in 0..<cols {
                var sum = 0.0, squares = 0.0, count = 0.0
                for y in (by*block)..<min(h, (by+1)*block) {
                    let up = max(0, y-1), down = min(h-1, y+1)
                    for x in (bx*block)..<min(w, (bx+1)*block) {
                        let value = Double(Int(gray[up*w+x]) + Int(gray[down*w+x]) + Int(gray[y*w+max(0,x-1)]) + Int(gray[y*w+min(w-1,x+1)]) - 4*Int(gray[y*w+x]))
                        sum += value; squares += value*value; count += 1
                    }
                }
                variances.append(max(0, squares/count - (sum/count)*(sum/count)))
            }
        }
        guard isCurrent() else { return nil }
        variances.sort(by: >)
        let top = max(1, variances.count/10)
        return variances.prefix(top).reduce(0,+) / Double(top)
    }
}
