import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class FastLibraryTests: XCTestCase {
    @MainActor func testLibraryDefaultShowsEditsAtFitAndNativeButMetadataKeepsCameraFastPath() {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        XCTAssertEqual(state.workspaceMode, .library)
        var xmp = XMPMetadata.empty; xmp.exposure2012 = 2
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/photo.arw"), xmp: xmp)
        XCTAssertEqual(state.previewPolicy(for: asset, native: false), .accurate)
        XCTAssertFalse(state.previewLabel(for: asset, native: false).contains("edits not displayed"))
        XCTAssertEqual(state.previewPolicy(for: asset, native: true), .accurate)
        var metadata = XMPMetadata.empty; metadata.rating = 5; metadata.flag = .pick
        let unedited = PhotoAsset(fileURL: asset.fileURL, xmp: metadata)
        XCTAssertFalse(metadata.hasDevelopEdits)
        XCTAssertEqual(state.previewPolicy(for: unedited, native: false), .cameraJPEG)
        XCTAssertEqual(state.previewPolicy(for: unedited, native: true), .cameraJPEG)
        state.workspaceMode = .develop
        XCTAssertEqual(state.previewPolicy(for: unedited, native: false), .accurate)
        XCTAssertEqual(asset.xmp.exposure2012, 2)
    }
    @MainActor func testCameraPreviewDoesNotDecodeInvalidRAWAndIgnoresDevelopEdits() async throws {
        let root = inspectionTestScratchURL("camera-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("camera.arw")
        try Data("not a RAW".utf8).write(to: raw)
        let jpg = root.appendingPathComponent("camera.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: jpg)
        var xmp = XMPMetadata.empty; xmp.exposure2012 = 3
        let asset = PhotoAsset(fileURL: raw, companionURLs: [jpg], xmp: xmp)
        let preview = await ThumbnailLoader.shared.loadCameraPreview(for: asset, maxPixelSize: 1600)
        XCTAssertNotNil(preview)
        let missing = await ThumbnailLoader.shared.loadCameraPreview(for: PhotoAsset(fileURL: raw), maxPixelSize: 1600)
        XCTAssertNil(missing, "Library must not fall through to RAW decode")
    }

    @MainActor func testDevelopHistogramDoesNotBinCameraLoadingFrame() async {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/loading.arw"))
        state.allAssets = [asset]; state.selectAsset(asset); state.workspaceMode = .develop
        state.isHistogramEnabled = true
        state.publishDisplayedBitmap(NSImage(size: NSSize(width: 2, height: 2)), assetID: asset.id,
            label: "JPEG loading Develop", accurate: false)
        await Task.yield()
        XCTAssertNil(state.displayHistogram.data)
        state.isHistogramEnabled = false
    }

    @MainActor func testCompanionRevisionInvalidatesCameraCacheAndCancelledLookupDoesNoWork() async throws {
        let root = inspectionTestScratchURL("camera-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("camera.ARW"), jpg = root.appendingPathComponent("camera.JPG")
        try Data("RAW without embedded preview".utf8).write(to: raw)
        func writeJPEG(width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: jpg)
        }
        try writeJPEG(width: 32)
        let asset = PhotoAsset(fileURL: raw, companionURLs: [jpg])
        let first = await ThumbnailLoader.shared.loadCameraPreview(for: asset)
        XCTAssertEqual(first?.size.width, 32)
        XCTAssertEqual(ThumbnailLoader.readyCameraPreview(for: asset)?.size.width, 32)
        try writeJPEG(width: 64)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: jpg.path)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(ThumbnailLoader.readyCameraPreview(for: asset), "A changed companion must invalidate the memory-only body handoff before a new decode")
        let changed = await ThumbnailLoader.shared.loadCameraPreview(for: asset)
        XCTAssertEqual(changed?.size.width, 64, "Companion file revision must be in the camera cache key")
        let cancelled = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await ThumbnailLoader.shared.loadCameraPreview(for: asset)
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
    }

    @MainActor func testCollectionCacheTracksNestedMetadataFiltersSortAndSelection() {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let a = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/a.jpg"))
        let b = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/b.jpg"))
        state.allAssets = [a, b]; state.sortOrder = .filenameAscending
        XCTAssertEqual(state.displayedAssets.map(\.id), [a.id, b.id])
        state.selectedAssetIDs = [a.id]
        XCTAssertEqual(state.selectedAssets.map(\.id), [a.id])
        state.selectedAssetIDs = [b.id]
        XCTAssertEqual(state.selectedAssets.map(\.id), [b.id])
        state.allAssets[1].xmp.rating = 5
        state.filterCriteria.minimumRating = 5
        XCTAssertEqual(state.displayedAssets.map(\.id), [b.id])
        state.allAssets[0].xmp.rating = 5
        XCTAssertEqual(state.displayedAssets.map(\.id), [a.id, b.id])
        state.sortOrder = .filenameDescending
        XCTAssertEqual(state.displayedAssets.map(\.id), [b.id, a.id])
        state.allAssets.removeLast()
        XCTAssertEqual(state.displayedAssets.map(\.id), [a.id])
        XCTAssertTrue(state.selectedAssets.isEmpty)
    }

    @MainActor func testNativeCameraJPEGUsesRealCompanionPixelsAndRejectsUnpairedFile() async throws {
        let root = inspectionTestScratchURL("native-camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("camera.arw")
        let jpg = root.appendingPathComponent("camera.jpg")
        try Data("not RAW".utf8).write(to: raw)
        func writeJPEG(_ width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: jpg)
        }
        try writeJPEG(64)
        let asset = PhotoAsset(fileURL: raw, companionURLs: [jpg])
        let first = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        XCTAssertEqual(first?.size.width, 64)
        try writeJPEG(96)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: jpg.path)
        let changed = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        XCTAssertEqual(changed?.size.width, 96)
        let other = PhotoAsset(fileURL: root.appendingPathComponent("different.arw"), companionURLs: [jpg])
        let rejected = await ThumbnailLoader.shared.loadNativeCameraJPEG(for: other)
        XCTAssertNil(rejected)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return await ThumbnailLoader.shared.loadNativeCameraJPEG(for: asset)
        }
        task.cancel(); let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    @MainActor func testCancelledHistogramDoesNotStartBins() async {
        ImageWorkDiagnostics.start(); defer { ImageWorkDiagnostics.stop() }
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await HistogramCalculator.computeHistogram(for: NSImage(size: NSSize(width: 2, height: 2)))
        }
        task.cancel(); _ = await task.value
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["histogramBins", default: 0], 0)
    }

    @MainActor func testHistogramOffDoesNoWorkAndReleasesResults() async {
        var calls = 0
        let histogram = DisplayHistogramState(compute: { _ in calls += 1; return .empty })
        let image = NSImage(size: NSSize(width: 2, height: 2))
        histogram.submit(image, label: "JPEG")
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(histogram.data)
        histogram.enabled = true
        histogram.submit(image, label: "JPEG")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        histogram.enabled = false
        XCTAssertNil(histogram.data)
        XCTAssertEqual(histogram.label, "")
        histogram.submit(image, label: "RAW")
        await Task.yield()
        XCTAssertEqual(calls, 1)
    }
}
