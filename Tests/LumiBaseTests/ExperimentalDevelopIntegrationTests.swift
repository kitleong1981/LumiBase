import XCTest
import CoreImage
import CoreGraphics
import AppKit
@testable import LumiBase

final class ExperimentalDevelopIntegrationTests: XCTestCase {
    func testA_BSameSliderWhitesMustNotGetBrighterAndShadowsMustLiftMore() throws {
        let bright = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var whites = XMPMetadata(whites2012: -90)
        let legacyWhites = try XCTUnwrap(rendered(image: AdobeColorPipeline.shared.process(
            image: bright, cameraModel: nil, xmp: whites)).first)
        whites.experimentalWhites = true
        let experimentalWhites = try XCTUnwrap(rendered(image: AdobeColorPipeline.shared.process(
            image: bright, cameraModel: nil, xmp: whites)).first)
        XCTAssertLessThan(experimentalWhites, legacyWhites, "A/B Whites -90 must go darker, not brighter")

        let dark = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var shadows = XMPMetadata(shadows2012: 100)
        let legacyShadows = try XCTUnwrap(rendered(image: AdobeColorPipeline.shared.process(
            image: dark, cameraModel: nil, xmp: shadows)).first)
        shadows.experimentalShadows = true
        let experimentalShadows = try XCTUnwrap(rendered(image: AdobeColorPipeline.shared.process(
            image: dark, cameraModel: nil, xmp: shadows)).first)
        XCTAssertGreaterThan(experimentalShadows, legacyShadows + 35)
    }

