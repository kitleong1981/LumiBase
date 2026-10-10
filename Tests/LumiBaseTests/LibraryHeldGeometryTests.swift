import XCTest
import AppKit
import SwiftUI
import ImageIO
import CoreImage
@testable import LumiBase

private final class HeldFixtureTrashManager: FileManager, @unchecked Sendable {
    let destination: URL
    init(destination: URL) { self.destination = destination; super.init() }
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
}

final class LibraryHeldGeometryTests: XCTestCase {
    func testCroppedHandoffExtentMatchesProductionPipelineBounds() {
        for source in [CGRect(x: 0, y: 0, width: 9504, height: 6336), CGRect(x: -21, y: 47, width: 3200, height: 4800)] {
            for angle in [0.0, 12.0] {
                for boundedCrop in [false, true] {
                    var xmp = XMPMetadata.empty; xmp.hasCrop = true; xmp.cropAngle = angle
                    if boundedCrop { xmp.cropLeft = 0.2; xmp.cropRight = 0.8; xmp.cropTop = 0.15; xmp.cropBottom = 0.85 }
                    let output = AdobeColorPipeline.shared.process(image: CIImage(color: .gray).cropped(to: source), cameraModel: nil, xmp: xmp)
                    XCTAssertEqual(InspectionFrameLayout.processedFullExtent(source: source, xmp: xmp).size, output.extent.integral.size,
                        "handoff metadata must match existing crop/straighten pipeline bounds")
                }
            }
        }
    }
    @MainActor func testFirstResidentFitProxyMouseDownAnchorsClickedSourceBeforeNative() async throws {
        let root = inspectionTestScratchURL("click-anchor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Landscape, portrait, EXIF-6 portrait, plus documented viewport-edge clamp.
        for (index, config) in [(4800, 3200, 1), (3200, 4800, 1), (4800, 3200, 6), (4800, 3200, 1)].enumerated() {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: config.0, pixelsHigh: config.1, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.bitmapData!.initialize(repeating: 80, count: rep.bytesPerRow * rep.pixelsHigh)
            let url = root.appendingPathComponent("anchor\(index).JPG")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(rep.cgImage), [kCGImagePropertyOrientation: config.2] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let otherURL = root.appendingPathComponent("other\(index).JPG")
            try FileManager.default.copyItem(at: url, to: otherURL)
            let asset = PhotoAsset(fileURL: url), other = PhotoAsset(fileURL: otherURL)
            try await exerciseClickAnchor(asset: asset, other: other,
                desired: index == 3 ? CGPoint(x: 0.01, y: 0.99) : CGPoint(x: 0.34, y: 0.65),
                releaseBeforeDecode: index == 2)
        }
    }

    @MainActor func testImmutableRealPairClickAnchorAndEditedCrop() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_FULL_SHARPNESS_FIXTURE"] else {
            throw XCTSkip("Set LUMIBASE_FULL_SHARPNESS_FIXTURE to immutable DSC01801/1803 pair copies")
        }
        let root = URL(fileURLWithPath: path)
        let a = PhotoAsset(fileURL: root.appendingPathComponent("DSC01801.JPG"))
        let b = PhotoAsset(fileURL: root.appendingPathComponent("DSC01803.JPG"))
        try await exerciseClickAnchor(asset: a, other: b, desired: CGPoint(x: 0.34, y: 0.65))
        // Actual processed producer, no ready-store manual seed; edits remain in memory.
        var edited = a
        edited.xmp.exposure2012 = 0.35; edited.xmp.hasCrop = true
        edited.xmp.cropLeft = 0.2; edited.xmp.cropRight = 0.8
        edited.xmp.cropTop = 0.15; edited.xmp.cropBottom = 0.85
        try await exerciseClickAnchor(asset: edited, other: b, desired: CGPoint(x: 0.34, y: 0.65), edited: true)
        var raw = PhotoAsset(fileURL: root.appendingPathComponent("DSC01801.ARW"), companionURLs: [a.fileURL])
        raw.xmp = edited.xmp
        try await exerciseClickAnchor(asset: raw, other: b, desired: CGPoint(x: 0.34, y: 0.65), edited: true)
    }

    @MainActor private func exerciseClickAnchor(asset: PhotoAsset, other: PhotoAsset, desired: CGPoint,
                                                releaseBeforeDecode: Bool = false, edited: Bool = false) async throws {
        let saved = PerformanceSettings.shared.sharpnessEnabled
        PerformanceSettings.shared.sharpnessEnabled = false
        defer { PerformanceSettings.shared.sharpnessEnabled = saved }
        func surface(_ view: NSView) -> InspectionSurface.Surface? {
            if let value = view as? InspectionSurface.Surface { return value }
            return view.subviews.compactMap(surface).first
        }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.workspaceMode = .library; state.isHistogramEnabled = false
        state.allAssets = [other, asset]; state.selectAsset(edited ? asset : other); state.viewMode = .loupe
        var pauseSelection = false
        let host = NSHostingView(rootView: LoupeView(appState: state, selectionLoadBarrier: { id in
            // Widen only the real selection-publication -> async-load interval.
            // Every proxy/native frame still comes from the production producer.
            while id == asset.id && pauseSelection && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { pauseSelection = false; window.contentView = nil }
        func settle(_ milliseconds: UInt64) async throws {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000); host.layoutSubtreeIfNeeded()
        }
        try await settle(100)
        let target = try XCTUnwrap(surface(host))
        if edited {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while PreviewPreloader.readyPreviewFrame(for: asset, xmp: asset.xmp) == nil,
                  ProcessInfo.processInfo.systemUptime < deadline { try await settle(5) }
            XCTAssertNotNil(PreviewPreloader.readyPreviewFrame(for: asset, xmp: asset.xmp), "actual edited host producer must warm full-frame handoff")
            state.selectAsset(other); try await settle(100)
        } else {
            _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset)
            XCTAssertNotNil(ThumbnailLoader.readyCameraGeometry(for: asset), "actual camera producer must publish resident proxy")
        }
        pauseSelection = true
        state.selectAsset(asset); try await settle(10)
        let fit = try XCTUnwrap(target.owner)
        XCTAssertTrue(fit.hasPresentedImage); XCTAssertTrue(fit.presentedHandoffProxy)
        XCTAssertEqual(fit.presentedAssetID, asset.id)
        XCTAssertFalse(fit.presentedZoomed)
        let extent = fit.presentedFullExtent.size
        XCTAssertGreaterThan(extent.width, 1600)
        let fitPoint = CGPoint(x: fit.presentedImagePosition.x + (desired.x - 0.5) * fit.presentedImageSize.width,
                               y: fit.presentedImagePosition.y + (desired.y - 0.5) * fit.presentedImageSize.height)
        let point = target.convert(fitPoint, to: nil)
        func event(_ type: NSEvent.EventType, time: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        func assertAnchor(_ frame: InspectionSurface) {
            XCTAssertEqual(frame.presentedAssetID, asset.id)
            XCTAssertEqual(frame.presentedFullExtent.size, extent)
            XCTAssertEqual(frame.presentedImageSize.width, extent.width / window.backingScaleFactor, accuracy: 0.01)
            XCTAssertEqual(frame.presentedImageSize.height, extent.height / window.backingScaleFactor, accuracy: 0.01)
            // Clamp at the source edge is intentional: never expose a black margin.
            func clamp(_ value: CGFloat, size: CGFloat, viewport: CGFloat) -> CGFloat {
                guard size > viewport else { return 0.5 }
                return min(1 - viewport / (2 * size), max(viewport / (2 * size), value))
            }
            let center = CGPoint(x: clamp(desired.x, size: frame.presentedImageSize.width, viewport: target.bounds.width),
                                 y: clamp(desired.y, size: frame.presentedImageSize.height, viewport: target.bounds.height))
            let clickedPixel = CGPoint(x: frame.presentedImagePosition.x + (desired.x - 0.5) * frame.presentedImageSize.width,
                                       y: frame.presentedImagePosition.y + (desired.y - 0.5) * frame.presentedImageSize.height)
            XCTAssertEqual(clickedPixel.x, target.bounds.midX + (desired.x - center.x) * frame.presentedImageSize.width, accuracy: 1,
                           "actual hosted proxy/native must map the clicked source pixel, not image center")
            XCTAssertEqual(clickedPixel.y, target.bounds.midY + (desired.y - center.y) * frame.presentedImageSize.height, accuracy: 1,
                           "letterbox/oriented top-origin source anchor")
        }
        target.mouseDown(with: try event(.leftMouseDown, time: 1))
        try await settle(10)
        let first = try XCTUnwrap(target.owner)
        XCTAssertTrue(first.presentedHandoffProxy); XCTAssertTrue(first.presentedZoomed); XCTAssertFalse(first.presentedNative)
        assertAnchor(first)
        print("ANCHOR_FIRST handoff=true native=false source=\(extent) backing=\(window.backingScaleFactor) click=\(desired) edited=\(edited)")
        if releaseBeforeDecode {
            _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 1.02), leftPressed: false)
            try await settle(10)
            XCTAssertFalse(target.owner?.presentedZoomed ?? true)
            pauseSelection = false
            for _ in 0..<50 {
                try await settle(5)
                XCTAssertFalse(target.owner?.presentedZoomed ?? true, "late decode must not resurrect released hold")
            }
            XCTAssertFalse(target.hasCaptureMonitor)
            return
        }
        // Resize while the real selected decode is still queued: anchor must survive.
        window.setContentSize(CGSize(width: 760, height: 720)); try await settle(10)
        assertAnchor(try XCTUnwrap(target.owner))
        pauseSelection = false
        var checkedNative = false
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await settle(1)
            let frame = try XCTUnwrap(target.owner)
            if frame.presentedZoomed && frame.hasPresentedImage {
                assertAnchor(frame)
                if frame.presentedNative { checkedNative = true; break }
            }
        }
        XCTAssertTrue(checkedNative, "real native/full processed frame must arrive with the same anchor")
        _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 2), leftPressed: false)
        try await settle(30)
        XCTAssertFalse(target.owner?.presentedZoomed ?? true)
        XCTAssertFalse(target.hasCaptureMonitor)
    }

    func testPairedJPEGOrientationIsCarriedByProxyAndMatchesNativePixels() async throws {
        let root = inspectionTestScratchURL("oriented-camera-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("portrait.ARW"), jpeg = root.appendingPathComponent("portrait.JPG")
        try Data("invalid RAW; never decode".utf8).write(to: raw)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(rep.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = PhotoAsset(fileURL: raw, companionURLs: [jpeg])
        _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset)
        XCTAssertEqual(ThumbnailLoader.readyCameraFullExtent(for: asset).size, CGSize(width: 32, height: 48))
        let loaded = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        let native = try XCTUnwrap(loaded)
        XCTAssertEqual(native.size, CGSize(width: 32, height: 48))
    }
    @MainActor func testShortClickNeverLatchesLibraryInspection() async throws {
        try await exercise(geometry: false)
    }
    @MainActor func testHeldRapidSelectionUsesSourceGeometryThroughoutHandoff() async throws {
        try await exercise(geometry: true)
    }
    @MainActor func testHostedLibraryDoubleClickWheelDragAndModeCancellation() async throws {
        try await exercise(geometry: false, lifecycle: true)
    }
    @MainActor func testHeldTrashConfirmationKeeps100UntilPhysicalRelease() async throws {
        try await exercise(geometry: false, trashConfirmation: true)
    }
    @MainActor func testHeldTrashConfirmationWithExperimentalJPEGROI() async throws {
        let previousHelper = ProcessInfo.processInfo.environment["LUMIBASE_JPEG_ROI_HELPER"]
        if previousHelper == nil { setenv("LUMIBASE_JPEG_ROI_HELPER", FileManager.default.currentDirectoryPath + "/.build/release/LumiBaseJPEGROIHelper", 1) }
        defer {
            if let previousHelper { setenv("LUMIBASE_JPEG_ROI_HELPER", previousHelper, 1) } else { unsetenv("LUMIBASE_JPEG_ROI_HELPER") }
            LibraryJPEGROICache.shared.cancel(clear: true)
        }
        try await exercise(geometry: false, trashConfirmation: true, jpegROI: true)
    }
    @MainActor func testConfirmationFocusExceptionDoesNotSuppressAppDeactivateOrWindowClose() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let surface = InspectionSurface.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(surface)
        defer { surface.endCapture(); window.contentView = nil }
        var held = false
        surface.owner = InspectionSurface(down: { _, _ in held = true }, drag: { _ in }, up: { held = false }, navigate: { _ in }, backingChanged: { _ in }, retainsHoldForConfirmation: { true })
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification] {
            surface.mouseDown(with: down)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertTrue(held)
            NotificationCenter.default.post(name: name, object: name == NSWindow.willCloseNotification ? window : nil)
            XCTAssertFalse(held)
            XCTAssertFalse(surface.hasCaptureMonitor)
        }
    }
    @MainActor private func exercise(geometry: Bool, lifecycle: Bool = false, trashConfirmation: Bool = false, jpegROI: Bool = false) async throws {
        let root = inspectionTestScratchURL("held-geometry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4800, pixelsHigh: 3200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        var assets: [PhotoAsset] = []
        for name in ["a", "b", "c"] {
            let url = root.appendingPathComponent(name + ".JPG")
            try data.write(to: url); assets.append(PhotoAsset(fileURL: url))
        }
        for asset in assets { _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.workspaceMode = .library; state.isHistogramEnabled = false; state.isFilmstripVisible = false
        state.allAssets = assets; state.selectAsset(assets[0]); state.viewMode = .loupe
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func surface(_ v: NSView) -> InspectionSurface.Surface? {
            if let s = v as? InspectionSurface.Surface { return s }
            return v.subviews.compactMap(surface).first
        }
        func settle(_ ms: UInt64) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000); host.layoutSubtreeIfNeeded() }
        try await settle(350)
        if jpegROI { NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleLibraryJPEGROI"), object: nil) }
        let target = try XCTUnwrap(surface(host))
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, time: Double, count: Int = 1, outside: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: outside ? CGPoint(x: -50, y: -50) : point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
        }
        target.mouseDown(with: try event(.leftMouseDown, time: 1))
        if trashConfirmation {
            try await settle(150)
            XCTAssertTrue(target.owner?.presentedZoomed ?? false)
            state.requestDeleteSelectedPhotos()
            let trash = root.appendingPathComponent("fixture-trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let manager = HeldFixtureTrashManager(destination: trash)
            let alert = NSAlert()
            alert.messageText = "Move generated fixture to Trash?"
            alert.addButton(withTitle: "Move to Trash").keyEquivalent = "\r"
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { state.confirmDeletePendingPhotos(fileManager: manager) }
                else { state.cancelDelete() }
            }
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) } }
            // Deterministic delivery of the exact notification: synthetic down does
            // not make a background host key, but its native sheet is really attached.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try await settle(150)
            XCTAssertNotNil(window.attachedSheet)
            XCTAssertTrue(target.owner?.presentedZoomed ?? false, "dialog key focus must not release a still-held left button")
            XCTAssertTrue(target.hasCaptureMonitor, "app-wide mouse-up capture must survive dialog focus")
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1.4, windowNumber: alert.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[0].keyEquivalentModifierMask = []
            XCTAssertTrue(alert.buttons[0].performKeyEquivalent(with: enter), "Return invokes the native sheet default action")
            try await settle(150)
            await state.waitForTrashCompletion()
            try await settle(250)
            XCTAssertEqual(state.primarySelectedAssetID, assets[1].id)
            XCTAssertEqual(target.owner?.presentedAssetID, assets[1].id)
            XCTAssertTrue(target.owner?.presentedZoomed ?? false, "confirm advances next photo without dropping hold")
            XCTAssertEqual(target.owner?.presentedFullExtent.size, CGSize(width: 4800, height: 3200))
            _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 2, outside: true), leftPressed: false)
            try await settle(150)
            XCTAssertFalse(target.owner?.presentedZoomed ?? true)
            XCTAssertFalse(target.hasCaptureMonitor)
            // Release while the second confirmation is open must never resurrect the hold.
            target.mouseDown(with: try event(.leftMouseDown, time: 4))
            state.requestDeleteSelectedPhotos()
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 4.1, outside: true), leftPressed: false)
            state.confirmDeletePendingPhotos(fileManager: manager)
            await state.waitForTrashCompletion()
            try await settle(150)
            XCTAssertEqual(state.primarySelectedAssetID, assets[2].id)
            XCTAssertFalse(target.owner?.presentedZoomed ?? true, "release during dialog remains Fit after confirmation")
            XCTAssertFalse(target.hasCaptureMonitor)
            return
        }
        if !geometry {
            target.mouseUp(with: try event(.leftMouseUp, time: 1.03))
            try await settle(350)
            XCTAssertFalse(target.owner?.presentedZoomed ?? true, "ordinary short left click must return Fit, never persist")
            XCTAssertFalse(target.hasCaptureMonitor)
            XCTAssertFalse(state.displayedBitmap?.label.contains("100%") ?? true, "released native load cannot relatch")
            if lifecycle {
                target.mouseDown(with: try event(.leftMouseDown, time: 1.1, count: 2))
                target.mouseUp(with: try event(.leftMouseUp, time: 1.13, count: 2))
                try await settle(200)
                XCTAssertTrue(target.owner?.presentedZoomed ?? false, "completed double-click retains explicit persistence")
                NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
                try await settle(100)
                target.mouseDown(with: try event(.leftMouseDown, time: 4))
                target.mouseDragged(with: try event(.leftMouseDragged, time: 4.1, outside: true))
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
                cg.location = point
                let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
                target.scrollWheel(with: wheel)
                try await settle(150)
                XCTAssertEqual(state.primarySelectedAssetID, assets[1].id)
                XCTAssertTrue(target.owner?.presentedZoomed ?? false, "held wheel navigation keeps hold")
                XCTAssertTrue(target.hasCaptureMonitor)
                _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 4.2, outside: true), leftPressed: false)
                try await settle(150)
                XCTAssertFalse(target.owner?.presentedZoomed ?? true)
                XCTAssertFalse(target.hasCaptureMonitor)
                target.mouseDown(with: try event(.leftMouseDown, time: 6))
                state.workspaceMode = .develop
                try await settle(150)
                XCTAssertFalse(target.owner?.presentedZoomed ?? true, "mode transition cancels temporary hold")
                XCTAssertFalse(target.hasCaptureMonitor, "mode transition cleans native capture")
                target.endCapture()
            }
            return
        }
        for asset in assets {
            state.selectAsset(asset)
            for _ in 0..<15 {
                try await settle(5)
                let owner = try XCTUnwrap(target.owner)
                XCTAssertTrue(owner.presentedZoomed)
                XCTAssertTrue(owner.hasPresentedImage)
                XCTAssertEqual(owner.presentedAssetID, asset.id)
                XCTAssertFalse(owner.presentsSpinner)
                XCTAssertEqual(owner.presentedImageSize.width, 4800 / window.backingScaleFactor, accuracy: 0.01, "proxy must use oriented full source extent, never Fit/proxy pixels")
                XCTAssertEqual(owner.presentedFullExtent.size, CGSize(width: 4800, height: 3200))
                if owner.preparingNative { XCTAssertFalse(owner.presentedNative) }
            }
        }
        print("HELD_GEOMETRY full=4800x3200 hosted=\(target.owner!.presentedImageSize) backing=\(window.backingScaleFactor)")
        _ = target.routeCapturedEvent(try event(.leftMouseUp, time: 3, outside: true), leftPressed: false)
        try await settle(350)
        XCTAssertFalse(target.owner?.presentedZoomed ?? true)
        XCTAssertFalse(target.hasCaptureMonitor)
        XCTAssertFalse(state.displayedBitmap?.label.contains("100%") ?? true)
    }
}
