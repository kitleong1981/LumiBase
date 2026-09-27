import XCTest
import CoreImage
import CoreGraphics
@testable import LumiBase

final class ExperimentalToneServiceTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .workingFormat: CIFormat.RGBAf])
    private let rect = CGRect(x: 13, y: 17, width: 32, height: 32)

    private func image(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: space)!).cropped(to: rect)
    }

    private func sample(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16,
                       bounds: CGRect(x: 29, y: 33, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return values
    }

    func testZeroIsIdentityAndBoundsRemainFinite() {
        let input = image(0.36, 0.18, 0.09)
        let operators: [(CIImage, Int) -> CIImage] = [
            ExperimentalToneService.contrast, ExperimentalToneService.shadows,
            ExperimentalToneService.whites, ExperimentalToneService.dehaze,
            ExperimentalToneService.texture
        ]
        for operation in operators {
            XCTAssertEqual(operation(input, 0).extent, rect)
            let original = sample(input)
            for (a, b) in zip(sample(operation(input, 0)), original) { XCTAssertEqual(a, b, accuracy: 0.0001) }
            for amount in [-100, 100] {
                let output = operation(input, amount)
                XCTAssertEqual(output.extent, rect)
                XCTAssertTrue(sample(output).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.001 })
            }
        }
    }

    func testDirectionAndHueStability() {
        let color = image(0.24, 0.12, 0.06)
        for operation in [ExperimentalToneService.shadows, ExperimentalToneService.dehaze] as [(CIImage, Int) -> CIImage] {
            let plus = sample(operation(color, 80)), minus = sample(operation(color, -80))
            XCTAssertTrue(plus[0].isFinite && minus[0].isFinite)
            XCTAssertEqual(plus[0] / plus[1], 2, accuracy: 0.08)
            XCTAssertEqual(minus[0] / minus[1], 2, accuracy: 0.08)
        }
        XCTAssertGreaterThan(sample(ExperimentalToneService.shadows(color, amount: 80))[0], sample(color)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.shadows(color, amount: -80))[0], sample(color)[0])
        let bright = image(0.7, 0.6, 0.5)
        XCTAssertGreaterThan(sample(ExperimentalToneService.whites(bright, amount: 80))[0], sample(bright)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.whites(bright, amount: -80))[0], sample(bright)[0])
        XCTAssertGreaterThan(sample(ExperimentalToneService.contrast(bright, amount: 80))[0], sample(bright)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.contrast(bright, amount: -80))[0], sample(bright)[0])
    }

    func testTexturePreservesUniformFields() {
        let input = image(0.3, 0.2, 0.1)
        for amount in [-100, 100] {
            let output = sample(ExperimentalToneService.texture(input, amount: amount))
            for (a, b) in zip(output, sample(input)) { XCTAssertEqual(a, b, accuracy: 0.002) }
        }
    }
}
