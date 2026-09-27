import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class ManualLensCorrectionTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    private let bounds = CGRect(x: 13, y: 27, width: 101, height: 101)

    private func image(_ pixel: @escaping (Int, Int) -> [Float]) -> CIImage {
        var data = [Float](repeating: 0, count: 101 * 101 * 4)
        for y in 0..<101 { for x in 0..<101 {
            let color = pixel(x, y)
            let i = ((100 - y) * 101 + x) * 4
            data[i] = color[0]; data[i + 1] = color[1]; data[i + 2] = color[2]; data[i + 3] = 1
        } }
        let bytes = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        return CIImage(bitmapData: bytes, bytesPerRow: 101 * 16, size: CGSize(width: 101, height: 101),
                       format: .RGBAf, colorSpace: space).transformed(by: CGAffineTransform(translationX: 13, y: 27))
    }

    private func sample(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var p = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &p, rowBytes: 16,
                       bounds: CGRect(x: x + 13, y: y + 27, width: 1, height: 1),
                       format: .RGBAf, colorSpace: space)
        return p
    }

    func testZeroReturnsOriginalImageAndExtent() {
        let input = image { x, _ in x < 50 ? [1, 0, 0] : [0, 0, 1] }
        let output = ManualLensCorrectionService.process(image: input, distortion: 0, purpleDefringe: 0, greenDefringe: 0, vignette: 0)
        XCTAssertTrue(output === input)
        XCTAssertEqual(output.extent, bounds)
    }

    func testDistortionMovesOffAxisGeometryInOppositeDirectionsAndKeepsEdgesFinite() {
        let input = image { x, y in x >= 73 && x <= 78 && y >= 48 && y <= 52 ? [1, 1, 1] : [0, 0, 0] }
        let positive = ManualLensCorrectionService.process(image: input, distortion: 80, purpleDefringe: 0, greenDefringe: 0, vignette: 0)
        let negative = ManualLensCorrectionService.process(image: input, distortion: -80, purpleDefringe: 0, greenDefringe: 0, vignette: 0)
        func centroid(_ output: CIImage) -> Float {
            var sum: Float = 0, weighted: Float = 0
            for x in 50..<100 { let v = sample(output, x, 50)[0]; sum += v; weighted += Float(x) * v }
            return weighted / sum
        }
        let original = centroid(input)
        XCTAssertGreaterThan(abs(centroid(positive) - original), 0.5)
        XCTAssertGreaterThan(abs(centroid(negative) - original), 0.5)
        XCTAssertLessThan((centroid(positive) - original) * (centroid(negative) - original), 0)
        for result in [positive, negative] {
            XCTAssertEqual(result.extent, bounds)
            for y in [0, 50, 100] { for x in [0, 50, 100] {
                XCTAssertTrue(sample(result, x, y).allSatisfy { $0.isFinite })
            } }
        }
    }

    func testDefringeTargetsColoredEdgeButNotFlatMatchingHue() {
        let input = image { x, y in
            if y < 48 { return [0.4, 0.4, 0.4] }
            if y < 53 { return x < 50 ? [0.8, 0.12, 0.8] : [0.12, 0.8, 0.12] }
            return x < 50 ? [0.8, 0.12, 0.8] : [0.12, 0.8, 0.12]
        }
        let purple = ManualLensCorrectionService.process(image: input, distortion: 0, purpleDefringe: 100, greenDefringe: 0, vignette: 0)
        let green = ManualLensCorrectionService.process(image: input, distortion: 0, purpleDefringe: 0, greenDefringe: 100, vignette: 0)
        XCTAssertLessThan(sample(purple, 25, 49)[0] - sample(purple, 25, 49)[1], 0.6)
        XCTAssertLessThan(sample(green, 75, 49)[1] - sample(green, 75, 49)[0], 0.6)
        XCTAssertEqual(sample(purple, 25, 85)[0], 0.8, accuracy: 0.02)
        XCTAssertEqual(sample(green, 75, 85)[1], 0.8, accuracy: 0.02)
        XCTAssertEqual(sample(purple, 75, 49)[1], 0.8, accuracy: 0.02)
        XCTAssertEqual(sample(green, 25, 49)[0], 0.8, accuracy: 0.02)
    }

    func testVignetteChangesCornerExposureInBothDirectionsWithoutCenterTint() {
        let input = image { _, _ in [0.4, 0.3, 0.2] }
        let brighter = ManualLensCorrectionService.process(image: input, distortion: 0, purpleDefringe: 0, greenDefringe: 0, vignette: 80)
        let darker = ManualLensCorrectionService.process(image: input, distortion: 0, purpleDefringe: 0, greenDefringe: 0, vignette: -80)
        XCTAssertEqual(brighter.extent, bounds)
        XCTAssertGreaterThan(sample(brighter, 0, 0)[0], 0.42)
        XCTAssertLessThan(sample(darker, 0, 0)[0], 0.38)
        for output in [brighter, darker] {
            for (actual, expected) in zip(sample(output, 50, 50), [Float(0.4), 0.3, 0.2, 1]) {
                XCTAssertEqual(actual, expected, accuracy: 0.015)
            }
            let corner = sample(output, 0, 0)
            XCTAssertEqual(corner[0] / corner[1], 4.0 / 3.0, accuracy: 0.03)
            XCTAssertTrue(corner.allSatisfy { $0.isFinite })
        }
    }
}
