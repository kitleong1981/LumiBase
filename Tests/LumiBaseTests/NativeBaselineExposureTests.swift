import XCTest
import CoreImage
import AppKit
@testable import LumiBase

final class NativeBaselineExposureTests: XCTestCase {
    private let samples = [
        ("ZF7/20260930_102006.dng", 3.0, 0.351947),
        ("Luna/IMG_20261002_182801_002.dng", 2.278541, 0.309187),
        ("Luna/IMG_20261004_154025_051.dng", 0.031837, 0.297393)
    ]

    func testAllNativeConsumersRetainPerFileBaseline() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["RAWImageLoader", "PhotoExportService", "NativeHighlightsService", "ThumbnailLoader"] {
            let source = try String(contentsOf: repo.appendingPathComponent("LumiBase/Services/Image/\(name).swift"))
            XCTAssertFalse(source.contains("baselineExposure ="), "\(name) must retain CIRAWFilter's per-file baseline, not replace it with any constant")
        }
    }

    func testReadOnlyRepresentativeNativeRAWAndFullPipelineExports() async throws {
        guard ProcessInfo.processInfo.environment["LUMIBASE_NATIVE_BASELINE_VALIDATION"] == "1" else {
            throw XCTSkip("Opt-in read-only native RAW validation with external SSD fixtures")
        }
        guard let fixtureRoot = ProcessInfo.processInfo.environment["LUMIBASE_NATIVE_BASELINE_FIXTURES"],
              let outputPath = ProcessInfo.processInfo.environment["LUMIBASE_NATIVE_BASELINE_OUTPUT"] else {
            throw XCTSkip("Set LUMIBASE_NATIVE_BASELINE_FIXTURES and LUMIBASE_NATIVE_BASELINE_OUTPUT")
        }
        let root = URL(fileURLWithPath: fixtureRoot)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = CIContext(options: [.highQualityDownsample: true])
        var stats: [[String: Any]] = []
        for (relative, baseline, diagnosticMean) in samples {
            let url = root.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Exact diagnostic path required")
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
            XCTAssertEqual(Double(raw.baselineExposure), baseline, accuracy: 0.00001)
            raw.exposure = 0; raw.shadowBias = 0; raw.boostShadowAmount = 0; raw.boostAmount = 1
            if #available(macOS 26.0, *) { raw.isHighlightRecoveryEnabled = true }
            let expected = try XCTUnwrap(raw.outputImage)
            let loaded = await RAWImageLoader.shared.loadBaseHolder(from: url, xmp: .empty, useSharedCache: false)
            let holder = try XCTUnwrap(loaded)
            let baseMean = try mean(holder.full, context: context)
            let expectedMean = try mean(expected, context: context)
            XCTAssertEqual(baseMean, expectedMean, accuracy: 0.0001, "Native baseline must survive the production loader")
            XCTAssertEqual(baseMean, diagnosticMean, accuracy: 0.005)
            let asset = PhotoAsset(fileURL: url, xmp: .empty)
            let preview = AdobeColorPipeline.shared.process(image: holder.full, cameraModel: asset.cameraMetadata.model, xmp: .empty, baseHolder: holder)
            let previewMean = try mean(preview, context: context)
            let name = url.deletingPathExtension().lastPathComponent
            let jpegURL = output.appendingPathComponent(name + "-full-export.jpg")
            try PhotoExportService.shared.exportPhoto(asset: asset, to: jpegURL, quality: 1)
            let exported = try XCTUnwrap(CIImage(contentsOf: jpegURL))
            XCTAssertEqual(exported.extent.size, preview.extent.size, "Export must rasterize full resolution")
            let exportMean = try mean(exported, context: context)
            XCTAssertEqual(exportMean, previewMean, accuracy: 0.006, "Neutral full-pipeline preview/export should agree apart from JPEG encoding")
            try writePNG(holder.full, to: output.appendingPathComponent(name + "-native-1024.png"), context: context)
            try writePNG(preview, to: output.appendingPathComponent(name + "-pipeline-1024.png"), context: context)
            let thumbnail = await ThumbnailLoader.shared.loadThumbnail(for: asset, maxPixelSize: 1024)
            let thumbnailCG = try XCTUnwrap(thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let thumbnailMean = try mean(CIImage(cgImage: thumbnailCG), context: context)
            var edited = asset
            edited.xmp.exposure2012 = 0.01
            let editedThumbnail = await ThumbnailLoader.shared.loadThumbnail(for: edited, maxPixelSize: 1024)
            let editedCG = try XCTUnwrap(editedThumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let editedMean = try mean(CIImage(cgImage: editedCG), context: context)
            var advanced = XMPMetadata(highlights2012: -30, advancedRAWHighlightRecovery: true)
            advanced.exposure2012 = 0
            let recipe = try XCTUnwrap(HighlightsSourceRecipe(url: url))
            let highlightsSettings = advanced
            let highlights = await Task.detached {
                NativeHighlightsService.shared.image(source: recipe, xmp: highlightsSettings,
                    cameraModel: asset.cameraMetadata.model, neutralDomain: .nativeRAWExport)
            }.value
            let highlightsMean = try mean(XCTUnwrap(highlights), context: context)
            XCTAssertTrue(highlightsMean.isFinite)
            XCTAssertGreaterThan(highlightsMean, 0.10, "Native highlight endpoints must not revert to the dark fixed baseline")
            stats.append(["source": url.path, "nativeBaseline": raw.baselineExposure,
                "nativeMean": baseMean, "expectedDiagnosticMean": diagnosticMean,
                "pipelineMean": previewMean, "fullExportMean": exportMean,
                "unmodifiedThumbnailMean": thumbnailMean, "editedThumbnailMean": editedMean,
                "nativeHighlightsMinus30Mean": highlightsMean,
                "exportWidth": exported.extent.width, "exportHeight": exported.extent.height])
            print("NATIVE_BASELINE \(relative) baseline=\(raw.baselineExposure) native=\(baseMean) pipeline=\(previewMean) export=\(exportMean) thumbnail=\(thumbnailMean) editedThumbnail=\(editedMean) highlights=\(highlightsMean)")
            RAWImageLoader.shared.clearCache()
        }
        try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("pipeline-stats.json"))
    }

    private func scaled(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = min(1, 1024 / max(extent.width, extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    private func mean(_ image: CIImage, context: CIContext) throws -> Double {
        let image = scaled(image); let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var total = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            total += (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i+1]) + 0.0722 * Double(bytes[i+2])) / 255
        }
        return total / Double(width * height)
    }
    private func writePNG(_ image: CIImage, to url: URL, context: CIContext) throws {
        try context.writePNGRepresentation(of: scaled(image), to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
