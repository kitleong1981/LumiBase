import XCTest
import Combine
import AppKit
import SwiftUI
import CoreImage
import ImageIO
@testable import LumiBase

final class SyncLargeBatchRefreshTests: XCTestCase {
    @MainActor func testHostedLoupeStaysVisibleAcross75TargetSync() async throws {
        let root = inspectionTestScratchURL("sync-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.tiff")
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        let cg = try XCTUnwrap(CIContext().createCGImage(
            CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.1)).cropped(to: rect), from: rect))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var xmp = XMPMetadata(); xmp.exposure2012 = 0.35
        let source = PhotoAsset(fileURL: sourceURL, xmp: xmp)
        let targets = (0..<75).map { PhotoAsset(fileURL: root.appendingPathComponent("target-\($0).tiff")) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [source] + targets
        state.primarySelectedAssetID = source.id
        state.selectedAssetIDs = Set(state.allAssets.map(\.id))
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func centerGreen() throws -> CGFloat {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
                .usingColorSpace(.deviceRGB)!.greenComponent
        }
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertGreaterThan(try centerGreen(), 0.2)
        state.syncDevelopSettings(options: .default)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(try centerGreen(), 0.2, "Source Loupe must not remain a spinner after syncing targets")
        XCTAssertEqual(state.primarySelectedAssetID, source.id)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @MainActor func testSync75TargetsPublishesCatalogOnceAndPreservesSelectedSource() async throws {
        let root = inspectionTestScratchURL("sync-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceXMP = XMPMetadata()
        sourceXMP.exposure2012 = 0.35
        let source = PhotoAsset(fileURL: root.appendingPathComponent("source.tiff"), xmp: sourceXMP)
        let targets = (0..<75).map { PhotoAsset(fileURL: root.appendingPathComponent("target-\($0).tiff")) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [source] + targets
        state.primarySelectedAssetID = source.id
        state.selectedAssetIDs = Set(state.allAssets.map(\.id))
        let published = Counter()
        let subscription = state.$allAssets.dropFirst().sink { _ in published.increment() }
        defer { subscription.cancel() }
        state.syncDevelopSettings(options: .default)
        XCTAssertEqual(published.count, 1, "One multi-photo sync is one catalog publication")
        XCTAssertEqual(state.primarySelectedAssetID, source.id)
        XCTAssertEqual(state.allAssets.first?.xmp, sourceXMP)
        XCTAssertTrue(state.allAssets.dropFirst().allSatisfy { $0.xmp.exposure2012 == 0.35 })
        try await Task.sleep(nanoseconds: 650_000_000) // let isolated sidecar writes finish
        let written = targets.filter { FileManager.default.fileExists(atPath: $0.sidecarXMPURL.path) }
        XCTAssertEqual(written.count, 75, "Every selected target should receive a sidecar")
        let persisted = try Data(contentsOf: targets[0].sidecarXMPURL)
        XCTAssertEqual(XMPParser.parse(data: persisted).exposure2012, 0.35)
    }

    @MainActor func test75FileEventsCoalesceToOneFolderRefresh() async throws {
        let root = inspectionTestScratchURL("sync-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let asset = PhotoAsset(fileURL: root.appendingPathComponent("source.tiff"))
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false),
            quickFolderScan: { _ in [] }, fullFolderScan: { _ in counter.increment(); return [asset] })
        state.currentFolderURL = root
        state.allAssets = [asset]
        state.primarySelectedAssetID = asset.id
        for _ in 0..<75 { state.scheduleFolderRefresh() }
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(state.primarySelectedAssetID, asset.id)
    }

    @MainActor func testRealSidecarBurstDoesNotRescanEveryWrite() async throws {
        let root = inspectionTestScratchURL("sync-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let asset = PhotoAsset(fileURL: root.appendingPathComponent("source.tiff"))
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false),
            quickFolderScan: { _ in [asset] }, fullFolderScan: { _ in counter.increment(); return [asset] })
        state.openFolder(url: root)
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = counter.count
        for i in 0..<75 {
            try Data("<xmp/>".utf8).write(to: root.appendingPathComponent("\(i).xmp"))
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(counter.count, before, "Watcher must observe the sidecar writes")
        XCTAssertLessThanOrEqual(counter.count - before, 2, "Watcher must coalesce many sidecar changes")
        XCTAssertEqual(state.primarySelectedAssetID, asset.id)
    }
}
