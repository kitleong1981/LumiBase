import XCTest
import CoreImage
@testable import LumiBase

final class OpticalExposureKernelTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        .workingFormat: CIFormat.RGBAf
    ])
    private let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    private func renderPixel(_ image: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &px,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: linearSpace
        )
        return px
    }

    private func makeImage(r: Float, g: Float, b: Float) -> CIImage {
        let color = CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    func testZeroExposureIsPassThrough() {
        for val in [Float(0.0), Float(0.05), Float(0.18), Float(0.50), Float(0.85), Float(1.0)] {
            let input = makeImage(r: val, g: val, b: val)
            let output = OpticalExposureKernel.apply(image: input, ev: 0.0)
            let outPix = renderPixel(output)
            XCTAssertEqual(outPix[0], val, accuracy: 0.001, "Zero EV must preserve pixel value \(val)")
        }
    }

    func testPositiveExposureLiftsShadowsSubstantially() {
        let shadowVal: Float = 0.05
        let input = makeImage(r: shadowVal, g: shadowVal, b: shadowVal)
        let output = OpticalExposureKernel.apply(image: input, ev: 1.0) // +1 EV
        let outPix = renderPixel(output)

        // At +1 EV, 0.05 should receive near 2.0x optical photon gain (expected ~0.095)
        XCTAssertGreaterThan(outPix[0], shadowVal * 1.75, "Shadows must receive optical gain close to 2x")
        XCTAssertLessThanOrEqual(outPix[0], shadowVal * 2.05, "Shadows gain must not exceed linear 2x")
    }

    func testPositiveExposureCompressesHighlightsWithoutHardClipping() {
        // High highlight patch: 0.75
        let hlVal: Float = 0.75
        let input = makeImage(r: hlVal, g: hlVal, b: hlVal)
        let output = OpticalExposureKernel.apply(image: input, ev: 1.0) // +1 EV
        let outPix = renderPixel(output)

        // Under old linear multiplier: 0.75 * 2.0 = 1.50 -> clipped hard to 1.0
        // Under OpticalExposureKernel Reinhard shoulder: it rolls off smoothly to ~0.85
        XCTAssertLessThan(outPix[0], 0.95, "0.75 at +1 EV must smoothly roll off into shoulder without blowing out to 1.0")
        XCTAssertGreaterThan(outPix[0], hlVal, "Highlight must still brighten proportionally")
    }

    func testExtremePositiveExposurePreservesWhitePointAtOne() {
        // Under +3 EV (+8x gain)
        let input = makeImage(r: 0.90, g: 0.90, b: 0.90)
        let output = OpticalExposureKernel.apply(image: input, ev: 3.0)
        let outPix = renderPixel(output)

        XCTAssertLessThanOrEqual(outPix[0], 1.0001, "White point must never exceed 1.0 under extreme exposure")
        XCTAssertGreaterThan(outPix[0], 0.98, "Very bright highlight must reach the white point ceiling smoothly")
    }

    func testNegativeExposureDarkensLinearly() {
        let midVal: Float = 0.40
        let input = makeImage(r: midVal, g: midVal, b: midVal)
        let output = OpticalExposureKernel.apply(image: input, ev: -1.0) // -1 EV (0.5x)
        let outPix = renderPixel(output)

        XCTAssertEqual(outPix[0], midVal * 0.5, accuracy: 0.01, "Negative exposure must pull down linearly")
    }

    func testMonotonicityAcrossDynamicRange() {
        let values: [Float] = [0.02, 0.05, 0.10, 0.18, 0.35, 0.50, 0.70, 0.85, 0.95]
        var prevOut: Float = -1.0
        for val in values {
            let input = makeImage(r: val, g: val, b: val)
            let output = OpticalExposureKernel.apply(image: input, ev: 1.5)
            let outPix = renderPixel(output)
            XCTAssertGreaterThan(outPix[0], prevOut, "Output must be strictly monotonically increasing")
            prevOut = outPix[0]
        }
    }

    func testWhitesSliderModulatesShoulderHeadroom() {
        let hlVal: Float = 0.70
        let input = makeImage(r: hlVal, g: hlVal, b: hlVal)
        
        let outNeutral = renderPixel(OpticalExposureKernel.apply(image: input, ev: 1.0, whites: 0.0))[0]
        let outHighWhites = renderPixel(OpticalExposureKernel.apply(image: input, ev: 1.0, whites: 50.0))[0]
        let outLowWhites = renderPixel(OpticalExposureKernel.apply(image: input, ev: 1.0, whites: -50.0))[0]

        XCTAssertGreaterThan(outHighWhites, outNeutral, "+Whites should lift the highlight shoulder")
        XCTAssertLessThan(outLowWhites, outNeutral, "-Whites should provide deeper highlight headroom")
    }

    func testPipelineIntegrationExposureAdjustment() {
        let pipeline = AdobeColorPipeline.shared
        let testImage = makeImage(r: 0.18, g: 0.18, b: 0.18)

        var xmp = XMPMetadata()
        xmp.exposure2012 = 1.0 // +1 EV
        let output = pipeline.process(image: testImage, cameraModel: nil, xmp: xmp)
        let outPix = renderPixel(output)

        XCTAssertGreaterThan(outPix[0], 0.25, "Pipeline exposure must lift midtones")
        XCTAssertLessThan(outPix[0], 0.40, "Pipeline exposure must lift midtones cleanly")
    }
}
