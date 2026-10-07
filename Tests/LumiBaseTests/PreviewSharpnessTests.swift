import XCTest
import AppKit
import CoreImage
@testable import LumiBase

final class PreviewSharpnessTests: XCTestCase {
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
