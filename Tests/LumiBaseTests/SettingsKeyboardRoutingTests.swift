import XCTest
import SwiftUI
import AppKit
@testable import LumiBase

final class SettingsKeyboardRoutingTests: XCTestCase {
    @MainActor func testActualSettingsEscapeDoesNotReachWorkspace() async throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let root = inspectionTestScratchURL("settings-keys-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let assets = try (0..<3).map { index -> PhotoAsset in
            let url = root.appendingPathComponent("\(index).JPG"); try data.write(to: url); return PhotoAsset(fileURL: url)
        }
        state.allAssets = assets; state.selectAsset(assets[1]); state.workspaceMode = .library
        state.isHistogramEnabled = false
        state.viewMode = .loupe
        let main = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.contentView = NSHostingView(rootView: WorkspaceView(appState: state))
        let settings = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: PerformanceSettingsView(settings: .shared))
        defer { main.orderOut(nil); main.contentView = nil; settings.orderOut(nil); settings.contentView = nil }
        // swift-test's unbundled xctest cannot activate an AppKit application.
        // Run this same test under the bundled native xctest host for real key focus.
        guard Bundle.main.bundleIdentifier == "com.lumibase.settings-keyboard-tests" else {
            throw XCTSkip("Requires bundled native xctest host; exercised separately with real key windows")
        }
        NSApplication.shared.finishLaunching()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        NotificationCenter.default.post(name: NSNotification.Name("LumiBaseToggleZoom"), object: nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        settings.makeKeyAndOrderFront(nil); settings.becomeKey()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(settings.isKeyWindow)
        func surface(_ view: NSView) -> InspectionSurface.Surface? { if let s = view as? InspectionSurface.Surface { return s }; return view.subviews.compactMap(surface).first }
        let target = try XCTUnwrap(surface(try XCTUnwrap(main.contentView)))
        XCTAssertTrue(target.owner?.presentedZoomed ?? false)
        func event(_ window: NSWindow, _ key: UInt16, _ text: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: key))
        }
        for (key, text) in [(UInt16(5), "g"), (UInt16(6), "z"), (UInt16(124), "\u{f703}")] {
            NSApplication.shared.sendEvent(try event(settings, key, text))
        }
        XCTAssertEqual(state.primarySelectedAssetID, assets[1].id)
        XCTAssertEqual(state.viewMode, .loupe)
        XCTAssertTrue(target.owner?.presentedZoomed ?? false)
        // Native editor owns cancellation, not workspace or Settings close.
        final class Editor: NSTextView {
            var canceled = false
            override func cancelOperation(_ sender: Any?) { canceled = true }
        }
        let editor = Editor(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        settings.contentView?.addSubview(editor); settings.makeFirstResponder(editor)
        NSApplication.shared.sendEvent(try event(settings, 53, "\u{1b}"))
        XCTAssertTrue(editor.canceled); XCTAssertTrue(settings.isVisible)
        settings.makeFirstResponder(nil); editor.removeFromSuperview()
        // Exercise native tracking notifications: an open picker must receive Escape.
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NSApplication.shared.sendEvent(try event(settings, 53, "\u{1b}"))
        XCTAssertTrue(settings.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        NSApplication.shared.sendEvent(try event(settings, 53, "\u{1b}"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(target.owner?.presentedZoomed ?? false)
        XCTAssertEqual(state.primarySelectedAssetID, assets[1].id)
        XCTAssertFalse(settings.isVisible, "Escape must close only Settings")
        XCTAssertEqual(state.viewMode, .loupe, "Settings Escape must not switch main UI to Grid")
        main.makeKeyAndOrderFront(nil); main.becomeKey()
        NSApplication.shared.sendEvent(try event(main, 53, "\u{1b}"))
        XCTAssertEqual(state.viewMode, .grid, "Main-window Escape retains Loupe→Grid")
    }
}
