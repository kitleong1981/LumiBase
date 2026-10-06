import XCTest
import AppKit
import SwiftUI
import Combine
import ImageIO
@testable import LumiBase

/// Opt-in, read-only real-asset test. Records actual Loupe SwiftUI bitmap publication,
/// not an estimate obtained by adding independent API timings, and not compositor latency.
final class FastLibraryA7RVPerformanceTests: XCTestCase {
    @MainActor func testA7RVActualFirstReadyLibraryAndDevelop() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_FAST_LIBRARY_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LUMIBASE_FAST_LIBRARY_BENCHMARK=1; originals are read-only")
        }
        let folder = URL(fileURLWithPath: "/Volumes/Extreme SSD/Working/2026.10.02-05 Hot Air Ballon Festival/A7RV", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("Exact A7RV folder is not mounted") }
        let names = ["DSC01063", "DSC01442", "DSC01715", "DSC01981"]
        let assets: [PhotoAsset] = try names.map { name in
            let raw = folder.appendingPathComponent(name + ".ARW")
            let attributes = try FileManager.default.attributesOfItem(atPath: raw.path)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(raw as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return PhotoAsset(fileURL: raw, fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                dateModified: attributes[.modificationDate] as? Date ?? .distantPast,
                sourceOrientation: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
                companionURLs: [folder.appendingPathComponent(name + ".JPG")],
                cameraMetadata: MetadataReader.readMetadata(from: raw).camera)
        }
        // Disable speculative neighbors in this controlled test without deleting app caches.
        let preloader = PreviewPreloader(observeMemoryPressure: false, previewDecoder: { _, _ in nil })
        let state = AppState(preloader: preloader)
        state.isHistogramEnabled = false; state.viewMode = .loupe; state.allAssets = assets
        let host = NSHostingView(rootView: AnyView(Color.clear))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; ImageWorkDiagnostics.stop() }
        var selectedID: String?, started = 0.0, firstReady: Double?, firstAccurate: Double?
        let subscription = state.$displayedBitmap.sink { frame in
            guard let frame, frame.assetID == selectedID else { return }
            if firstReady == nil { firstReady = (frame.readyUptime - started) * 1000 }
            if frame.accurate && firstAccurate == nil { firstAccurate = (frame.readyUptime - started) * 1000 }
        }
        defer { subscription.cancel() }
        var rows: [[String: Any]] = []
        let sequence = [0,1,2,3,2,1,0,1,2,3,2,1,0,3]
        for mode in WorkspaceMode.allCases {
            host.rootView = AnyView(Color.clear)
            state.deselectAll(); try await Task.sleep(nanoseconds: 50_000_000)
            state.workspaceMode = mode
            RAWImageLoader.shared.clearCache(); InspectionReadyFrameStore.shared.clearAll()
            ImageWorkDiagnostics.start()
            for (step, index) in sequence.enumerated() {
                let asset = assets[index]
                selectedID = asset.id; firstReady = nil; firstAccurate = nil
                started = ProcessInfo.processInfo.systemUptime
                state.selectAsset(asset)
                if step == 0 { host.rootView = AnyView(LoupeView(appState: state)) }
                let deadline = started + 8
                while (firstReady == nil || (mode == .develop && firstAccurate == nil)) && ProcessInfo.processInfo.systemUptime < deadline {
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 1_000_000)
                }
                let ready = try XCTUnwrap(firstReady, "No actual first-ready bitmap")
                XCTAssertEqual(state.displayedBitmap?.assetID, asset.id)
                let frame = try XCTUnwrap(state.displayedBitmap)
                let cg = try XCTUnwrap(frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                var row: [String: Any] = ["mode": mode.rawValue, "step": step, "filename": asset.filename,
                    "firstReadyMilliseconds": ready, "bitmapWidth": cg.width, "bitmapHeight": cg.height,
                    "label": frame.label, "accurate": frame.accurate]
                if let firstAccurate { row["firstAccurateMilliseconds"] = firstAccurate }
                // Let accurate refinement finish; this is not included in first-ready.
                try await Task.sleep(nanoseconds: mode == .develop ? 700_000_000 : 30_000_000)
                let work = ImageWorkDiagnostics.snapshot(); row["cumulativeWork"] = work
                XCTAssertEqual(work["histogramBins", default: 0], 0)
                if mode == .library {
                    XCTAssertEqual(work["sourceLoad", default: 0], 0)
                    XCTAssertEqual(work["processedRender", default: 0], 0)
                    XCTAssertFalse(frame.accurate)
                } else { XCTAssertNotNil(firstAccurate); XCTAssertTrue(frame.accurate) }
                rows.append(row)
            }
        }
        // Library 100% now requests original companion JPEG pixels, never a zoomed proxy.
        state.workspaceMode = .library
        selectedID = assets[0].id; firstReady = nil; firstAccurate = nil
        state.selectAsset(assets[0]); try await Task.sleep(nanoseconds: 100_000_000)
        started = ProcessInfo.processInfo.systemUptime; firstReady = nil; firstAccurate = nil
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        let deadline = started + 8
        while !(state.displayedBitmap?.label.contains("native 100%") ?? false) && ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(firstReady)
        let nativeFrame = try XCTUnwrap(state.displayedBitmap)
        XCTAssertFalse(nativeFrame.accurate)
        let nativeCG = try XCTUnwrap(nativeFrame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(nativeCG.width, 2560)
        let nativeJPEGFirstReady = firstReady
        // Staying zoomed while switching to Develop must replace JPEG with native
        // accurate RAW; mode/source revision gates may not reuse the camera frame.
        firstReady = nil; firstAccurate = nil
        state.workspaceMode = .develop
        let developDeadline = ProcessInfo.processInfo.systemUptime + 12
        while firstAccurate == nil && ProcessInfo.processInfo.systemUptime < developDeadline {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(firstAccurate)
        let developedNative = try XCTUnwrap(state.displayedBitmap)
        XCTAssertTrue(developedNative.accurate)
        let developedCG = try XCTUnwrap(developedNative.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(developedCG.width, 2560)
        let output = ProcessInfo.processInfo.environment["LUMIBASE_FAST_EVIDENCE_PATH"] ?? inspectionTestScratchURL("fast-library-a7rv.json").path
        let evidence: [String: Any] = ["folder": folder.path, "rows": rows,
            "measurement": "Actual hosted Loupe SwiftUI onChange display bitmap publication; not compositor/display-present. OS cache not purged; thumbnail cache not cleared.",
            "histogramEnabled": false, "speculativeNeighborDecoder": "disabled for controlled comparison",
            "nativeLibraryFirstJPEGMilliseconds": nativeJPEGFirstReady as Any,
            "developNativeBitmapWidth": developedCG.width, "developNativeBitmapHeight": developedCG.height,
            "nativeBitmapWidth": nativeCG.width, "nativeBitmapHeight": nativeCG.height]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("A7RV_FIRST_READY_EVIDENCE \(output) rows=\(rows.count)")
    }
}
