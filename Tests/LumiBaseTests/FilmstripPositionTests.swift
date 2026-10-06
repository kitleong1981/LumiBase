import XCTest
import AppKit
import SwiftUI
@testable import LumiBase

final class FilmstripPositionTests: XCTestCase {
    @MainActor
    func testHostedFilmstripRestoresActiveOnLayoutReturnAndChangeWithoutManualSnapping() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.viewMode = .loupe
        state.isFilmstripVisible = true
        state.allAssets = (0..<120).map { PhotoAsset(fileURL: URL(fileURLWithPath: "/fixtures/strip-\(String(format: "%03d", $0)).jpg")) }
        let active = state.allAssets[90].id
        state.primarySelectedAssetID = active
        state.selectedAssetIDs = [state.allAssets[2].id, active]
        let host = NSHostingView(rootView: AnyView(FilmstripView(appState: state)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 85), styleMask: [.borderless], backing: .buffered, defer: false)
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
        func settle() async throws { try render(); try await Task.sleep(nanoseconds: 400_000_000) }
        func assertVisible(_ index: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let scroll = try XCTUnwrap(scrollView(host))
            let bounds = scroll.contentView.bounds
            let center = CGFloat(index) * 96 + 55
            XCTAssertTrue(bounds.minX <= center && bounds.maxX >= center, "Active thumbnail \(index) must be visible; clip=\(bounds)", file: file, line: line)
        }
        try await settle()
        try assertVisible(90)
        let scroll = try XCTUnwrap(scrollView(host))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertLessThan(scroll.contentView.bounds.minX, 1, "Manual browsing must not snap back")
        state.primarySelectedAssetID = state.allAssets[60].id
        try await settle()
        try assertVisible(60)
        state.viewMode = .grid
        host.rootView = AnyView(Color.clear)
        try await settle()
        state.viewMode = .loupe
        host.rootView = AnyView(FilmstripView(appState: state))
        try await settle()
        try assertVisible(60)
        state.isFilmstripVisible = false
        host.rootView = AnyView(Color.clear)
        try await settle()
        state.isFilmstripVisible = true
        host.rootView = AnyView(FilmstripView(appState: state))
        try await settle()
        try assertVisible(60)
        state.primarySelectedAssetID = "missing"
        try await settle()
        let returned = try XCTUnwrap(scrollView(host))
        returned.contentView.scroll(to: .zero)
        returned.reflectScrolledClipView(returned.contentView)
        state.primarySelectedAssetID = state.allAssets[90].id
        state.filterCriteria.searchText = "strip-000.jpg"
        try await settle()
        XCTAssertEqual(state.primarySelectedAssetID, active, "Filtering must not substitute a selection")
        XCTAssertLessThan(returned.contentView.bounds.minX, 1)
        state.filterCriteria.reset()
        try await settle()
        try assertVisible(90)
        state.primarySelectedAssetID = nil
        try await settle()
        returned.contentView.scroll(to: .zero)
        returned.reflectScrolledClipView(returned.contentView)
        try await settle()
        XCTAssertNil(state.primarySelectedAssetID)
        XCTAssertLessThan(returned.contentView.bounds.minX, 1)
    }
}
