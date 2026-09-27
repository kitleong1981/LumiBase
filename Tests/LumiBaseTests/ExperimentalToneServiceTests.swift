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
        }
        let negativeShadows = sample(ExperimentalToneService.shadows(color, amount: -80))
        XCTAssertEqual(negativeShadows[0] / negativeShadows[1], 2, accuracy: 0.08)
        let mist = sample(ExperimentalToneService.dehaze(color, amount: -80))
        XCTAssertLessThan(mist[0] / mist[1], 2, "Negative dehaze should reduce chroma")
        XCTAssertGreaterThan(sample(ExperimentalToneService.shadows(color, amount: 80))[0], sample(color)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.shadows(color, amount: -80))[0], sample(color)[0])
        let bright = image(0.7, 0.6, 0.5)
        XCTAssertGreaterThan(sample(ExperimentalToneService.whites(bright, amount: 80))[0], sample(bright)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.whites(bright, amount: -80))[0], sample(bright)[0])
        XCTAssertGreaterThan(sample(ExperimentalToneService.contrast(bright, amount: 80))[0], sample(bright)[0])
        XCTAssertLessThan(sample(ExperimentalToneService.contrast(bright, amount: -80))[0], sample(bright)[0])
    }

    func testPositiveShadowsLiftWhilePreservingRelativeDetail() {
        let input = image(0.20, 0.12, 0.07)
        let old = sample(input)
        let lifted = sample(ExperimentalToneService.shadows(input, amount: 100))
        XCTAssertGreaterThan(lifted[0] / old[0], 1.8, "Need meaningful shadow lift without tonal inversion")
        XCTAssertEqual(lifted[0] / lifted[1], old[0] / old[1], accuracy: 0.08)
        let black = image(0, 0, 0)
        XCTAssertEqual(sample(ExperimentalToneService.shadows(black, amount: 100))[0], 0, accuracy: 0.0001)
    }

    func testShadowAndWhiteCurvesCannotReverseOrMergeAdjacentTones() {
        let count = 256
        let pixels: [Float] = (0..<count).flatMap { i -> [Float] in
            let y = Float(i) / Float(count - 1)
            return [y, y, y, 1]
        }
        let source = pixels.withUnsafeBufferPointer { ptr in
            CIImage(bitmapData: Data(buffer: ptr), bytesPerRow: count * 16,
                    size: CGSize(width: count, height: 1), format: .RGBAf, colorSpace: space)
        }
        for (name, op, amounts, minimumSlope) in [
            ("shadows", ExperimentalToneService.shadows, [25, 50, 70, 100], Float(0.62)),
            ("whites", ExperimentalToneService.whites, [-50, -90, -100], Float(0.60))
        ] as [(String, (CIImage, Int) -> CIImage, [Int], Float)] {
            for amount in amounts {
                var result = [Float](repeating: 0, count: pixels.count)
                context.render(op(source, amount), toBitmap: &result, rowBytes: count * 16,
                               bounds: CGRect(x: 0, y: 0, width: count, height: 1),
                               format: .RGBAf, colorSpace: space)
                for i in 0..<(count - 1) {
                    let slope = (result[(i + 1) * 4] - result[i * 4]) * Float(count - 1)
                    XCTAssertGreaterThanOrEqual(slope, minimumSlope,
                        "\(name) \(amount) reversed/merged neighboring tones near \(i)/255")
                }
            }
        }
    }

    func testNegativeWhitesDarkensBrightDetailWithoutRaisingIt() {
        let input = image(0.8, 0.74, 0.68)
        let after = sample(ExperimentalToneService.whites(input, amount: -90))
        XCTAssertLessThan(after[0], 0.74, "Whites -90 should compress the upper tone range but retain detail")
        XCTAssertEqual(after[0] / after[1], 0.8 / 0.74, accuracy: 0.06)
        let shadow = image(0.08, 0.07, 0.06)
        XCTAssertEqual(sample(ExperimentalToneService.whites(shadow, amount: -90))[0], 0.08, accuracy: 0.01)
    }

    func testNegativeDehazeAddsNeutralVeilAndWashesOutColorAndPositiveCutsHaze() {
        let original = image(0.2, 0.1, 0.05)
        let before = sample(original)
        let fogged = sample(ExperimentalToneService.dehaze(original, amount: -85))
        XCTAssertGreaterThan(fogged[1], before[1] + 0.12, "Negative dehaze should look like visible mist")
        XCTAssertLessThan(fogged[0] - fogged[2], before[0] - before[2], "Airlight should wash out color")
        XCTAssertLessThan(fogged[0] / fogged[1], before[0] / before[1])
        let hazy = image(0.55, 0.55, 0.55)
        XCTAssertLessThan(sample(ExperimentalToneService.dehaze(hazy, amount: 85))[0], 0.47,
                          "Positive dehaze needs a visibly stronger atmospheric contrast change")
    }

    func testTexturePreservesUniformFields() {
        let input = image(0.3, 0.2, 0.1)
        for amount in [-100, 100] {
            let output = sample(ExperimentalToneService.texture(input, amount: amount))
            for (a, b) in zip(output, sample(input)) { XCTAssertEqual(a, b, accuracy: 0.002) }
        }
    }
}
