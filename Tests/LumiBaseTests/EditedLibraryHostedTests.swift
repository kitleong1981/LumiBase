import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class EditedLibraryHostedTests: XCTestCase {
    @MainActor func testIsolatedRAWOnlyFitEmbeddedAndHonestNativeOnDemand() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_INTERACTIVE_RAW"] else { throw XCTSkip("Set LUMIBASE_INTERACTIVE_RAW for isolated RAW-only inspection") }
        let root = inspectionTestScratchURL("raw-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); ImageWorkDiagnostics.stop() }
        let url = root.appendingPathComponent("only.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        let asset = PhotoAsset(fileURL: url)
        let image = await ThumbnailLoader.shared.loadCameraPreview(for: asset)
        XCTAssertNotNil(image)
        let nativeJPEG = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        XCTAssertNil(nativeJPEG, "Reduced embedded JPEG must never masquerade as full source 100%")
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false)); state.isHistogramEnabled = false
        state.allAssets = [asset]; state.selectAsset(asset); state.viewMode = .loupe
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        ImageWorkDiagnostics.start()
        let end = ProcessInfo.processInfo.systemUptime+10
        while state.displayedBitmap == nil && ProcessInfo.processInfo.systemUptime < end { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(try XCTUnwrap(state.displayedBitmap).accurate)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        let started = ProcessInfo.processInfo.systemUptime
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        let nativeEnd = started+30
        while (state.displayedBitmap?.accurate != true || state.displayedBitmap?.scorePreview != false) && ProcessInfo.processInfo.systemUptime < nativeEnd { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        let frame = try XCTUnwrap(state.displayedBitmap)
        XCTAssertTrue(frame.accurate); XCTAssertFalse(frame.scorePreview)
        func surface(_ view: NSView) -> InspectionSurface.Surface? {
            if let target = view as? InspectionSurface.Surface { return target }
            return view.subviews.compactMap(surface).first
        }
        host.layoutSubtreeIfNeeded()
        let presentation = try XCTUnwrap(surface(host)?.owner)
        XCTAssertTrue(presentation.presentedNative)
        XCTAssertEqual(presentation.presentedFullExtent.size, CGSize(width: 9504, height: 6336))
        XCTAssertEqual(presentation.presentedAssetID, asset.id)
        XCTAssertGreaterThan(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        print("RAW_ONLY_HOST embeddedFit=\(image?.size ?? .zero) nativeBitmap=\(frame.image.size) nativeMs=\((frame.readyUptime-started)*1000)")
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        let fitEnd = ProcessInfo.processInfo.systemUptime+5
        while state.displayedBitmap?.accurate != false && ProcessInfo.processInfo.systemUptime < fitEnd { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(try XCTUnwrap(state.displayedBitmap).accurate)
    }
    @MainActor func testReadOnlyRAWEditedColdWarmNativeAndMixedSelection() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_INTERACTIVE_RAW"] else { throw XCTSkip("Set LUMIBASE_INTERACTIVE_RAW for read-only edited RAW host probe") }
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        var xmp = XMPMetadata.empty; xmp.exposure2012 = 1
        xmp.hasCrop = true; xmp.cropLeft = 0.25; xmp.cropRight = 0.75; xmp.cropTop = 0.25; xmp.cropBottom = 0.75
        let asset = PhotoAsset(fileURL: url, companionURLs: [url.deletingPathExtension().appendingPathExtension("JPG")], xmp: xmp)
        let unedited = PhotoAsset(fileURL: url, companionURLs: asset.companionURLs)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false)); state.isHistogramEnabled = false
        state.allAssets = [asset]; state.selectAsset(asset); state.viewMode = .loupe
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; ImageWorkDiagnostics.stop() }
        var gaps: [Double] = []; var last = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in let now = ProcessInfo.processInfo.systemUptime; gaps.append((now-last)*1000); last = now }
        RunLoop.main.add(timer, forMode: .common); defer { timer.invalidate() }
        func wait(_ accurate: Bool, native: Bool = false) async throws -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 30 {
                host.layoutSubtreeIfNeeded()
                if let frame = state.displayedBitmap, frame.accurate == accurate,
                   (!native || Int(frame.image.size.width) == 4752) { return (frame.readyUptime-start)*1000 }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("RAW actual host did not publish expected edited/native pixels"); return -1
        }
        ImageWorkDiagnostics.start()
        let cold = try await wait(true)
        let fit = try XCTUnwrap(state.displayedBitmap?.image)
        XCTAssertEqual(fit.size.width / fit.size.height, 1.5, accuracy: 0.02)
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        let native = try await wait(true, native: true)
        let nativeImage = try XCTUnwrap(state.displayedBitmap?.image)
        XCTAssertEqual(nativeImage.size, NSSize(width: 4752, height: 3168))
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        state.allAssets[0] = unedited
        _ = try await wait(false)
        state.allAssets[0] = asset
        let warm = try await wait(true)
        for _ in 0..<8 { state.allAssets[0] = unedited; await Task.yield(); state.allAssets[0] = asset; await Task.yield() }
        _ = try await wait(true)
        XCTAssertFalse(state.displayedBitmap?.label.contains("JPEG") ?? true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        print("EDITED_RAW_HOST coldMs=\(cold) warmMs=\(warm) nativeCropMs=\(native) maxHeartbeatMs=\(gaps.max() ?? 0) work=\(ImageWorkDiagnostics.snapshot())")
    }
    @MainActor func testDevelopExposureCropReturnsLibraryAndReeditInvalidatesActualLoupePixels() async throws {
        let root = inspectionTestScratchURL("edited-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.bitmapData!.initialize(repeating: 40, count: rep.bytesPerRow * rep.pixelsHigh)
        let url = root.appendingPathComponent("photo.jpg")
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url)
        let original = try Data(contentsOf: url)
        let asset = PhotoAsset(fileURL: url)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]; state.selectAsset(asset); state.viewMode = .loupe; state.workspaceMode = .develop
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func ready() async throws -> NSImage {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while ProcessInfo.processInfo.systemUptime < deadline {
                host.layoutSubtreeIfNeeded()
                if let frame = state.displayedBitmap, frame.assetID == asset.id, frame.accurate { return frame.image }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("Actual hosted edited frame was never published")
            return NSImage()
        }
        _ = try await ready()
        var edits = XMPMetadata.empty; edits.exposure2012 = 2
        edits.hasCrop = true; edits.cropLeft = 0.25; edits.cropRight = 0.75; edits.cropTop = 0.25; edits.cropBottom = 0.75
        state.liveDevelopAssetID = asset.id; state.liveDevelopXMP = edits
        state.workspaceMode = .library
        let first = try await ready()
        XCTAssertEqual(state.primarySelectedAsset?.xmp.exposure2012, 2)
        XCTAssertEqual(first.size.width / first.size.height, 4.0 / 3.0, accuracy: 0.02)
        XCTAssertLessThan(first.size.width, 320)
        XCTAssertFalse(state.displayedBitmap?.label.contains("JPEG") ?? true)
        state.workspaceMode = .develop
        edits.exposure2012 = -2
        state.liveDevelopAssetID = asset.id; state.liveDevelopXMP = edits
        state.workspaceMode = .library
        let second = try await ready()
        func brightness(_ image: NSImage) throws -> CGFloat {
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)).brightnessComponent
        }
        XCTAssertGreaterThan(try brightness(first), try brightness(second) + 0.1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testHostedEditedGridAndFilmstripUseCropAndReeditIdentity() async throws {
        let root = inspectionTestScratchURL("edited-cells-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.bitmapData!.initialize(repeating: 70, count: rep.bytesPerRow * rep.pixelsHigh)
        let url = root.appendingPathComponent("cell.jpg")
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url)
        var xmp = XMPMetadata.empty; xmp.exposure2012 = 1; xmp.hasCrop = true
        xmp.cropLeft = 0.25; xmp.cropRight = 0.75; xmp.cropTop = 0; xmp.cropBottom = 1
        let asset = PhotoAsset(fileURL: url, xmp: xmp)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]; state.selectAsset(asset)
        let host = NSHostingView(rootView: GridView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while state.displayedBitmap == nil && ProcessInfo.processInfo.systemUptime < deadline { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        let first = try XCTUnwrap(state.displayedBitmap)
        XCTAssertTrue(first.accurate)
        XCTAssertEqual(first.image.size.width / first.image.size.height, 2.0 / 3.0, accuracy: 0.03)
        // Exercise the actual filmstrip cell with the same completion hook used by its host.
        var film: NSImage?
        let strip = NSHostingView(rootView: FilmstripItemView(asset: asset, isSelected: true, isPrimary: true, onSelect: { _, _ in }, onPreview: { film = $0 }))
        window.contentView = strip
        let due = ProcessInfo.processInfo.systemUptime + 8
        while film == nil && ProcessInfo.processInfo.systemUptime < due { strip.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000) }
        let filmImage = try XCTUnwrap(film)
        XCTAssertEqual(filmImage.size.width / filmImage.size.height, 2.0 / 3.0, accuracy: 0.03)
    }
}
