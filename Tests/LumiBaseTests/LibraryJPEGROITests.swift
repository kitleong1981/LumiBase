import XCTest
import AppKit
import ImageIO
import SwiftUI
@testable import LumiBase

final class LibraryJPEGROITests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("LUMIBASE_JPEG_ROI_HELPER", FileManager.default.currentDirectoryPath + "/.build/release/LumiBaseJPEGROIHelper", 1)
    }
    override func tearDown() { unsetenv("LUMIBASE_JPEG_ROI_HELPER"); super.tearDown() }
    @MainActor func testHostedOptInNeighborHitsBeforeFullNative() async throws {
        let root = inspectionTestScratchURL("jpeg-roi-host-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4800, pixelsHigh: 3200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        var assets: [PhotoAsset] = []
        for name in ["a", "b", "c"] { let url = root.appendingPathComponent(name + ".JPG"); try data.write(to: url); assets.append(PhotoAsset(fileURL: url)) }
        for asset in assets { _ = await ThumbnailLoader.shared.loadCameraPreview(for: asset) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.workspaceMode = .library; state.isHistogramEnabled = false; state.isFilmstripVisible = false
        state.allAssets = assets; state.selectAsset(assets[1]); state.viewMode = .loupe
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; LibraryJPEGROICache.shared.cancel(clear: true) }
        func surface(_ view: NSView) -> InspectionSurface.Surface? { if let s = view as? InspectionSurface.Surface { return s }; return view.subviews.compactMap(surface).first }
        try await Task.sleep(nanoseconds: 300_000_000); host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleLibraryJPEGROI"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(LibraryJPEGROICache.shared.bytes, 0, "actual current-native completion must produce ±1 ROI")
        let hits = LibraryJPEGROICache.shared.hits
        state.selectAsset(assets[2])
        try await Task.sleep(nanoseconds: 30_000_000); host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(surface(host))
        XCTAssertGreaterThan(LibraryJPEGROICache.shared.hits, hits, "selected neighbor must consume actual producer output")
        XCTAssertEqual(target.owner?.presentedAssetID, assets[2].id)
        XCTAssertEqual(target.owner?.presentedFullExtent.size, CGSize(width: 4800, height: 3200))
        XCTAssertTrue(target.owner?.presentedZoomed ?? false)
        XCTAssertTrue(target.owner?.hasPresentedImage ?? false)
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(target.owner?.presentedZoomed ?? true)
        XCTAssertNil(target.owner?.presentedSourceRect)
        XCTAssertEqual(LibraryJPEGROICache.shared.bytes, 0, "Fit clears experiment without relatching zoom")
    }

    func testBudgetEvictionStaleSourceAndCanceledQueue() async throws {
        let root = inspectionTestScratchURL("jpeg-roi-budget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let assets = try ["a", "b", "c"].map { name -> PhotoAsset in
            let url = root.appendingPathComponent(name + ".JPG"); try data.write(to: url); return PhotoAsset(fileURL: url)
        }
        let geometry = LibraryJPEGROICache.Geometry(center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 300, height: 200), backing: 2)
        let preview = await ThumbnailLoader.shared.loadCameraPreview(for: assets[0])
        let previewCG = try XCTUnwrap(preview?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let singleCost = (600 + 512) * (400 + 512) * 4 + previewCG.bytesPerRow * previewCG.height
        let cache = LibraryJPEGROICache(budget: singleCost)
        await cache.preload([assets[0], assets[1]], geometry: geometry)
        XCTAssertEqual(cache.bytes, singleCost)
        XCTAssertNil(cache.match(assets[0], geometry: geometry), "LRU must evict old entry to satisfy byte budget")
        XCTAssertNotNil(cache.match(assets[1], geometry: geometry))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: assets[1].fileURL.path)
        XCTAssertNil(cache.match(assets[1], geometry: geometry), "actual companion/source version invalidates hit")
        cache.cancel(clear: true)
        let canceled = Task { await cache.preload([assets[2]], geometry: geometry) }
        canceled.cancel(); await canceled.value
        XCTAssertEqual(cache.bytes, 0)
        let running = Task { await cache.preload([assets[2], assets[0]], geometry: geometry) }
        try await Task.sleep(nanoseconds: 1_000_000)
        cache.cancel(clear: true)
        await running.value
        XCTAssertEqual(cache.bytes, 0, "stale helper completion and queued neighbor may not publish after cancel")
        let tooSmall = LibraryJPEGROICache(budget: singleCost - 1)
        await tooSmall.preload([assets[0]], geometry: geometry)
        XCTAssertEqual(tooSmall.bytes, 0)
    }

    func testOrientedProducerPixelParityWithFullNative() async throws {
        let root = inspectionTestScratchURL("jpeg-roi-parity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("portrait.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 1200, bitsPerComponent: 8, bytesPerRow: 1800 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let asset = PhotoAsset(fileURL: url), cache = LibraryJPEGROICache()
        let geometry = LibraryJPEGROICache.Geometry(center: CGPoint(x: 0.4, y: 0.6), viewport: CGSize(width: 100, height: 80), backing: 2)
        await cache.preload([asset], geometry: geometry)
        let frame = try XCTUnwrap(cache.match(asset, geometry: geometry))
        XCTAssertEqual(frame.orientation, 6)
        XCTAssertEqual(frame.fullExtent.size, CGSize(width: 1200, height: 1800))
        let loaded = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        let full = try XCTUnwrap(loaded?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let reference = try XCTUnwrap(CGContext(data: nil, width: frame.image.width, height: frame.image.height, bitsPerComponent: 8, bytesPerRow: frame.image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reference.interpolationQuality = .none
        reference.draw(full, in: CGRect(x: -frame.sourceRect.minX, y: -frame.sourceRect.minY, width: frame.fullExtent.width, height: frame.fullExtent.height))
        let expected = Data(bytes: try XCTUnwrap(reference.data), count: frame.roiBytes)
        let actual = try XCTUnwrap(frame.image.dataProvider?.data) as Data
        XCTAssertEqual(actual, expected, "oriented native pixels, row direction and ROI offset must match")
        cache.cancel(clear: true)
    }

    func testNeighborProducerCreatesOwnedPixelsAndHandsOffOnlyMatchingGeometry() async throws {
        let root = inspectionTestScratchURL("jpeg-roi-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.JPG")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url)
        let asset = PhotoAsset(fileURL: url)
        let cache = LibraryJPEGROICache(budget: 16 * 1024 * 1024)
        let geometry = LibraryJPEGROICache.Geometry(center: CGPoint(x: 0.5, y: 0.5), viewport: CGSize(width: 300, height: 200), backing: 2)
        await cache.preload([asset], geometry: geometry)
        let frame = try XCTUnwrap(cache.match(asset, geometry: geometry))
        XCTAssertEqual(frame.fullExtent.size, CGSize(width: 1800, height: 1200))
        XCTAssertEqual(frame.image.bytesPerRow, frame.image.width * 4)
        XCTAssertEqual(frame.roiBytes, frame.image.width * frame.image.height * 4)
        XCTAssertLessThan(frame.roiBytes, 1800 * 1200 * 4)
        XCTAssertNotNil(frame.preview)
        XCTAssertGreaterThan(frame.cost, frame.roiBytes)
        XCTAssertNil(cache.match(asset, geometry: .init(center: .zero, viewport: CGSize(width: 300, height: 200), backing: 2)))
        var display = InspectionDisplay()
        let ticket = display.beginSelection(assetID: asset.id, filename: asset.filename)
        display.accept(NSImage(cgImage: frame.image, size: frame.sourceRect.size), assetID: asset.id, filename: asset.filename, pixels: frame.sourceRect.size, native: true, ticket: ticket, sourceRect: frame.sourceRect, fullExtent: frame.fullExtent, accurate: false)
        XCTAssertTrue(display.native)
        XCTAssertEqual(display.sourceRect, frame.sourceRect)
        cache.cancel(clear: true)
        XCTAssertNil(cache.match(asset, geometry: geometry))
        XCTAssertEqual(cache.bytes, 0)
    }
}
