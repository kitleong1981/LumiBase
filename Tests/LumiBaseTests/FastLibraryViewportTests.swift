import XCTest
import SwiftUI
import AppKit
import Combine
@testable import LumiBase

private struct FastViewport: View {
    @ObservedObject var state: AppState
    var body: some View {
        WorkspaceView(appState: state)
    }
}

final class FastLibraryViewportTests: XCTestCase {
    @MainActor func testWarmCameraSelectionNeverPresentsEmptyOrWrongPhoto() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_VIEWPORT_PROBE"] == "1" else { throw XCTSkip("Read-only mounted A7RV handoff probe") }
        guard let fixture = ProcessInfo.processInfo.environment["LUMIBASE_A7RV_FIXTURE"] else { throw XCTSkip("Set LUMIBASE_A7RV_FIXTURE to a read-only paired A7RV folder") }
        let folder = URL(fileURLWithPath: fixture)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("A7RV not mounted") }
        let assets = await Task.detached { FolderScanner.quickScan(url: folder) }.value
        XCTAssertEqual(assets.count, 739)
        let middle = assets.count / 2
        for asset in assets[middle...middle+3] { _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset) }
        let state = AppState(); state.isHistogramEnabled = false; state.allAssets = assets
        state.selectAsset(assets[middle]); state.viewMode = .loupe
        let host = NSHostingView(rootView: FastViewport(state: state))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1100, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func surface(_ view: NSView) -> InspectionSurface.Surface? {
            if let target = view as? InspectionSurface.Surface { return target }
            return view.subviews.compactMap { surface($0) }.first
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        // Z establishes persistent 100% intent; selected warm proxies must retain native geometry.
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 350_000_000)
        var rows: [[String: Any]] = []
        for step in 0..<12 {
            let asset = assets[middle + 1 + step % 3]
            state.selectAsset(asset)
            var empty = 0, spinner = 0, emptyMs = 0.0
            let started = ProcessInfo.processInfo.systemUptime
            var previous = started
            while ProcessInfo.processInfo.systemUptime - started < 0.09 {
                host.layoutSubtreeIfNeeded()
                let target = try XCTUnwrap(surface(host))
                let now = ProcessInfo.processInfo.systemUptime
                if target.owner?.hasPresentedImage == false { empty += 1; emptyMs += (now - previous) * 1000 }
                if target.owner?.presentsSpinner == true { spinner += 1 }
                let owner = try XCTUnwrap(target.owner)
                let extent = ThumbnailLoader.readyCameraFullExtent(for: asset)
                XCTAssertEqual(extent.size, CGSize(width: 9504, height: 6336))
                XCTAssertTrue(owner.presentedZoomed)
                XCTAssertEqual(owner.presentedImageSize.width, extent.width / window.backingScaleFactor, accuracy: 0.01)
                XCTAssertEqual(owner.presentedImageSize.height, extent.height / window.backingScaleFactor, accuracy: 0.01)
                if owner.preparingNative { XCTAssertFalse(owner.presentedNative) }
                if target.owner?.hasPresentedImage == true { XCTAssertEqual(target.owner?.presentedAssetID, state.primarySelectedAssetID) }
                previous = now
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            rows.append(["step": step, "emptySamples": empty, "spinnerSamples": spinner, "emptyMs": emptyMs])
            XCTAssertEqual(empty, 0, "Warm selected camera preview must reach actual host without an empty branch")
            XCTAssertEqual(spinner, 0)
            XCTAssertEqual(state.displayedBitmap?.assetID, asset.id)
        }
        print("WARM_SELECTION_PRESENTATION \(rows)")
    }
    @MainActor func testLibraryHoldPublishesNativeJPEGThenReleaseReturnsFit() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_VIEWPORT_PROBE"] == "1" else { throw XCTSkip("Read-only A7RV native click probe") }
        guard let fixture = ProcessInfo.processInfo.environment["LUMIBASE_A7RV_FIXTURE"] else { throw XCTSkip("Set LUMIBASE_A7RV_FIXTURE to a read-only paired A7RV folder") }
        let folder = URL(fileURLWithPath: fixture)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("A7RV not mounted") }
        let assets = await Task.detached { FolderScanner.quickScan(url: folder) }.value
        let state = AppState(); state.isHistogramEnabled = false; state.allAssets = assets
        state.selectAsset(assets[assets.count / 2]); state.viewMode = .loupe
        let host = NSHostingView(rootView: FastViewport(state: state))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1100, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; ImageWorkDiagnostics.stop() }
        func wait(_ seconds: Double) async throws {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < until { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        }
        func surface(_ view: NSView) -> InspectionSurface.Surface? {
            if let target = view as? InspectionSurface.Surface { return target }
            return view.subviews.compactMap { surface($0) }.first
        }
        try await wait(0.8)
        let target = try XCTUnwrap(surface(host))
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.03, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        ImageWorkDiagnostics.start()
        target.mouseDown(with: down)
        var emptySamples = 0, spinnerSamples = 0
        var emptyMs = 0.0
        var previousSample = ProcessInfo.processInfo.systemUptime
        let sampleUntil = previousSample + 2
        while ProcessInfo.processInfo.systemUptime < sampleUntil {
            host.layoutSubtreeIfNeeded()
            let sampleTime = ProcessInfo.processInfo.systemUptime
            if target.owner?.hasPresentedImage == false { emptySamples += 1; emptyMs += (sampleTime - previousSample) * 1000 }
            if target.owner?.presentsSpinner == true { spinnerSamples += 1 }
            if target.owner?.hasPresentedImage == true { XCTAssertEqual(target.owner?.presentedAssetID, state.primarySelectedAssetID) }
            previousSample = sampleTime
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        print("ZOOM_PRESENTATION emptySamples=\(emptySamples) spinnerSamples=\(spinnerSamples) emptyMs=\(emptyMs)")
        XCTAssertEqual(emptySamples, 0, "A selected Fit frame must stay on the actual native-hosted image branch during native decode")
        XCTAssertEqual(spinnerSamples, 0, "No central spinner over a ready same-photo proxy")
        let frame = try XCTUnwrap(state.displayedBitmap)
        let cg = try XCTUnwrap(frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 9504, "Held inspection must publish actual native JPEG pixels")
        XCTAssertEqual(cg.height, 6336)
        XCTAssertTrue(frame.label.contains("100%"))
        XCTAssertFalse(frame.accurate, "Camera JPEG is never a developed RAW frame")
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let layout = InspectionFrameLayout.make(pixels: pixelSize, sourceRect: nil,
            fullExtent: CGRect(origin: .zero, size: pixelSize), zoomed: true,
            viewport: target.bounds.size, backing: window.backingScaleFactor)
        XCTAssertEqual(layout.imageSize.width, CGFloat(cg.width) / window.backingScaleFactor)
        XCTAssertGreaterThan(layout.imageSize.width, target.bounds.width)
        XCTAssertNotEqual(layout.imagePosition(viewport: target.bounds.size, center: CGPoint(x: 0.6, y: 0.5), sourceRect: nil),
            layout.imagePosition(viewport: target.bounds.size, center: CGPoint(x: 0.5, y: 0.5), sourceRect: nil))
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["histogramBins", default: 0], 0)
        print("NATIVE_CLICK width=\(cg.width) height=\(cg.height) backing=\(window.backingScaleFactor) label=\(frame.label) elapsedMs=\((frame.readyUptime-now)*1000)")
        target.mouseUp(with: up)
        try await wait(0.15)
        XCTAssertFalse(target.owner?.presentedZoomed ?? true, "Release returns Fit")
        // Persistent zoom uses the actual Z notification, not an ordinary click.
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await wait(0.15)
        let dragPoint = CGPoint(x: point.x + 40, y: point.y + 20)
        let dragDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now + 3, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: dragPoint, modifierFlags: [], timestamp: now + 3.1, windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        let dragUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: dragPoint, modifierFlags: [], timestamp: now + 3.2, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 0))
        target.mouseDown(with: dragDown); target.mouseDragged(with: drag); target.mouseUp(with: dragUp)
        try await wait(0.15)
        XCTAssertTrue(state.displayedBitmap?.label.contains("native 100%") == true, "Drag must pan, not toggle Fit")
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await wait(0.4)
        let fit = try XCTUnwrap(state.displayedBitmap)
        XCTAssertFalse(fit.label.contains("100%"), "Z must return to Fit")
        XCTAssertLessThanOrEqual(fit.image.size.width, 1600)
    }

    @MainActor func testLargeA7RVViewportScrollAndModeChanges() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_VIEWPORT_PROBE"] == "1" else { throw XCTSkip("Read-only mounted A7RV viewport probe") }
        guard let fixture = ProcessInfo.processInfo.environment["LUMIBASE_A7RV_FIXTURE"] else { throw XCTSkip("Set LUMIBASE_A7RV_FIXTURE to a read-only paired A7RV folder") }
        let folder = URL(fileURLWithPath: fixture)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("A7RV not mounted") }
        let assets = await Task.detached { FolderScanner.quickScan(url: folder) }.value
        XCTAssertGreaterThan(assets.count, 300)
        let state = AppState()
        state.isHistogramEnabled = false
        state.allAssets = assets
        state.selectAsset(assets[assets.count / 2])
        let host = NSHostingView(rootView: FastViewport(state: state))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        var gaps: [Double] = [], rows: [[String: Any]] = []
        var previous = ProcessInfo.processInfo.systemUptime
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let gap = (now - previous) * 1000
            gaps.append(gap); previous = now
            if gap > 250 { FileHandle.standardError.write(Data("MAIN_HEARTBEAT_STALL_MS \(gap)\n".utf8)) }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate(); window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        func settle(_ seconds: Double) async throws {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < until {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        try await settle(1)
        let scroll = try XCTUnwrap(scrollViews(host).first { ($0.documentView?.bounds.height ?? 0) > $0.bounds.height * 2 })
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = document.bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(maximum, 1000)
        // Actual native clip viewport movement, not a service-only thumbnail benchmark.
        for fraction in [0.48, 0.52, 0.56, 0.50, 0.46, 0.54] {
            let started = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(0.15)
            rows.append(["phase": "grid-scroll", "fraction": fraction, "elapsedMs": (ProcessInfo.processInfo.systemUptime - started) * 1000, "viewportY": scroll.contentView.bounds.minY])
        }
        for cycle in 0..<3 {
            var started = ProcessInfo.processInfo.systemUptime
            state.viewMode = .loupe
            state.publishDisplayedBitmap(nil, assetID: nil, label: "")
            let deadline = started + 8
            while state.displayedBitmap == nil && ProcessInfo.processInfo.systemUptime < deadline { try await settle(0.01) }
            XCTAssertNotNil(state.displayedBitmap)
            rows.append(["phase": "grid-to-single", "cycle": cycle, "firstReadyMs": ((state.displayedBitmap?.readyUptime ?? ProcessInfo.processInfo.systemUptime) - started) * 1000])
            for step in 0..<8 {
                started = ProcessInfo.processInfo.systemUptime
                state.selectNextPhoto()
                try await settle(0.035)
                if let frame = state.displayedBitmap, frame.assetID == state.primarySelectedAssetID {
                    rows.append(["phase": "arrow-publication", "step": step, "firstReadyMs": (frame.readyUptime - started) * 1000])
                }
            }
            started = ProcessInfo.processInfo.systemUptime
            let lastID = state.primarySelectedAssetID
            while state.displayedBitmap?.assetID != lastID && ProcessInfo.processInfo.systemUptime - started < 5 { try await settle(0.01) }
            XCTAssertEqual(state.displayedBitmap?.assetID, lastID)
            rows.append(["phase": "rapid-arrows-final", "firstReadyMs": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            state.viewMode = .grid
            try await settle(0.3)
        }
        let ordered = gaps.sorted()
        let p95 = ordered.isEmpty ? 0 : ordered[Int(Double(ordered.count - 1) * 0.95)]
        let maxGap = gaps.max() ?? 0
        let evidence: [String: Any] = ["assets": assets.count, "rows": rows, "heartbeatMaxMs": maxGap, "heartbeatP95Ms": p95, "heartbeatSamples": gaps.count,
            "measurement": "Hosted actual Grid/Loupe/Filmstrip native viewport; timer main-run-loop gaps, real bitmap publications. OS and thumbnail caches not purged. No source writes. Not compositor latency."]
        let output = ProcessInfo.processInfo.environment["LUMIBASE_VIEWPORT_EVIDENCE"] ?? inspectionTestScratchURL("viewport.json").path
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("VIEWPORT_EVIDENCE \(output) max=\(maxGap) p95=\(p95) assets=\(assets.count)")
        XCTAssertLessThan(maxGap, 250, "User-visible main event loop stall")
    }
}