    func testReadOnlyRealRAWWithToneLensAndNativeHighlights() async throws {
        let source = HighlightsIntegrationTests.source
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("RAW fixture unavailable") }
        var xmp = XMPMetadata(highlights2012: -80, advancedRAWHighlightRecovery: true,
                              shadows2012: 65, whites2012: -45, dehaze: 20,
                              experimentalShadows: true, experimentalWhites: true,
                              experimentalDehaze: true, lensDistortion: 20,
                              lensPurpleDefringe: 10, lensVignette: -20)
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        let baselineSettings = XMPMetadata(highlights2012: -80, advancedRAWHighlightRecovery: true)
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let baseline = await Task.detached {
            RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                xmp: baselineSettings, interactive: true)
        }.value
        XCTAssertNotNil(baseline)
        print("BASELINE_RAW_INTERACTIVE_WALL_S=\(ProcessInfo.processInfo.systemUptime - baselineStart)")
        let started = ProcessInfo.processInfo.systemUptime
        let renderSettings = xmp
        let rendered = await Task.detached {
            RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                xmp: renderSettings, interactive: true)
        }.value
        let image = try XCTUnwrap(rendered?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(image.width, 300)
        XCTAssertGreaterThan(image.height, 300)
        print("EXPERIMENTAL_RAW_INTERACTIVE_WALL_S=\(ProcessInfo.processInfo.systemUptime - started) PIXELS=\(image.width)x\(image.height)")
        xmp.experimentalShadows = false
        XCTAssertNotEqual(ProcessedROIRequest.settingsIdentity(xmp),
                          ProcessedROIRequest.settingsIdentity(XMPMetadata(highlights2012: -80)))
    }

    func testRasterPreviewAndJPEGExportUseSameExperimentalPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumiBase-export-experimental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sample.png")
        let image = CIImage(color: CIColor(red: 0.24, green: 0.15, blue: 0.11))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        let cg = try XCTUnwrap(ctx.createCGImage(image, from: image.extent))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: source)
        let baseline = XMPMetadata(shadows2012: 90)
        let original = try XCTUnwrap(PhotoExportService.shared.exportPhoto(
            asset: PhotoAsset(fileURL: source, xmp: baseline), to: directory.appendingPathComponent("original.jpg")))
        var experiment = baseline
        experiment.experimentalShadows = true
        experiment.lensVignette = -60
        let preview = try XCTUnwrap(RAWImageLoader.shared.renderProcessed(baseImage: image, cameraModel: nil, xmp: experiment))
        XCTAssertEqual(Int(preview.size.width), 64)
        let exported = try XCTUnwrap(PhotoExportService.shared.exportPhoto(
            asset: PhotoAsset(fileURL: source, xmp: experiment), to: directory.appendingPathComponent("experiment.jpg")))
        XCTAssertNotEqual(try Data(contentsOf: original), try Data(contentsOf: exported))
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: exported)))
        XCTAssertEqual(rendered.pixelsWide, 64)
        XCTAssertEqual(rendered.pixelsHigh, 64)
    }

    func testExperimentalAndLensXMPDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumiBase-experimental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("photo.xmp")
        var xmp = XMPMetadata(contrast2012: 42, shadows2012: 80, whites2012: -70,
                              dehaze: 33, texture: 25, experimentalContrast: true,
                              experimentalShadows: true, experimentalWhites: true,
                              experimentalDehaze: true, experimentalTexture: true,
                              lensDistortion: -45, lensPurpleDefringe: 40,
                              lensGreenDefringe: 15, lensVignette: -30)
        try XMPWriter.write(metadata: xmp, to: sidecar, originalFilename: "photo.dng")
        XCTAssertEqual(XMPParser.parse(url: sidecar), xmpWithSidecar(xmp, filename: "photo.xmp"))
        let xml = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(xml.contains("lumibase:LensDistortion=\"-45\""))
        XCTAssertTrue(xml.contains("lumibase:ExperimentalWhites=\"true\""))
        xmp.experimentalWhites = false
        xmp.lensDistortion = nil
        try XMPWriter.write(metadata: xmp, to: sidecar)
        let off = XMPParser.parse(url: sidecar)
        XCTAssertFalse(off.experimentalWhites)
        XCTAssertNil(off.lensDistortion)
        XCTAssertEqual(off.lensGreenDefringe, 15)
    }

    func testMalformedXMLFallbackAndLegacyDefaults() {
        let xml = """
        <rdf:Description xmlns:lumibase="https://github.com/tedyeng/LumiBase/ns/1.0/"
          lumibase:ExperimentalShadows="true" lumibase:LensVignette="+17" >
        """
        let parsed = XMPParser.parse(data: Data(xml.utf8))
        XCTAssertTrue(parsed.experimentalShadows)
        XCTAssertEqual(parsed.lensVignette, 17)
        let legacy = XMPParser.parse(data: Data(XMPWriter.generateXMPXML(metadata: .empty).utf8))
        XCTAssertFalse(legacy.experimentalShadows)
        XCTAssertNil(legacy.lensVignette)
    }

    func testSelectionAndCacheIdentity() {
        let baseline = XMPMetadata(shadows2012: 65)
        var selected = baseline
        selected.experimentalShadows = true
        XCTAssertNotEqual(baseline.thumbnailDevelopCacheIdentity, selected.thumbnailDevelopCacheIdentity)
        selected.lensDistortion = 20
        XCTAssertNotEqual(XMPMetadata(shadows2012: 65, experimentalShadows: true).thumbnailDevelopCacheIdentity,
                          selected.thumbnailDevelopCacheIdentity)
        var options = DevelopSyncOptions.default
        XCTAssertFalse(options.lensCorrections)
        options.checkModified(from: selected)
        XCTAssertTrue(options.shadows)
        XCTAssertTrue(options.lensCorrections)
        var destination = XMPMetadata(lensDistortion: 12, lensVignette: -30)
        options.lensCorrections = false
        options.apply(from: selected, to: &destination)
        XCTAssertTrue(destination.experimentalShadows)
        XCTAssertEqual(destination.lensDistortion, 12)
        options.lensCorrections = true
        options.apply(from: selected, to: &destination)
        XCTAssertEqual(destination.lensDistortion, 20)
        XCTAssertNil(destination.lensVignette)
        destination.resetDevelopSettings()
        XCTAssertFalse(destination.experimentalShadows)
        XCTAssertNil(destination.lensDistortion)
    }

    func testSwitchesAtZeroAndLegacyWithoutLensRemainPixelIdentical() throws {
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let image = CIImage(color: CIColor(red: 0.22, green: 0.31, blue: 0.44)).cropped(to: rect)
        let pipeline = AdobeColorPipeline.shared
        let base = XMPMetadata()
        let original = try rendered(image: pipeline.process(image: image, cameraModel: nil, xmp: base))
        var switched = base
        switched.experimentalContrast = true
        switched.experimentalShadows = true
        switched.experimentalWhites = true
        switched.experimentalDehaze = true
        switched.experimentalTexture = true
        XCTAssertEqual(original, try rendered(image: pipeline.process(image: image, cameraModel: nil, xmp: switched)))
    }

    private func rendered(image: CIImage) throws -> Data {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let context = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: extent,
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Data(bytes)
    }

    private func xmpWithSidecar(_ xmp: XMPMetadata, filename: String) -> XMPMetadata {
        var result = xmp
        result.isLoadedFromSidecar = true
        result.sidecarFilename = filename
        return result
    }
}
