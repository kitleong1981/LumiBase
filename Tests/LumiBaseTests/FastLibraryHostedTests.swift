import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class FastLibraryHostedTests: XCTestCase {
    @MainActor func testGridHistogramUsesSelectedDisplayedJPEGWithoutSourceLoad() async throws {
        let root = inspectionTestScratchURL("grid-hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); ImageWorkDiagnostics.stop() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = root.appendingPathComponent("one.JPG")
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        let asset = PhotoAsset(fileURL: url)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]; state.selectAsset(asset); state.isHistogramEnabled = true
        let host = NSHostingView(rootView: GridView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { state.isHistogramEnabled = false; window.orderOut(nil); window.contentView = nil }
        ImageWorkDiagnostics.start()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while state.displayHistogram.data == nil && ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(state.displayHistogram.data)
        XCTAssertEqual(state.displayedBitmap?.assetID, asset.id)
        XCTAssertTrue(state.displayHistogram.label.contains("JPEG"))
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
    }

    @MainActor func testHostedLibraryLatestFrameHistogramOffAndDevelopTransition() async throws {
        let root = inspectionTestScratchURL("fast-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); ImageWorkDiagnostics.stop() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        var xmp = XMPMetadata.empty; xmp.rating = 2
        var assets: [PhotoAsset] = []
        for name in ["one", "two", "three"] {
            let raw = root.appendingPathComponent(name + ".ARW"), jpg = root.appendingPathComponent(name + ".JPG")
            try Data("invalid RAW fixture".utf8).write(to: raw); try data.write(to: jpg)
            assets.append(PhotoAsset(fileURL: raw, companionURLs: [jpg], xmp: xmp))
        }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.isHistogramEnabled = false; state.viewMode = .loupe
        state.allAssets = assets; state.selectAsset(assets[0])
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        ImageWorkDiagnostics.start()
        func waitReady(_ asset: PhotoAsset, accurate: Bool = false) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                host.layoutSubtreeIfNeeded()
                if state.displayedBitmap?.assetID == asset.id && (!accurate || state.displayedBitmap?.accurate == true) { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("No actual SwiftUI first-ready publication for \(asset.filename)")
        }
        try await waitReady(assets[0])
        state.selectAsset(assets[1]); state.selectAsset(assets[2])
        try await waitReady(assets[2])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.displayedBitmap?.assetID, assets[2].id)
        XCTAssertEqual(state.allAssets[2].xmp.rating, 2)
        XCTAssertTrue(state.displayedBitmap?.label.contains("JPEG") == true)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["processedRender", default: 0], 0)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["histogramBins", default: 0], 0)
        state.isHistogramEnabled = true
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while state.displayHistogram.data == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(state.displayHistogram.data)
        XCTAssertTrue(state.displayHistogram.label.contains("JPEG"))
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        state.isHistogramEnabled = false
        XCTAssertNil(state.displayHistogram.data)
        // An ordinary JPEG exercises the accurate Develop render engine, not a fake RAW.
        let jpeg = PhotoAsset(fileURL: assets[2].companionURLs[0], xmp: xmp)
        state.allAssets.append(jpeg); state.selectAsset(jpeg); state.workspaceMode = .develop
        let revision = state.displaySourceRevision
        try await waitReady(jpeg, accurate: true)
        XCTAssertEqual(state.displayedBitmap?.sourceRevision, revision)
        XCTAssertGreaterThan(ImageWorkDiagnostics.snapshot()["sourceLoad", default: 0], 0)
        XCTAssertGreaterThan(ImageWorkDiagnostics.snapshot()["processedRender", default: 0], 0)
        let oldRevision = state.displaySourceRevision
        state.resetDevelopSettings()
        XCTAssertGreaterThan(state.displaySourceRevision, oldRevision)
        XCTAssertNil(state.displayedBitmap)
        try await waitReady(jpeg, accurate: true)
        XCTAssertEqual(state.displayedBitmap?.sourceRevision, state.displaySourceRevision)
        XCTAssertFalse(state.primarySelectedAsset?.xmp.hasDevelopEdits ?? true)
        state.workspaceMode = .library
        XCTAssertNil(state.displayedBitmap, "Mode revision synchronously releases old developed publication")
        try await waitReady(jpeg)
        XCTAssertTrue(state.displayedBitmap?.label.contains("JPEG") == true)
    }
}
