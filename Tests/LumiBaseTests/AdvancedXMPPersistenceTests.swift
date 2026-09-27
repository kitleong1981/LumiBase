import XCTest
import AppKit
@testable import LumiBase

final class AdvancedXMPPersistenceTests: XCTestCase {
    @MainActor func testPendingSliderWriteCannotRevertImmediateCheckboxPersistence() async throws {
        _ = NSApplication.shared
        let root = inspectionTestScratchURL("advanced-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = PhotoAsset(fileURL: root.appendingPathComponent("photo.dng"))
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]; state.primarySelectedAssetID = asset.id
        state.updateDevelopSettings(for: asset.id, isDragging: false) { $0.highlights2012 = -80 }
        state.setAdvancedRAWHighlightRecovery(true, for: asset.id)
        XCTAssertEqual(XMPParser.parse(url: asset.sidecarXMPURL).advancedRAWHighlightRecovery, true)
        XCTAssertEqual(XMPParser.parse(url: asset.sidecarXMPURL).highlights2012, -80)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(XMPParser.parse(url: asset.sidecarXMPURL).advancedRAWHighlightRecovery, true)
    }

    @MainActor func testRealRAWReopenedSidecarSelectsPixelsRegardlessOfLegacyPreference() async throws {
        let source = HighlightsIntegrationTests.source
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("RAW fixture unavailable") }
        let root = inspectionTestScratchURL("advanced-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = NativeHighlightsService.isEnabled
        defer { NativeHighlightsService.isEnabled = previous }
        var xmp = XMPMetadata(temperature: 3650, tint: 8, highlights2012: -80)
        let loaded = await RAWImageLoader.shared.loadBaseHolder(from: source, xmp: xmp, useSharedCache: false)
        let holder = try XCTUnwrap(loaded)
        func pixels(_ enabled: Bool, legacy: Bool) async throws -> Data {
            xmp.advancedRAWHighlightRecovery = enabled
            let sidecar = root.appendingPathComponent("\(enabled).xmp")
            try XMPWriter.write(metadata: xmp, to: sidecar)
            let reopened = XMPParser.parse(url: sidecar)
            NativeHighlightsService.isEnabled = legacy
            let result = await Task.detached {
                RAWImageLoader.shared.renderProcessed(baseHolder: holder, cameraModel: nil,
                    xmp: reopened, interactive: true)
            }.value
            let image = try XCTUnwrap(result?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        let advanced = try await pixels(true, legacy: false)
        let standard = try await pixels(false, legacy: true)
        XCTAssertNotEqual(advanced, standard)
    }

    func testSyncHighlightsCopiesPerPhotoRecoveryOnlyWhenHighlightsSelected() {
        let source = XMPMetadata(highlights2012: -80, advancedRAWHighlightRecovery: true)
        var target = XMPMetadata(highlights2012: -20, advancedRAWHighlightRecovery: false)
        var options = DevelopSyncOptions.default
        options.highlights = false
        options.apply(from: source, to: &target)
        XCTAssertEqual(target.advancedRAWHighlightRecovery, false)
        options.highlights = true
        options.apply(from: source, to: &target)
        XCTAssertEqual(target.advancedRAWHighlightRecovery, true)
        XCTAssertEqual(target.highlights2012, -80)
    }

    func testExplicitPerPhotoPolicyOverridesGlobalPreferenceInCacheIdentity() {
        let previous = NativeHighlightsService.isEnabled
        defer { NativeHighlightsService.isEnabled = previous }
        let standard = XMPMetadata(highlights2012: -80, advancedRAWHighlightRecovery: false)
        let advanced = XMPMetadata(highlights2012: -80, advancedRAWHighlightRecovery: true)
        NativeHighlightsService.isEnabled = false
        XCTAssertTrue(NativeHighlightsService.isAdvancedEnabled(for: advanced))
        XCTAssertFalse(NativeHighlightsService.isAdvancedEnabled(for: standard))
        XCTAssertNotEqual(ProcessedROIRequest.settingsIdentity(standard), ProcessedROIRequest.settingsIdentity(advanced))
        NativeHighlightsService.isEnabled = true
        XCTAssertFalse(NativeHighlightsService.isAdvancedEnabled(for: standard))
        XCTAssertNotEqual(ProcessedROIRequest.settingsIdentity(standard), ProcessedROIRequest.settingsIdentity(advanced))
    }

    @MainActor func testPerPhotoToggleSurvivesReopenWithoutAutoSyncingNeighbors() async throws {
        _ = NSApplication.shared
        let root = inspectionTestScratchURL("advanced-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PhotoAsset(fileURL: root.appendingPathComponent("a.dng"), xmp: XMPMetadata(highlights2012: -80))
        let b = PhotoAsset(fileURL: root.appendingPathComponent("b.dng"), xmp: XMPMetadata(highlights2012: -80))
        try Data([1, 2, 3]).write(to: a.fileURL)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [a, b]
        state.primarySelectedAssetID = a.id
        state.selectedAssetIDs = [a.id, b.id]
        state.isAutoSyncEnabled = true
        state.setAdvancedRAWHighlightRecovery(true, for: a.id)
        XCTAssertEqual(XMPParser.parse(url: a.sidecarXMPURL).advancedRAWHighlightRecovery, true,
                       "A checkbox change must reach disk before the app can be closed")
        XCTAssertEqual(state.allAssets[0].xmp.advancedRAWHighlightRecovery, true)
        XCTAssertNil(state.allAssets[1].xmp.advancedRAWHighlightRecovery)
        XCTAssertEqual(state.liveDevelopXMP?.advancedRAWHighlightRecovery, true)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(XMPParser.parse(url: a.sidecarXMPURL).advancedRAWHighlightRecovery, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.sidecarXMPURL.path))
        state.setAdvancedRAWHighlightRecovery(false, for: a.id)
        XCTAssertEqual(XMPParser.parse(url: a.sidecarXMPURL).advancedRAWHighlightRecovery, false)
        try await Task.sleep(nanoseconds: 700_000_000)
        let reopened = XMPParser.parse(url: a.sidecarXMPURL)
        XCTAssertEqual(reopened.advancedRAWHighlightRecovery, false)
        XCTAssertEqual(reopened.highlights2012, -80)
        XCTAssertEqual(FolderScanner.parseAsset(fileURL: a.fileURL)?.xmp.advancedRAWHighlightRecovery, false)
    }

    @MainActor func testFailedSidecarWriteDoesNotLieAboutEnabledState() {
        _ = NSApplication.shared
        let file = inspectionTestScratchURL("missing-parent-\(UUID().uuidString)/photo.dng")
        let asset = PhotoAsset(fileURL: file, xmp: XMPMetadata(highlights2012: -80))
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [asset]
        state.primarySelectedAssetID = asset.id
        state.setAdvancedRAWHighlightRecovery(true, for: asset.id)
        XCTAssertNil(state.allAssets[0].xmp.advancedRAWHighlightRecovery)
        XCTAssertNotNil(state.xmpSaveError)
    }

    func testNamespacedAdvancedRecoveryRoundTripsBothOnAndOff() throws {
        let root = inspectionTestScratchURL("advanced-xmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for enabled in [true, false] {
            var source = XMPMetadata(highlights2012: -75, whites2012: -15)
            source.advancedRAWHighlightRecovery = enabled
            let path = root.appendingPathComponent(enabled ? "on.xmp" : "off.xmp")
            try XMPWriter.write(metadata: source, to: path)
            let xml = try String(contentsOf: path)
            XCTAssertTrue(xml.contains("xmlns:lumibase="))
            XCTAssertTrue(xml.contains("lumibase:AdvancedRAWHighlightRecovery=\"\(enabled ? "true" : "false")\""))
            let reopened = XMPParser.parse(url: path)
            XCTAssertEqual(reopened.advancedRAWHighlightRecovery, enabled)
            XCTAssertEqual(reopened.highlights2012, -75)
            XCTAssertEqual(reopened.whites2012, -15)
        }
    }

    func testLegacyXMPWithoutFlagDoesNotInventPreference() {
        let xml = XMPWriter.generateXMPXML(metadata: XMPMetadata(highlights2012: -75))
        XCTAssertFalse(xml.contains("AdvancedRAWHighlightRecovery"))
        let legacy = XMPParser.parse(data: Data(xml.utf8))
        XCTAssertNil(legacy.advancedRAWHighlightRecovery)
    }
}
