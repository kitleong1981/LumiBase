import XCTest
import AppKit
import SwiftUI
import ImageIO
@testable import LumiBase

final class LibraryHeldGeometryTests: XCTestCase {
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
    @MainActor private func exercise(geometry: Bool, lifecycle: Bool = false) async throws {
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
        let target = try XCTUnwrap(surface(host))
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, time: Double, count: Int = 1, outside: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: outside ? CGPoint(x: -50, y: -50) : point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
        }
        target.mouseDown(with: try event(.leftMouseDown, time: 1))
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
