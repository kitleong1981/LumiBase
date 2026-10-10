import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class LightcraftHighlightsTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let cs = CGColorSpaceCreateDeviceRGB()
    
    func testHighlightRollOffKernelCompressesHighlightsAndPreservesMidtones() {
        let kernel = HighlightRollOffKernel.shared
        
        // Highlight patch (high luminance)
        let highlightColor = CIColor(red: 0.92, green: 0.82, blue: 0.70)
        let highlightImg = CIImage(color: highlightColor).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        
        // Midtone patch (y = 0.50)
        let midtoneColor = CIColor(red: 0.50, green: 0.50, blue: 0.50)
        let midtoneImg = CIImage(color: midtoneColor).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        
        let neutralHL = highlightImg
        let recoveredHL = kernel.apply(image: highlightImg, hlFactor: -1.0)
        
        let neutralMid = midtoneImg
        let recoveredMid = kernel.apply(image: midtoneImg, hlFactor: -1.0)
        
        var pixNeutralHL = [UInt8](repeating: 0, count: 4)
        var pixRecoveredHL = [UInt8](repeating: 0, count: 4)
        var pixNeutralMid = [UInt8](repeating: 0, count: 4)
        var pixRecoveredMid = [UInt8](repeating: 0, count: 4)
        
        context.render(neutralHL, toBitmap: &pixNeutralHL, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(recoveredHL, toBitmap: &pixRecoveredHL, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(neutralMid, toBitmap: &pixNeutralMid, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(recoveredMid, toBitmap: &pixRecoveredMid, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        
        // Highlights must be visibly compressed
        XCTAssertLessThan(pixRecoveredHL[0], pixNeutralHL[0], "Highlights must be compressed when hlFactor < 0")
        
        // Midtones must be strictly preserved (within 1 LSB 8-bit quantization tolerance)
        let midDiff = abs(Int(pixRecoveredMid[0]) - Int(pixNeutralMid[0]))
        XCTAssertLessThanOrEqual(midDiff, 1, "Midtones (y <= 0.50) must remain strictly preserved by the highlight roll-off kernel")
    }
    
    func testHighlightRollOffKernelPreservesHueRatios() {
        let kernel = HighlightRollOffKernel.shared
        
        // Warm sunset golden light: R > G > B
        let sunsetColor = CIColor(red: 0.90, green: 0.60, blue: 0.30)
        let sunsetImg = CIImage(color: sunsetColor).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        
        let recovered = kernel.apply(image: sunsetImg, hlFactor: -0.75)
        
        var origFloat = [Float](repeating: 0, count: 4)
        var recFloat = [Float](repeating: 0, count: 4)
        let fcs = CGColorSpace(name: CGColorSpace.linearSRGB)!
        
        context.render(sunsetImg, toBitmap: &origFloat, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: fcs)
        context.render(recovered, toBitmap: &recFloat, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: fcs)
        
        // Verify R/G and G/B ratios are preserved within 0.05 tolerance (hue constancy)
        let origRG = origFloat[0] / origFloat[1]
        let recRG = recFloat[0] / recFloat[1]
        XCTAssertEqual(origRG, recRG, accuracy: 0.05, "Highlight recovery must preserve chromaticity / hue ratios")
    }
    
    func testSpecularHighlightDesaturationNearClipping() {
        let kernel = HighlightRollOffKernel.shared
        
        // Highly saturated specular highlight near clipping limit (> 0.985)
        let specularColor = CIColor(red: 0.995, green: 0.85, blue: 0.30)
        let specularImg = CIImage(color: specularColor).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        
        let processed = kernel.apply(image: specularImg, hlFactor: 0.0) // even at 0, specular roll-off desaturates extreme highlights
        
        var origBytes = [UInt8](repeating: 0, count: 4)
        var procBytes = [UInt8](repeating: 0, count: 4)
        
        context.render(specularImg, toBitmap: &origBytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        context.render(processed, toBitmap: &procBytes, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
        
        // Blue channel should increase towards luminance to desaturate specular highlight into neutral white
        XCTAssertGreaterThan(procBytes[2], origBytes[2], "Specular highlights must desaturate towards neutral white")
    }
    
    func testPipelineIntegrationWithLightcraftHighlights() {
        let pipeline = AdobeColorPipeline.shared
        let testImage = CIImage(color: CIColor(red: 0.90, green: 0.80, blue: 0.65)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        
        var xmp = XMPMetadata()
        xmp.highlights2012 = -60
        xmp.advancedRAWHighlightRecovery = false
        
        let output = pipeline.process(image: testImage, cameraModel: "ILCE-7M4", xmp: xmp)
        XCTAssertNotNil(output)
        XCTAssertEqual(output.extent.width, 32)
        XCTAssertEqual(output.extent.height, 32)
    }
}
