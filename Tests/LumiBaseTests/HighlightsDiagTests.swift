import XCTest
import AppKit
@testable import LumiBase

/// Opt-in diagnostic: LUMIBASE_DIAG_DNG=<path> LUMIBASE_DIAG_OUT=<dir>
final class HighlightsDiagTests: XCTestCase {
    func testBalloonVariants() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_DIAG_DNG"],
              let out = ProcessInfo.processInfo.environment["LUMIBASE_DIAG_OUT"] else { throw XCTSkip("opt-in") }
        let url = URL(fileURLWithPath: path)
        var variants: [(String, XMPMetadata)] = []
        var h0 = XMPMetadata(); h0.advancedRAWHighlightRecovery = false; variants.append(("h0", h0))
        var std = XMPMetadata(); std.highlights2012 = -80; std.advancedRAWHighlightRecovery = false; variants.append(("std80", std))
        var adv = XMPMetadata(); adv.highlights2012 = -80; adv.advancedRAWHighlightRecovery = true; variants.append(("adv80", adv))
        var samples: [String: [[Double]]] = [:]
        let only = ProcessInfo.processInfo.environment["LUMIBASE_DIAG_ONLY"]
        for (name, xmp) in variants where only == nil || only == name {
            guard let holder = await RAWImageLoader.shared.loadBaseHolder(from: url, xmp: xmp, useSharedCache: false),
                  let img = RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: "ILCE-7RM5", xmp: xmp) else { XCTFail("render \(name)"); continue }
            print("DIAG \(name) isRaw=\(holder.isRaw) nativeInspect=\(holder.supportsNativeInspection) src=\(holder.highlightsSource != nil) applies=\(NativeHighlightsService.applies(holder: holder, xmp: xmp)) size=\(img.size)")
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
            // fixed normalized sample points (x,y from top-left) on balloons
            let pts: [(Double, Double)] = [(0.22,0.42),(0.30,0.38),(0.40,0.50),(0.52,0.46),(0.56,0.60),(0.70,0.55),(0.78,0.60),(0.35,0.62),(0.50,0.68)]
            samples[name] = pts.map { p in
                let x = Int(p.0 * Double(rep.pixelsWide)), y = Int(p.1 * Double(rep.pixelsHigh))
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
            }
        }
        for i in 0..<9 where only == nil {
            let row = variants.map { v in samples[v.0].map { String(format: "%@=(%.2f %.2f %.2f)", v.0, $0[i][0], $0[i][1], $0[i][2]) } ?? "" }
            print("DIAGPT \(i) " + row.joined(separator: "  "))
        }
    }
}

import CoreImage
extension HighlightsDiagTests {
    /// Scene-linear Apple RAW output (no boost / shadow bias) in linear sRGB, 16-bit PNG, 2560 wide.
    func testLinearApple() throws {
        guard let path = ProcessInfo.processInfo.environment["LUMIBASE_DIAG_LINEAR"],
              let out = ProcessInfo.processInfo.environment["LUMIBASE_DIAG_OUT"] else { throw XCTSkip("opt-in") }
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: URL(fileURLWithPath: path)))
        raw.boostAmount = 0; raw.shadowBias = 0; raw.boostShadowAmount = 0
        raw.exposure = 0
        var img = try XCTUnwrap(raw.outputImage)
        let s = 2560.0 / img.extent.width
        img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!, .workingFormat: CIFormat.RGBAh])
        try ctx.writePNGRepresentation(of: img, to: URL(fileURLWithPath: out).appendingPathComponent("lin.png"),
            format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        print("DIAGLIN \(img.extent)")
    }
}
