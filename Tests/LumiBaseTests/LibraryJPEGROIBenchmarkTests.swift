import XCTest
import AppKit
import SwiftUI
import Darwin
@testable import LumiBase

final class LibraryJPEGROIBenchmarkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("LUMIBASE_JPEG_ROI_HELPER", FileManager.default.currentDirectoryPath + "/.build/release/LumiBaseJPEGROIHelper", 1)
    }
    override func tearDown() { unsetenv("LUMIBASE_JPEG_ROI_HELPER"); super.tearDown() }
    private func rss() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private func inputs() throws -> [PhotoAsset] {
        let folder = URL(fileURLWithPath: "/Volumes/Extreme SSD/Working/2026.10.02-05 Hot Air Ballon Festival/A7RV")
        return try ["DSC01442.JPG", "DSC01443.JPG", "DSC01444.JPG", "DSC01445.JPG", "DSC01446.JPG"].map { name in
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Read-only benchmark source missing: \(name)") }
            let raw = folder.appendingPathComponent(name.replacingOccurrences(of: ".JPG", with: ".ARW"))
            guard FileManager.default.fileExists(atPath: raw.path) else { throw XCTSkip("Read-only paired RAW missing") }
            return PhotoAsset(fileURL: raw, companionURLs: [url])
        }
    }
    private func output(_ value: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_REPORT"] else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
    @MainActor func testReadOnlyHostedComparison() async throws {
        guard let mode = ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_BENCH"], ["off", "on"].contains(mode) else { throw XCTSkip("Explicit read-only benchmark opt-in") }
        let enabled = mode == "on", assets = try inputs()
        let fast = ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_FAST"] == "1"
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.workspaceMode = .library; state.isHistogramEnabled = false; state.isFilmstripVisible = false
        state.allAssets = assets; state.selectAsset(assets[1]); state.viewMode = .loupe
        for asset in assets { _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset) }
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; LibraryJPEGROICache.shared.cancel(clear: true) }
        func surface(_ v: NSView) -> InspectionSurface.Surface? { if let s = v as? InspectionSurface.Surface { return s }; return v.subviews.compactMap(surface).first }
        try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(surface(host))
        let baseline = rss(); var peak = baseline; var heartbeats: [Double] = []; var previous = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime; heartbeats.append((now - previous) * 1000); previous = now; peak = max(peak, self.rss())
        }
        RunLoop.main.add(timer, forMode: .common); defer { timer.invalidate() }
        if enabled { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleLibraryJPEGROI"), object: nil) }
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 1_700_000_000)
        var rows: [[String: Any]] = []; var blackout = 0; var mismatches = 0; var geometryErrors = 0
        for index in [2, 3, 2, 1, 0, 1] {
            let hits = LibraryJPEGROICache.shared.hits, start = ProcessInfo.processInfo.systemUptime
            let workerInFlight = LibraryJPEGROICache.shared.workerActive
            state.selectAsset(assets[index]); var first: Double?; var firstROI = false; var full: Double?
            for _ in 0..<600 {
                try await Task.sleep(nanoseconds: 5_000_000); host.layoutSubtreeIfNeeded()
                let owner = target.owner
                if owner?.hasPresentedImage != true || owner?.presentsSpinner == true { blackout += 1 }
                if owner?.hasPresentedImage == true && owner?.presentedAssetID != assets[index].id { mismatches += 1 }
                if owner?.presentedZoomed != true || owner?.presentedFullExtent.size != CGSize(width: 9504, height: 6336) { geometryErrors += 1 }
                if owner?.presentedNative == true && owner?.presentedAssetID == assets[index].id {
                    if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000; firstROI = owner?.presentedSourceRect != nil }
                    if owner?.presentedSourceRect == nil { full = (ProcessInfo.processInfo.systemUptime - start) * 1000; break }
                }
            }
            XCTAssertNotNil(first); XCTAssertNotNil(full)
            rows.append(["index":index, "firstNativeMS":first ?? -1, "fullNativeMS":full ?? -1, "firstWasROI":firstROI, "hits":LibraryJPEGROICache.shared.hits - hits, "workerInFlightAtSelection":workerInFlight, "rss":rss(), "cacheBytes":LibraryJPEGROICache.shared.bytes])
            try await Task.sleep(nanoseconds: fast ? 50_000_000 : 1_400_000_000)
        }
        let sorted = heartbeats.sorted(), p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        try output(["mode":mode, "fastTrace":fast, "baselineRSS":baseline, "peakSampledRSS":peak, "finalRSS":rss(), "heartbeatP95MS":p95, "heartbeatMaxMS":sorted.last ?? 0, "blackoutSamples":blackout, "wrongIDSamples":mismatches, "geometryErrorSamples":geometryErrors, "rows":rows, "note":"Serial real hosted Loupe branch samples, not compositor latency; OS caches not purged. Full decoder transient peak can fall between RSS samples."])
        XCTAssertEqual(blackout, 0); XCTAssertEqual(mismatches, 0); XCTAssertEqual(geometryErrors, 0)
        XCTAssertLessThan(sorted.last ?? 0, 250, "Existing foreground heartbeat gate unchanged")
        if enabled { XCTAssertGreaterThan(rows.reduce(0) { $0 + ($1["hits"] as? Int ?? 0) }, 0) }
    }
    @MainActor func testReadOnlyHostedPanOutsideROIAndRelease() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_BENCH"] == "pan" else { throw XCTSkip("Explicit read-only pan benchmark opt-in") }
        let assets = try inputs(), state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.workspaceMode = .library; state.isHistogramEnabled = false; state.isFilmstripVisible = false
        state.allAssets = assets; state.selectAsset(assets[1]); state.viewMode = .loupe
        // Initial Fit + forward-only camera prefetch leave the previous neighbor's proxy cold.
        _ = await ThumbnailLoader.shared.loadCameraPreview(for: assets[1])
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; LibraryJPEGROICache.shared.cancel(clear: true) }
        func surface(_ v: NSView) -> InspectionSurface.Surface? { if let s = v as? InspectionSurface.Surface { return s }; return v.subviews.compactMap(surface).first }
        try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(surface(host))
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleLibraryJPEGROI"), object: nil)
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        target.mouseDown(with: down)
        try await Task.sleep(nanoseconds: 1_700_000_000)
        let evictions = inspectionTestScratchURL("jpeg-roi-eviction-\(UUID())")
        try FileManager.default.createDirectory(at: evictions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evictions) }
        let tiny = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(tiny.representation(using: .jpeg, properties: [:]))
        for index in 0..<13 {
            let url = evictions.appendingPathComponent("evict-\(index).JPG"); try bytes.write(to: url)
            _ = await ThumbnailLoader.shared.loadCameraPreview(for: PhotoAsset(fileURL: url))
        }
        XCTAssertNil(ThumbnailLoader.readyCameraGeometry(for: assets[0]), "exercise the actual cold/evicted previous-neighbor handoff")
        state.selectAsset(assets[0])
        var roiObserved = false; var emptySamples = 0; var wrongIDSamples = 0
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 5_000_000); host.layoutSubtreeIfNeeded()
            if target.owner?.hasPresentedImage != true || target.owner?.presentsSpinner == true { emptySamples += 1 }
            if target.owner?.hasPresentedImage == true && target.owner?.presentedAssetID != assets[0].id { wrongIDSamples += 1 }
            if target.owner?.presentedSourceRect != nil && target.owner?.presentedNative == true { roiObserved = true; break }
        }
        XCTAssertEqual(emptySamples, 0); XCTAssertEqual(wrongIDSamples, 0)
        XCTAssertTrue(roiObserved, "actual selected neighbor ROI must be visible before native full")
        target.owner?.drag(CGSize(width: -3500, height: -2200))
        try await Task.sleep(nanoseconds: 5_000_000); host.layoutSubtreeIfNeeded()
        let afterPan = target.owner
        XCTAssertTrue(afterPan?.hasPresentedImage ?? false)
        XCTAssertFalse(afterPan?.presentsSpinner ?? true)
        XCTAssertEqual(afterPan?.presentedAssetID, assets[0].id)
        XCTAssertTrue(afterPan?.presentedZoomed ?? false)
        XCTAssertNil(afterPan?.presentedSourceRect, "outside coverage must fall back to this selected asset's own preview/full, never expose cropped black borders")
        XCTAssertEqual(afterPan?.presentedFullExtent.size, CGSize(width: 9504, height: 6336))
        XCTAssertEqual(afterPan?.presentedImageSize, CGSize(width: 4752, height: 3168))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: -50, y: -50), modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        _ = target.routeCapturedEvent(up, leftPressed: false)
        try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(target.owner?.presentedZoomed ?? true)
        XCTAssertNil(target.owner?.presentedSourceRect)
        XCTAssertEqual(LibraryJPEGROICache.shared.bytes, 0)
        try output(["roiObserved":roiObserved,"coldEvictedNeighborEmptySamples":emptySamples,"coldEvictedNeighborWrongIDSamples":wrongIDSamples,"afterPanHasImage":afterPan?.hasPresentedImage ?? false,"afterPanNative":afterPan?.presentedNative ?? false,"afterPanSpinner":afterPan?.presentsSpinner ?? true,"afterReleaseZoomed":target.owner?.presentedZoomed ?? true,"cacheBytes":LibraryJPEGROICache.shared.bytes,"note":"Actual hosted surface capture + drag callback seam; no source writes, no compositor timing claim."])
    }

    func testReadOnlyOwnedBufferSteadyCycles() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_BENCH"] == "memory" else { throw XCTSkip("Explicit read-only memory benchmark opt-in") }
        let assets = try inputs(), cache = LibraryJPEGROICache()
        let baseline = rss(); var rows: [[String: Any]] = []
        for cycle in 0..<16 {
            let center = CGPoint(x: 0.45 + Double(cycle % 3) * 0.03, y: 0.5)
            await cache.preload([assets[cycle % 5], assets[(cycle + 1) % 5]], geometry: .init(center: center, viewport: CGSize(width: 1100, height: 850), backing: 2))
            try await Task.sleep(nanoseconds: 50_000_000)
            rows.append(["cycle":cycle, "rss":rss(), "cacheBytes":cache.bytes, "ownedBytes":LibraryJPEGROICache.ownedBytes])
            XCTAssertLessThanOrEqual(cache.bytes, 64 * 1024 * 1024)
        }
        cache.cancel(clear: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try output(["baselineRSS":baseline, "releasedRSS":rss(), "releasedOwnedBytes":LibraryJPEGROICache.ownedBytes, "rows":rows, "note":"RSS includes allocator/ImageIO retention. Exactly 2 ROI providers max in cache, no retained full JPEG by these providers."])
        XCTAssertEqual(LibraryJPEGROICache.ownedBytes, 0)
        let settled = rows.suffix(8).compactMap { $0["rss"] as? UInt64 }
        XCTAssertLessThan((settled.max() ?? 0) - (settled.min() ?? 0), 8 * 1024 * 1024, "Repeated cycles must plateau, not retain every decode")
    }
}
