import XCTest
import Foundation
@testable import LumiBase

/// Opt-in read-only reference probe. JPEGs are written to a separate scratch directory.
final class RawReferenceDiagnosticsTests: XCTestCase {
    func testRenderProvidedRAWAgainstLightroomFinal() throws {
        guard let source = ProcessInfo.processInfo.environment["LUMIBASE_RAW_DEBUG_DIR"],
              let destination = ProcessInfo.processInfo.environment["LUMIBASE_RAW_DEBUG_EVIDENCE_DIR"] else {
            throw XCTSkip("Explicit reference source and evidence directory required")
        }
        let input = URL(fileURLWithPath: source, isDirectory: true)
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for stem in ["O9266983-DXO6", "O9267000-DXO6"] {
            let raw = input.appendingPathComponent(stem + ".dng")
            let embedded = output.appendingPathComponent(stem + "-LR-final-embedded.xmp")
            let lr = input.appendingPathComponent(stem + "_raw_4k.jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: lr.path))
            var xmp = XMPParser.parse(url: embedded)
            let sidecar = XMPParser.parse(url: input.appendingPathComponent(stem + ".xmp"))
            print("REFERENCE_METADATA \(stem): LR JPEG EV=\(xmp.exposure2012 ?? -999) HL=\(xmp.highlights2012 ?? -999) SH=\(xmp.shadows2012 ?? -999) WH=\(xmp.whites2012 ?? -999) profile=\(xmp.cameraProfile ?? "none"), sidecar EV=\(sidecar.exposure2012 ?? -999) HL=\(sidecar.highlights2012 ?? -999)")
            XCTAssertEqual(xmp.highlights2012, -90)
            XCTAssertEqual(xmp.whites2012, -90)
            XCTAssertEqual(xmp.shadows2012, 70)
            XCTAssertEqual(xmp.cameraProfile, "Adobe Standard")
            let zero = PhotoAsset(fileURL: raw, xmp: XMPMetadata())
            let zeroStart = ProcessInfo.processInfo.systemUptime
            let zeroPath = output.appendingPathComponent(stem + "-LB-zero.jpg")
            try PhotoExportService.shared.exportPhoto(asset: zero, to: zeroPath, quality: 0.98)
            print("REFERENCE_RENDER_ZERO \(stem) wall_s=\(ProcessInfo.processInfo.systemUptime - zeroStart)")
            // The source sidecars reflect an earlier edit state, not the LR final JPEG.
            // Use the settings embedded in that JPEG for the same-value reference.
            xmp.experimentalContrast = true
            xmp.experimentalShadows = false
            xmp.experimentalWhites = false
            xmp.experimentalDehaze = false
            xmp.experimentalTexture = false
            let edited = PhotoAsset(fileURL: raw, xmp: xmp)
            let editedStart = ProcessInfo.processInfo.systemUptime
            let editPath = output.appendingPathComponent(stem + "-LB-final-contrast-only.jpg")
            try PhotoExportService.shared.exportPhoto(asset: edited, to: editPath, quality: 0.98)
            print("REFERENCE_RENDER_EDITED \(stem) wall_s=\(ProcessInfo.processInfo.systemUptime - editedStart)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: editPath.path))
            let experiments: [(String, KeyPath<XMPMetadata, Bool>)] = [
                ("shadow-only", \.experimentalShadows),
                ("whites-only", \.experimentalWhites),
                ("dehaze-only", \.experimentalDehaze)
            ]
            for (label, keyPath) in experiments {
                var single = xmp
                switch keyPath {
                case \.experimentalShadows: single.experimentalShadows = true
                case \.experimentalWhites: single.experimentalWhites = true
                default: single.experimentalDehaze = true
                }
                let destination = output.appendingPathComponent(stem + "-LB-final-1.12.2-" + label + ".jpg")
                try PhotoExportService.shared.exportPhoto(asset: PhotoAsset(fileURL: raw, xmp: single), to: destination, quality: 0.98)
            }
            xmp.experimentalShadows = true
            xmp.experimentalWhites = true
            xmp.experimentalDehaze = true
            let allExperimental = PhotoAsset(fileURL: raw, xmp: xmp)
            let allPath = output.appendingPathComponent(stem + "-LB-final-1.12.2-monotone.jpg")
            try PhotoExportService.shared.exportPhoto(asset: allExperimental, to: allPath, quality: 0.98)
            XCTAssertTrue(FileManager.default.fileExists(atPath: allPath.path))
            xmp.advancedRAWHighlightRecovery = true
            let nativeStart = ProcessInfo.processInfo.systemUptime
            let nativePath = output.appendingPathComponent(stem + "-LB-final-1.12.2-native-highlights.jpg")
            try PhotoExportService.shared.exportPhoto(asset: PhotoAsset(fileURL: raw, xmp: xmp), to: nativePath, quality: 0.98)
            print("REFERENCE_RENDER_NATIVE_HIGHLIGHTS \(stem) wall_s=\(ProcessInfo.processInfo.systemUptime - nativeStart)")
        }
    }
}
