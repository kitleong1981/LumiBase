import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import LumiBase

final class PreviewSharpnessHostedTests: XCTestCase {
    private func rss() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.resident_size)/1048576 : 0
    }
    private func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)*1000 + Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1000
    }
    @MainActor func testHostedSelectedScoreOffOnGridLoupeNativeAndMixedEdits() async throws {
        let root = inspectionTestScratchURL("score-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ProcessInfo.processInfo.environment["LUMIBASE_FULL_SHARPNESS_FIXTURE"] ?? ProcessInfo.processInfo.environment["LUMIBASE_A7RV_FIXTURE"]
        let real = fixture.map { URL(fileURLWithPath: $0) }
        var assets: [PhotoAsset] = []
        if let real {
            if ProcessInfo.processInfo.environment["LUMIBASE_FULL_SHARPNESS_FIXTURE"] != nil {
                let scanned = await Task.detached { FolderScanner.quickScan(url: real) }.value
                let pair = try XCTUnwrap(scanned.first { $0.filename == "DSC01803.ARW" })
                assets = [PhotoAsset(fileURL: real.appendingPathComponent("DSC01801.JPG")), pair,
                    PhotoAsset(fileURL: real.appendingPathComponent("DSC01803.JPG"))]
            } else { assets = Array(await Task.detached { FolderScanner.quickScan(url: real) }.value.prefix(3)) }
        } else {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1066, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.bitmapData!.initialize(repeating: 60, count: rep.bytesPerRow*rep.pixelsHigh)
            for n in 0..<3 { let url = root.appendingPathComponent("\(n).jpg"); try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url); assets.append(PhotoAsset(fileURL: url)) }
        }
        XCTAssertEqual(assets.count, 3)
        assets[1].xmp.exposure2012 = 1
        // Use identical prewarmed file/proxy conditions for OFF/ON, no source writes.
        for asset in assets {
            if asset.xmp.hasDevelopEdits { _ = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 440) }
            else { _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset); _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset, maxPixelSize: 440) }
        }
        let saved = PerformanceSettings.shared.sharpnessEnabled
        let radius = PerformanceSettings.shared.roiRadius
        PerformanceSettings.shared.roiRadius = 0
        defer { PerformanceSettings.shared.sharpnessEnabled = saved; PerformanceSettings.shared.roiRadius = radius; ImageWorkDiagnostics.stop() }
        var rows: [[String: Any]] = []
        // Unmeasured complete OFF/ON trace warms framework/GPU/thumbnail state too.
        for trial in -1..<3 {
            for enabled in (trial % 2 == 0 ? [false, true] : [true, false]) {
                PerformanceSettings.shared.sharpnessEnabled = enabled
                let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false)); state.isHistogramEnabled = false
                state.allAssets = assets; state.selectAsset(assets[0]); state.viewMode = .grid
                let host = NSHostingView(rootView: WorkspaceView(appState: state))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                var gaps: [Double] = []; var previous = ProcessInfo.processInfo.systemUptime
                let baseRSS = rss(); var peakRSS = baseRSS
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in let now = ProcessInfo.processInfo.systemUptime; gaps.append((now-previous)*1000); previous = now }
                RunLoop.main.add(timer, forMode: .common)
                ImageWorkDiagnostics.start(); let startCPU = cpu()
                var first: [Double] = [], native: [Double] = [], compute: [Double] = [], computeCPU: [Double] = [], loads: [Double] = [], totals: [Double] = [], pixelBytes: [Int] = [], sizes: [String] = [], scoreValues: [Double] = []
                func waitReady(_ asset: PhotoAsset, after: Double, wantNative: Bool = false) async throws {
                    let due = ProcessInfo.processInfo.systemUptime+20
                    while ProcessInfo.processInfo.systemUptime < due {
                        host.layoutSubtreeIfNeeded(); peakRSS = max(peakRSS, rss())
                        if let frame = state.displayedBitmap, frame.assetID == asset.id, frame.readyUptime >= after,
                           frame.accurate == asset.xmp.hasDevelopEdits,
                           (!wantNative || !frame.scorePreview) { return }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    XCTFail("No current actual host bitmap for selected input")
                }
                func waitScore(_ asset: PhotoAsset) async throws {
                    guard enabled else { XCTAssertNil(state.previewSharpness.score); return }
                    let due = ProcessInfo.processInfo.systemUptime+30
                    while state.previewSharpness.score == nil && !state.previewSharpness.unavailable && ProcessInfo.processInfo.systemUptime < due { host.layoutSubtreeIfNeeded(); peakRSS = max(peakRSS, rss()); try await Task.sleep(nanoseconds: 2_000_000) }
                    XCTAssertNotNil(state.previewSharpness.score)
                    XCTAssertEqual(state.previewSharpness.assetID, asset.id)
                    compute.append(state.previewSharpness.computeMilliseconds)
                    computeCPU.append(state.previewSharpness.computeCPUMilliseconds)
                    loads.append(state.previewSharpness.sourceLoadMilliseconds); totals.append(state.previewSharpness.totalMilliseconds)
                    pixelBytes.append(state.previewSharpness.ownedPixelBytes); sizes.append(state.previewSharpness.sourceDescription)
                    scoreValues.append(state.previewSharpness.score ?? -1)
                }
                let gridStart = previous
                try await waitReady(assets[0], after: gridStart); try await waitScore(assets[0])
                state.viewMode = .loupe
                for asset in assets {
                    let began = ProcessInfo.processInfo.systemUptime
                    state.selectAsset(asset)
                    try await waitReady(asset, after: began)
                    first.append((try XCTUnwrap(state.displayedBitmap).readyUptime-began)*1000)
                    // Request native before waiting for the score: analysis must not gate readiness.
                    let beganNative = ProcessInfo.processInfo.systemUptime
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
                    try await waitReady(asset, after: beganNative, wantNative: true)
                    native.append((try XCTUnwrap(state.displayedBitmap).readyUptime-beganNative)*1000)
                    try await waitScore(asset)
                    NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
                    try await Task.sleep(nanoseconds: 70_000_000)
                }
                // Burst must never publish a previous selected asset's score.
                for asset in assets.reversed() { state.selectAsset(asset); await Task.yield() }
                let due = ProcessInfo.processInfo.systemUptime+5
                while state.displayedBitmap?.assetID != assets[0].id && ProcessInfo.processInfo.systemUptime < due { try await Task.sleep(nanoseconds: 5_000_000) }
                try await waitScore(assets[0])
                let counts = ImageWorkDiagnostics.snapshot()
                if trial >= 0 { rows.append(["trial": trial, "enabled": enabled, "firstReadyMs": first, "nativeReadyMs": native,
                    "computeWallMs": compute, "computeCPUMs": computeCPU, "sourceLoadMs": loads, "scoreTotalMsExcludingGrace": totals, "explicitPixelBytes": pixelBytes, "scoreSources": sizes, "scores": scoreValues, "maxHeartbeatMs": gaps.max() ?? 0, "cpuProcessMs": cpu()-startCPU,
                    "rssBaseMiB": baseRSS, "rssPeakDeltaMiB": peakRSS-baseRSS, "work": counts]) }
                timer.invalidate(); window.orderOut(nil); window.contentView = nil
                state.previewSharpness.clear()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        print("SHARPNESS_HOSTED_ROWS \(rows)")
        if let output = ProcessInfo.processInfo.environment["LUMIBASE_SHARPNESS_RESULTS"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        for trial in 0..<3 {
            let pair = rows.filter { $0["trial"] as? Int == trial }
            let off = try XCTUnwrap(pair.first { $0["enabled"] as? Bool == false }?["work"] as? [String: Int])
            let on = try XCTUnwrap(pair.first { $0["enabled"] as? Bool == true }?["work"] as? [String: Int])
            // Full-source scoring can legitimately add selected decodes/renders;
            // report the exact delta rather than retaining the old preview-only claim.
            XCTAssertLessThanOrEqual(on["sourceLoad", default: 0]-off["sourceLoad", default: 0], 6)
            XCTAssertLessThanOrEqual(on["processedRender", default: 0]-off["processedRender", default: 0], 6)
            XCTAssertEqual(off["sharpnessCompute", default: 0], 0)
            XCTAssertGreaterThan(on["sharpnessCompute", default: 0], 0)
        }
    }
}
