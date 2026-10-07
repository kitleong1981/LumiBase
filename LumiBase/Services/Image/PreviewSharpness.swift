import Foundation
import AppKit
import SwiftUI
import Darwin

/// One active utility computation + one latest pending preview, never a folder queue.
private final class SharpnessWorker: @unchecked Sendable {
    struct Job { let token: UUID; let key: String; let image: NSImage; let complete: @Sendable (UUID, Double?, Double, Double) -> Void }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lumibase.sharpness.preview", qos: .utility)
    private var pending: Job?
    private var running = false
    private var currentToken = UUID()
    private var cache: [String: Double] = [:]
    private var order: [String] = []
    private func cpuMilliseconds() -> Double {
        var value = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec)*1000 + Double(value.tv_nsec)/1_000_000
    }
    func cancel() { lock.lock(); currentToken = UUID(); pending = nil; lock.unlock() }
    func isCurrent(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return currentToken == token }
    func submit(_ job: Job) {
        lock.lock(); currentToken = job.token; pending = job
        let start = !running; running = true; lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else { running = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let cpuStart = cpuMilliseconds()
            let value: Double? = autoreleasepool {
                guard isCurrent(job.token) else { return nil }
                if let hit = cache[job.key] { return hit }
                guard let cg = job.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let score = PreviewSharpness.compute(cg, isCurrent: { self.isCurrent(job.token) }) else { return nil }
                ImageWorkDiagnostics.record("sharpnessCompute")
                cache[job.key] = score; order.removeAll { $0 == job.key }; order.append(job.key)
                if order.count > 256 { cache.removeValue(forKey: order.removeFirst()) }
                return score
            }
            job.complete(job.token, value, (ProcessInfo.processInfo.systemUptime-start)*1000, cpuMilliseconds()-cpuStart)
        }
    }
}

@MainActor final class PreviewSharpnessState: ObservableObject {
    @Published private(set) var score: Double?
    @Published private(set) var assetID: String?
    private(set) var identity: String?
    private(set) var computeMilliseconds: Double = 0
    private(set) var computeCPUMilliseconds: Double = 0
    private var token = UUID()
    private let worker = SharpnessWorker()
    func clear() { token = UUID(); worker.cancel(); score = nil; assetID = nil; identity = nil }
    func submit(_ image: NSImage, asset: PhotoAsset, revision: UInt64, previewKind: String) {
        let key = "\(PreviewSharpness.algorithm)|\(asset.id)|\(asset.dateModified.timeIntervalSinceReferenceDate)|\(asset.fileSize)|\(revision)|\(asset.xmp.thumbnailDevelopCacheIdentity)|\(NativeHighlightsService.isEnabled)|\(previewKind)|\(image.size.width)x\(image.size.height)"
        if identity == key && score != nil { return }
        token = UUID(); let captured = token
        score = nil; assetID = asset.id; identity = key
        worker.submit(.init(token: captured, key: key, image: image, complete: { [weak self] ticket, result, milliseconds, cpuMilliseconds in
            Task { @MainActor in
                guard let self, self.token == ticket, self.identity == key else { return }
                self.score = result; self.computeMilliseconds = milliseconds
                self.computeCPUMilliseconds = cpuMilliseconds
            }
        }))
    }
}

struct PreviewSharpnessInfo: View {
    @ObservedObject var state: PreviewSharpnessState
    let selectedID: String?
    var body: some View {
        Text(state.assetID == selectedID && state.score != nil ? String(format: "Sharpness · Preview: %.1f", state.score!) : "Sharpness · Preview: preparing")
            .font(.system(size: 10, design: .monospaced))
            .accessibilityIdentifier("previewSharpnessScore")
            .help("Experimental relative preview metric (1024px, top 10% of 64px Laplacian blocks). Compare the same view and preview quality. Noise and sharpening can increase the score; this is not focus confidence or an automatic reject rule.")
    }
}

/// Display-preview metric, not a RAW focus-confidence classifier.
enum PreviewSharpness {
    static let algorithm = "laplacian-top10-block64-srgb1024-v1"
    static func compute(_ image: CGImage, isCurrent: () -> Bool = { true }) -> Double? {
        guard isCurrent(), image.width > 2, image.height > 2 else { return nil }
        // Fixed display-scale grayscale input; never reopen a file or decode RAW.
        let scale = 1024.0 / Double(max(image.width, image.height))
        let w = max(3, Int(Double(image.width) * scale)), h = max(3, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(data: pixels.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
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
