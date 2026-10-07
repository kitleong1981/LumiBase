import XCTest
import AppKit
import CoreImage
@testable import LumiBase

final class PreviewSharpnessTests: XCTestCase {
    @MainActor func testProductionScoresOriginalPixelsNotPublishedProxyOrROI() async throws {
        let root = inspectionTestScratchURL("full-score-red-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = 2048, h = 1536
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { rep.bitmapData![y*rep.bytesPerRow+x*3+c] = x % 2 == 0 ? 20 : 230 } } }
        let url = root.appendingPathComponent("source.jpg")
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 1])).write(to: url)
        let asset = PhotoAsset(fileURL: url)
        let saved = PerformanceSettings.shared.sharpnessEnabled
        PerformanceSettings.shared.sharpnessEnabled = true
        defer { PerformanceSettings.shared.sharpnessEnabled = saved }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]; state.selectAsset(asset)
        let proxy = NSImage(size: NSSize(width: 1600, height: 1200))
        proxy.lockFocus(); NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 1200).fill(); proxy.unlockFocus()
        state.publishDisplayedBitmap(proxy, assetID: asset.id, label: "Camera preview", accurate: false)
        let end = ProcessInfo.processInfo.systemUptime+10
        while state.previewSharpness.score == nil && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertGreaterThan(try XCTUnwrap(state.previewSharpness.score), 10_000, "Must score original 2048px detail, not the uniform 1600px published proxy")
        XCTAssertEqual(state.previewSharpness.fullPixelWidth, w)
        XCTAssertEqual(state.previewSharpness.fullPixelHeight, h)
        XCTAssertTrue(state.previewSharpness.sourceDescription.hasPrefix("Native JPEG"))
        // A later viewport ROI is a scheduling signal, never a new score input.
        let identity = state.previewSharpness.identity
        let score = state.previewSharpness.score
        state.publishDisplayedBitmap(proxy, assetID: asset.id, label: "Native ROI", accurate: false, scorePreview: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(state.previewSharpness.identity, identity)
        XCTAssertEqual(state.previewSharpness.score, score)
        state.previewSharpness.clear()
    }

    @MainActor func testFullProcessedCropUsesEditedOutputAndEditCancellation() async throws {
        let root = inspectionTestScratchURL("full-score-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1536, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<1536 { for x in 0..<2048 { for c in 0..<3 { rep.bitmapData![y*rep.bytesPerRow+x*3+c] = ((x/8+y/8)%2 == 0) ? 20 : 230 } } }
        let url = root.appendingPathComponent("edited.jpg")
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: url)
        var asset = PhotoAsset(fileURL: url)
        asset.xmp.exposure2012 = 1
        asset.xmp.hasCrop = true; asset.xmp.cropLeft = 0.25; asset.xmp.cropRight = 0.75
        asset.xmp.cropTop = 0.25; asset.xmp.cropBottom = 0.75
        let model = PreviewSharpnessState()
        model.submit(asset: asset, revision: 1, processed: true)
        let end = ProcessInfo.processInfo.systemUptime+15
        while model.score == nil && !model.unavailable && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(model.score); XCTAssertTrue(model.sourceDescription.hasPrefix("Processed"))
        XCTAssertEqual(model.fullPixelWidth, 1024); XCTAssertEqual(model.fullPixelHeight, 768)
        let oldKey = model.identity
        asset.xmp.cropLeft = 0; asset.xmp.cropRight = 1; asset.xmp.cropTop = 0; asset.xmp.cropBottom = 1
        model.submit(asset: asset, revision: 2, processed: true)
        XCTAssertNil(model.score); XCTAssertNotEqual(model.identity, oldKey)
        model.clear()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(model.score); XCTAssertNil(model.assetID)
    }

    @MainActor func testReadOnlyReal9504PairOriginalNot1600AndRAWOnlyFullSource() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["LUMIBASE_FULL_SHARPNESS_FIXTURE"] else { throw XCTSkip("Opt-in immutable DSC01801/DSC01803 JPG/ARW copies") }
        let root = URL(fileURLWithPath: fixture)
        var scores: [Double] = []
        for name in ["DSC01801", "DSC01803"] {
            let asset = PhotoAsset(fileURL: root.appendingPathComponent(name + ".JPG"))
            let model = PreviewSharpnessState()
            model.submit(asset: asset, revision: 1, processed: false)
            let end = ProcessInfo.processInfo.systemUptime+20
            while model.score == nil && !model.unavailable && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 2_000_000) }
            scores.append(try XCTUnwrap(model.score))
            XCTAssertEqual(model.fullPixelWidth, 9504); XCTAssertEqual(model.fullPixelHeight, 6336)
            XCTAssertTrue(model.sourceDescription.hasPrefix("Native JPEG"))
            print("FULL_PAIR \(name) score=\(model.score!) size=\(model.fullPixelWidth)x\(model.fullPixelHeight) computeMs=\(model.computeMilliseconds) cpuMs=\(model.computeCPUMilliseconds) loadMs=\(model.sourceLoadMilliseconds) explicitPixelMiB=\(Double(model.ownedPixelBytes)/1048576)")
            model.clear()
        }
        XCTAssertGreaterThan(scores[1], scores[0]*2.5)
        XCTAssertEqual(scores[0], 131.42, accuracy: 4); XCTAssertEqual(scores[1], 439.53, accuracy: 8)
        // No companion means the reduced embedded preview must be rejected, not enlarged.
        let raw = PhotoAsset(fileURL: root.appendingPathComponent("DSC01803.ARW"))
        let model = PreviewSharpnessState()
        model.submit(asset: raw, revision: 2, processed: false)
        let end = ProcessInfo.processInfo.systemUptime+30
        while model.score == nil && !model.unavailable && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(model.score); XCTAssertEqual(model.fullPixelWidth, 9504); XCTAssertEqual(model.fullPixelHeight, 6336)
        XCTAssertTrue(model.sourceDescription.hasPrefix("Native RAW"))
        print("FULL_RAW_ONLY score=\(model.score ?? -1) source=\(model.sourceDescription) computeMs=\(model.computeMilliseconds) loadMs=\(model.sourceLoadMilliseconds)")
        model.clear()
        var editedRAW = raw
        editedRAW.xmp.exposure2012 = 1; editedRAW.xmp.hasCrop = true
        editedRAW.xmp.cropLeft = 0.25; editedRAW.xmp.cropRight = 0.75
        editedRAW.xmp.cropTop = 0.25; editedRAW.xmp.cropBottom = 0.75
        model.submit(asset: editedRAW, revision: 3, processed: true)
        let cropEnd = ProcessInfo.processInfo.systemUptime+30
        while model.score == nil && !model.unavailable && ProcessInfo.processInfo.systemUptime < cropEnd { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(model.score); XCTAssertEqual(model.fullPixelWidth, 4752); XCTAssertEqual(model.fullPixelHeight, 3168)
        XCTAssertTrue(model.sourceDescription.hasPrefix("Processed"))
        print("FULL_RAW_CROP score=\(model.score ?? -1) source=\(model.sourceDescription) computeMs=\(model.computeMilliseconds) loadMs=\(model.sourceLoadMilliseconds)")
        model.clear()
    }
    @MainActor func testRealWorkerCacheEditRevisionAndLatestSelectionPublication() async throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 768, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.bitmapData!.initialize(repeating: 100, count: rep.bytesPerRow*rep.pixelsHigh)
        let image = NSImage(cgImage: try XCTUnwrap(rep.cgImage), size: NSSize(width: 1024, height: 768))
        var asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/selected.jpg"))
        let model = PreviewSharpnessState()
        ImageWorkDiagnostics.start(); defer { ImageWorkDiagnostics.stop() }
        func wait() async throws {
            let end = ProcessInfo.processInfo.systemUptime+2
            while model.score == nil && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertNotNil(model.score)
        }
        model.submit(image, asset: asset, revision: 1, previewKind: "loupe"); try await wait()
        let key = model.identity
        model.clear(); model.submit(image, asset: asset, revision: 1, previewKind: "loupe"); try await wait()
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sharpnessCompute"], 1)
        asset.xmp.exposure2012 = 1
        model.submit(image, asset: asset, revision: 1, previewKind: "loupe"); try await wait()
        XCTAssertNotEqual(model.identity, key)
        XCTAssertEqual(ImageWorkDiagnostics.snapshot()["sharpnessCompute"], 2)
        for n in 0..<20 { model.submit(image, asset: PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/\(n).jpg")), revision: 1, previewKind: "loupe") }
        model.clear(); try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(model.score); XCTAssertNil(model.assetID)
        model.submit(image, asset: asset, revision: 2, previewKind: "loupe"); try await wait()
        XCTAssertEqual(model.assetID, asset.id)
    }
    func testSharpCheckerRanksAboveBlurAndCancelledWorkReturnsNothing() throws {
        let w = 1024, h = 768
        var bytes = [UInt8](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w { bytes[y*w+x] = ((x/8 + y/8) % 2 == 0) ? 20 : 230 } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let sharp = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let base = CIImage(cgImage: sharp)
        let blurred = base.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4]).cropped(to: base.extent)
        let blur = try XCTUnwrap(CIContext().createCGImage(blurred, from: base.extent))
        let score = try XCTUnwrap(PreviewSharpness.compute(sharp))
        let low = try XCTUnwrap(PreviewSharpness.compute(blur))
        XCTAssertGreaterThan(score, low * 4)
        XCTAssertGreaterThan(score, 100)
        XCTAssertNil(PreviewSharpness.compute(sharp, isCurrent: { false }))
        XCTAssertEqual(PreviewSharpness.compute(sharp), score)
    }
}
