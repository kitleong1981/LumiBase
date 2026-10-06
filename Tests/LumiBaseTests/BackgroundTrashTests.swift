import XCTest
import AppKit
@testable import LumiBase

private final class FixtureTrashManager: FileManager, @unchecked Sendable {
    let destination: URL
    var failName: String?
    var entered: (() -> Void)?
    var release: DispatchSemaphore?
    var removedPermanently = 0
    var calls: [String] = []
    init(destination: URL) { self.destination = destination; super.init() }
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        entered?(); release?.wait(); calls.append(url.lastPathComponent)
        if url.lastPathComponent == failName { throw NSError(domain: "fixture", code: 1) }
        try moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
    override func removeItem(at url: URL) throws { removedPermanently += 1; try super.removeItem(at: url) }
}

final class BackgroundTrashTests: XCTestCase {
    private func fixture() throws -> (URL, PhotoAsset, PhotoAsset, FixtureTrashManager) {
        let root = inspectionTestScratchURL("background-trash-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["one.ARW", "one.JPG", "one.xmp", "one.ARW.xmp", "one.JPG.xmp", "two.JPG"] { try Data([1,2,3]).write(to: root.appendingPathComponent(name)) }
        let one = PhotoAsset(fileURL: root.appendingPathComponent("one.ARW"), companionURLs: [root.appendingPathComponent("one.JPG")])
        let two = PhotoAsset(fileURL: root.appendingPathComponent("two.JPG"))
        return (root, one, two, FixtureTrashManager(destination: destination))
    }
    @MainActor func testPendingTrashDoesNotBlockNextSelectionAndFinalizesSuccess() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [one, two]; state.selectAsset(one)
        let entered = expectation(description: "background worker entered")
        fm.entered = { entered.fulfill() }; fm.release = DispatchSemaphore(value: 0)
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        XCTAssertEqual(state.deletingAssetIDs, [one.id])
        XCTAssertEqual(state.primarySelectedAssetID, two.id)
        XCTAssertFalse(state.showDeleteConfirmation)
        await fulfillment(of: [entered], timeout: 2)
        fm.entered = nil; fm.release?.signal(); fm.release = nil
        await state.waitForTrashCompletion()
        XCTAssertEqual(state.allAssets.map(\.id), [two.id])
        XCTAssertTrue(state.deletingAssetIDs.isEmpty)
        XCTAssertEqual(Set(fm.calls), ["one.ARW", "one.JPG", "one.xmp", "one.ARW.xmp", "one.JPG.xmp"])
        XCTAssertEqual(fm.removedPermanently, 0)
    }
    @MainActor func testPartialFailureRetainsAssetAndReportsMovedFiles() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fm.failName = "one.JPG"
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [one, two]; state.selectAsset(one)
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        await state.waitForTrashCompletion()
        XCTAssertEqual(state.allAssets.map(\.id), [one.id, two.id])
        XCTAssertEqual(state.primarySelectedAssetID, two.id, "Do not steal selection after user advances")
        XCTAssertNotNil(state.deleteErrorMessage)
        XCTAssertTrue(state.deleteErrorMessage?.contains("one.JPG") == true)
        XCTAssertTrue(state.deleteErrorMessage?.contains("one.ARW") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.sidecarXMPURL.path))
        XCTAssertEqual(fm.removedPermanently, 0)
    }
    @MainActor func testQueuedXMPCannotResurrectAfterTrash() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [one, two]; state.selectAsset(one)
        let hold = DispatchSemaphore(value: 0)
        state.enqueueFileWorkForTesting { hold.wait() }
        state.setRating(4) // queued behind hold
        state.updateDevelopSettings(isDragging: true) { $0.exposure2012 = 2 }
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        XCTAssertNil(state.liveDevelopXMP)
        XCTAssertNil(state.liveDevelopAssetID)
        state.selectAsset(one); state.setRating(5) // mutation refused while pending
        hold.signal()
        await state.waitForTrashCompletion()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.sidecarXMPURL.path))
        XCTAssertEqual(state.allAssets.map(\.id), [two.id])
        XCTAssertEqual(fm.removedPermanently, 0)
    }
    @MainActor func testAlreadyRunningWriteFinishesBeforeTrashAndStaleWatcherCannotResurrect() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let newSidecar = one.fileURL.appendingPathExtension("xmp")
        try FileManager.default.removeItem(at: newSidecar) // disposable fixture only
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false), fullFolderScan: { _ in [one, two] })
        state.currentFolderURL = root; state.allAssets = [one, two]; state.selectAsset(one)
        let began = expectation(description: "an already-running write")
        let hold = DispatchSemaphore(value: 0)
        state.enqueueFileWorkForTesting {
            began.fulfill(); hold.wait()
            do { try XMPWriter.write(metadata: XMPMetadata(rating: 4), to: newSidecar) }
            catch { XCTFail("Fixture active sidecar write failed: \(error)") }
        }
        await fulfillment(of: [began], timeout: 2)
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        hold.signal(); await state.waitForTrashCompletion()
        XCTAssertTrue(fm.calls.contains("one.ARW.xmp"), "Trash enumerates after active writes complete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSidecar.path))
        state.refreshCurrentFolder()
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertEqual(state.allAssets.map(\.id), [two.id], "Even a stale scan cannot reinsert the trashed group")
    }
    @MainActor func testNextPhotoAdvancedSettingDoesNotWaitBehindPendingTrash() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [one, two]; state.selectAsset(one)
        let hold = DispatchSemaphore(value: 0)
        state.enqueueFileWorkForTesting { hold.wait() }
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        // Guaranteed release keeps the RED test finite even for the old synchronous path.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { hold.signal() }
        let began = ProcessInfo.processInfo.systemUptime
        state.setAdvancedRAWHighlightRecovery(false, for: two.id)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.15, "Next-photo editing must not block MainActor on Trash")
        XCTAssertEqual(state.allAssets.first(where: { $0.id == two.id })?.xmp.advancedRAWHighlightRecovery, false)
        await state.waitForTrashCompletion()
        let drained = expectation(description: "advanced sidecar queue drained")
        state.enqueueFileWorkForTesting { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        let saved = XMPParser.parse(data: try Data(contentsOf: two.sidecarXMPURL))
        XCTAssertEqual(saved.advancedRAWHighlightRecovery, false)
    }
    @MainActor func testMissingPrimaryIsFailureNotSuccessfulTrashOfCompanions() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: one.fileURL) // fixture simulates an unavailable original
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.allAssets = [one, two]; state.selectAsset(one)
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        await state.waitForTrashCompletion()
        XCTAssertTrue(fm.calls.isEmpty, "Unavailable primary must not silently trash the remaining companions")
        XCTAssertNotNil(state.deleteErrorMessage)
        XCTAssertEqual(Set(state.allAssets.map(\.id)), [one.id, two.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.companionURLs[0].path))
        XCTAssertEqual(fm.removedPermanently, 0)
    }
    @MainActor func testWatcherKeepsPartiallyFailedGroupEvenWhenPrimaryIsMissing() async throws {
        let (root, one, two, fm) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        fm.failName = "one.JPG"
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false),
            fullFolderScan: { _ in [two, PhotoAsset(fileURL: one.companionURLs[0])] })
        state.currentFolderURL = root; state.allAssets = [one, two]; state.selectAsset(one)
        state.requestDeleteSelectedPhotos(); state.confirmDeletePendingPhotos(fileManager: fm)
        await state.waitForTrashCompletion()
        state.refreshCurrentFolder()
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertTrue(state.allAssets.contains { $0.id == one.id })
        XCTAssertEqual(Set(state.allAssets.map(\.id)), [one.id, two.id], "The retained companion must not become a resurrected standalone asset")
        XCTAssertNotNil(state.deleteErrorMessage)
        XCTAssertEqual(state.primarySelectedAssetID, two.id)
    }
}
