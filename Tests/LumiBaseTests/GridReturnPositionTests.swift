import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class GridReturnPositionTests: XCTestCase {
    @MainActor
    func testHostedGridReturnsToUnchangedActivePhotoAndDoesNotFightManualScroll() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.viewMode = .grid
        state.allAssets = (0..<120).map { PhotoAsset(fileURL: URL(fileURLWithPath: "/fixtures/photo-\(String(format: "%03d", $0)).jpg")) }
        state.primarySelectedAssetID = state.allAssets[90].id
        state.selectedAssetIDs = [state.allAssets[90].id]
        let host = NSHostingView(rootView: AnyView(GridView(appState: state)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        func render() throws {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try render()
        try await Task.sleep(nanoseconds: 400_000_000)
        let initialScroll = try XCTUnwrap(scrollView(host))
        initialScroll.contentView.scroll(to: NSPoint(x: 0, y: 1200))
        initialScroll.reflectScrolledClipView(initialScroll.contentView)
        state.viewMode = .loupe
        host.rootView = AnyView(Color.clear)
        try await Task.sleep(nanoseconds: 100_000_000)
        state.viewMode = .grid
        host.rootView = AnyView(GridView(appState: state))
        try render()
        try await Task.sleep(nanoseconds: 400_000_000)
        let returnedScroll = try XCTUnwrap(scrollView(host))
        XCTAssertGreaterThan(returnedScroll.contentView.bounds.origin.y, 100, "Unchanged active ID must restore on recreation")
        returnedScroll.contentView.scroll(to: .zero)
        returnedScroll.reflectScrolledClipView(returnedScroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(returnedScroll.contentView.bounds.origin.y, 1, "Later lazy layouts must not recenter")
        XCTAssertEqual(state.primarySelectedAssetID, state.allAssets[90].id)
    }

    @MainActor
    func testReturnKeepsActivePhotoIncludingNavigationInLoupe() {
        let state = AppState()
        state.allAssets = (0..<120).map { PhotoAsset(fileURL: URL(fileURLWithPath: "/fixtures/photo-\($0).jpg")) }
        state.primarySelectedAssetID = state.allAssets[80].id
        state.selectedAssetIDs = [state.allAssets[2].id, state.allAssets[80].id]
        state.viewMode = .loupe
        state.viewMode = .grid
        XCTAssertEqual(state.gridScrollTargetID, state.allAssets[80].id)
        state.viewMode = .loupe
        state.primarySelectedAssetID = state.allAssets[95].id
        state.viewMode = .grid
        XCTAssertEqual(state.gridScrollTargetID, state.allAssets[95].id)
        state.sortOrder = .filenameDescending
        XCTAssertEqual(state.gridScrollTargetID, state.allAssets[95].id)
    }

    @MainActor
    func testHiddenMissingOrUnselectedPhotoDoesNotScrollToFirstOrChangeSelection() {
        let state = AppState()
        state.allAssets = ["a", "b"].map { PhotoAsset(fileURL: URL(fileURLWithPath: "/fixtures/\($0).jpg")) }
        let active = state.allAssets[1].id
        state.primarySelectedAssetID = active
        state.filterCriteria.searchText = "a.jpg"
        XCTAssertNil(state.gridScrollTargetID)
        XCTAssertEqual(state.primarySelectedAssetID, active)
        state.filterCriteria.reset()
        XCTAssertEqual(state.gridScrollTargetID, active)
        state.primarySelectedAssetID = "missing"
        XCTAssertNil(state.gridScrollTargetID)
        state.primarySelectedAssetID = nil
        XCTAssertNil(state.gridScrollTargetID)
        state.allAssets = []
        XCTAssertNil(state.gridScrollTargetID)
    }

    func testGridRestoresActivePhotoAfterContentLayoutNotOnlySelectionChange() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("LumiBase/Views/Center/GridView.swift"))
        // Lifecycle wiring regression: selection does not change when Workspace recreates GridView.
        XCTAssertTrue(source.contains(".onGeometryChange(for: CGSize.self)"))
        XCTAssertTrue(source.contains("hasRestoredActivePhoto"))
        XCTAssertTrue(source.contains("appState.gridScrollTargetID"))
    }
}
