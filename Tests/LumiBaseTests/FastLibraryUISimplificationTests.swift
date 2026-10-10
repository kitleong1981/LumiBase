import XCTest
import SwiftUI
import AppKit
@testable import LumiBase

final class FastLibraryUISimplificationTests: XCTestCase {
    @MainActor private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["LUMIBASE_UI_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }
    @MainActor private func labels(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 30, let node = object as? NSObject else { return [] }
        func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        let own = ["accessibilityLabel", "accessibilityValue", "accessibilityHelp"].compactMap { value($0) as? String }
        let children = (value("accessibilityChildren") as? [Any]) ?? []
        return own + children.flatMap { labels($0, depth: depth + 1) } + ((object as? NSView)?.subviews ?? []).flatMap { labels($0, depth: depth + 1) }
    }
    @MainActor func testHostedLoupeLibraryOmitsComparisonMenu() async throws {
        let root = inspectionTestScratchURL("ui-loupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = root.appendingPathComponent("fixture.JPG")
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false)); state.isHistogramEnabled = false
        let asset = PhotoAsset(fileURL: url); state.allAssets = [asset]; state.selectAsset(asset)
        let host = NSHostingView(rootView: LoupeView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for mode in [WorkspaceMode.library, .develop] {
            state.workspaceMode = mode; try await Task.sleep(nanoseconds: 600_000_000); host.layoutSubtreeIfNeeded()
            let menus = descendants(host).filter { $0 is NSPopUpButton }
            try capture(host, name: "loupe-\(mode)")
            print("HOSTED_LOUPE \(mode) menus=\(menus.count)")
            XCTAssertEqual(menus.count, mode == .library ? 0 : 1)
        }
    }

    @MainActor func testHostedBottomLibraryOmitsComparisonMenu() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false)); state.viewMode = .loupe
        let host = NSHostingView(rootView: BottomControlsBarView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for mode in [WorkspaceMode.library, .develop] {
            state.workspaceMode = mode; try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
            let menus = descendants(host).filter { String(describing: type(of: $0)).contains("Menu") || $0 is NSPopUpButton }
            try capture(host, name: "bottom-\(mode)")
            print("HOSTED_BOTTOM \(mode) menus=\(menus.map { String(describing: type(of: $0)) })")
            XCTAssertEqual(menus.count, mode == .library ? 1 : 2)
        }
    }

    @MainActor func testHostedCompactHeaderSeparatesModeFromSearch() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        state.filterCriteria.searchText = "active search"; state.filterCriteria.minimumRating = 3
        let host = NSHostingView(rootView: TopFilterBarView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first)
        let rect = search.convert(search.bounds, to: host)
        try capture(host, name: "header-700-active")
        print("HOSTED_HEADER fitting=\(host.fittingSize) search=\(rect)")
        XCTAssertLessThanOrEqual(host.fittingSize.height, 80, "Two compact rows must not wrap the hidden workspace label")
        XCTAssertLessThanOrEqual(host.fittingSize.width, 700, "Compact header must fit the actual 700px center")
        XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, 700)
        XCTAssertGreaterThan(rect.width, 100)
    }

    @MainActor func testHostedInspectorLibraryOmitsEditingAndDevelopRetainsIt() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        var xmp = XMPMetadata.empty; xmp.exposure2012 = 1
        xmp.title = "Retained metadata title"; xmp.caption = "Retained metadata caption"
        let root = inspectionTestScratchURL("ui-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = PhotoAsset(fileURL: root.appendingPathComponent("absent-ui-fixture.JPG"), xmp: xmp)
        state.allAssets = [asset]; state.selectAsset(asset); state.isHistogramEnabled = false
        let host = NSHostingView(rootView: RightInspectorView(appState: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 1600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for mode in [WorkspaceMode.library, .develop] {
            state.workspaceMode = mode
            try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
            let text = labels(host).joined(separator: " | ")
            try capture(host, name: "inspector-\(mode)")
            print("HOSTED_INSPECTOR \(mode): \(Set(labels(host)).sorted())")
            // Native popup is constructed by DevelopBasicPanelView, not a model surrogate.
            XCTAssertEqual(text.contains("Adobe Color"), mode == .develop, "Develop profile popup must not be instantiated in Library")
            XCTAssertTrue(text.contains("Retained metadata title")); XCTAssertTrue(text.contains("Retained metadata caption"))
        }
        // Even a retained crop tool selection cannot instantiate editing UI in Library.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for mode in [WorkspaceMode.library, .develop] {
            state.workspaceMode = mode; state.activeDevelopTool = .crop
            try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
            let menus = descendants(host).filter { $0 is NSPopUpButton }
            print("HOSTED_CROP \(mode) menus=\(menus.count)")
            XCTAssertEqual(menus.count, mode == .library ? 0 : 1)
            try capture(host, name: "inspector-crop-\(mode)")
        }
    }
}
