import XCTest
import CoreImage
@testable import LumiBase

/// Behavioural checks for the experimental baseline correction (see docs/baseline-tone-correction-zhTW.md).
final class BaselineToneKernelTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                              .workingFormat: CIFormat.RGBAf])

    private func decode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    /// Applies the kernel to a uniform linear-sRGB color given as sRGB-encoded components.
    private func apply(_ r: Double, _ g: Double, _ b: Double) throws -> (before: [Double], after: [Double]) {
        let lin = [decode(r), decode(g), decode(b)]
        let color = try XCTUnwrap(CIColor(red: lin[0], green: lin[1], blue: lin[2], colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!))
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = BaselineToneKernel.apply(image)
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        return (lin, px.prefix(3).map(Double.init))
    }

    private func lab(_ lin: [Double]) -> (L: Double, C: Double) {
        let x = (0.4124 * lin[0] + 0.3576 * lin[1] + 0.1805 * lin[2]) / 0.95047
        let y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
        let z = (0.0193 * lin[0] + 0.1192 * lin[1] + 0.9505 * lin[2]) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, hypot(500 * (fx - fy), 200 * (fy - fz)))
    }

    func testBlackAndNeutralMidGrayAreUnchanged() throws {
        for v in [0.0, 0.5] {
            let (before, after) = try apply(v, v, v)
            for i in 0..<3 { XCTAssertEqual(after[i], before[i], accuracy: 0.003, "neutral \(v) channel \(i)") }
        }
    }

    func testDarkBlueIsLiftedAndDesaturated() throws {
        let (before, after) = try apply(0.05, 0.10, 0.30)
        let b = lab(before), a = lab(after)
        XCTAssertGreaterThan(a.L, b.L + 1.0, "dark/mid band should be lifted")
        XCTAssertLessThan(a.C, b.C * 0.95, "dark/mid band chroma should be reduced")
    }

    func testBrightSaturatedOrangeIsDesaturatedNotDarkened() throws {
        let (before, after) = try apply(0.95, 0.55, 0.15)
        let b = lab(before), a = lab(after)
        XCTAssertLessThan(a.C, b.C * 0.97, "bright band chroma should be reduced")
        XCTAssertEqual(a.L, b.L, accuracy: 1.5, "bright band luminance should stay put")
    }
}
