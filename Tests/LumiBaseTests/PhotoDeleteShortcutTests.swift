import XCTest
import AppKit
@testable import LumiBase

final class PhotoDeleteShortcutTests: XCTestCase {
    @MainActor func testFocusBoundsAndTextInputsNeverRequestDeletion() throws {
        _ = NSApplication.shared
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let asset = PhotoAsset(fileURL: URL(fileURLWithPath: "/fixture/never-delete.tiff"))
        state.allAssets = [asset]; state.selectAsset(asset)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let root = try XCTUnwrap(window.contentView)
        let surface = PhotoKeyboardFocusSurface.Surface(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        root.addSubview(surface); state.photoKeyboardSurfaces.add(surface)
        defer { window.contentView = nil }
        func click(_ x: CGFloat) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: x, y: 100),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            state.updatePhotoKeyboardFocus(event)
        }
        func key(_ flags: NSEvent.ModifierFlags = [], _ code: UInt16 = 51) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code))
        }
        try click(400)
        XCTAssertFalse(state.photoBrowserHasKeyboardFocus)
        XCTAssertFalse(state.handleGlobalKeyEvent(try key()))
        try click(100)
        XCTAssertTrue(state.photoBrowserHasKeyboardFocus)
        XCTAssertNil(surface.hitTest(.zero))
        for field in [NSTextField(), NSSearchField(), NSTextField(string: "12"), NSTextField(string: "filename")] {
            root.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            for flags: NSEvent.ModifierFlags in [[], [.command], [.function]] {
                XCTAssertFalse(state.handleGlobalKeyEvent(try key(flags, flags == [.function] ? 117 : 51)))
                XCTAssertFalse(state.showDeleteConfirmation)
            }
            window.makeFirstResponder(nil); field.removeFromSuperview()
        }
        let editor = NSTextView(); root.addSubview(editor); window.makeFirstResponder(editor)
        XCTAssertFalse(state.handleGlobalKeyEvent(try key()))
        window.makeFirstResponder(nil); editor.removeFromSuperview()
        for flags: NSEvent.ModifierFlags in [[.shift], [.option], [.control]] {
            XCTAssertFalse(state.handleGlobalKeyEvent(try key(flags)))
        }
        state.showSyncDialog = true
        XCTAssertFalse(state.handleGlobalKeyEvent(try key()))
        state.showSyncDialog = false
        XCTAssertTrue(state.handleGlobalKeyEvent(try key()))
        XCTAssertTrue(state.showDeleteConfirmation)
        XCTAssertFalse(state.handleGlobalKeyEvent(try key([], 36)))
        state.cancelDelete()
        XCTAssertTrue(state.handleGlobalKeyEvent(try key([.command])))
        XCTAssertTrue(state.showDeleteConfirmation)
        state.cancelDelete()
    }

    @MainActor func testPlainBackspaceRequestsSameConfirmationWithoutDeletingFixture() throws {
        let state = AppState(preloader: PreviewPreloader(observeMemoryPressure: false))
        let root = inspectionTestScratchURL("backspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.tiff")
        try Data([1, 2, 3]).write(to: file)
        let asset = PhotoAsset(fileURL: file)
        state.allAssets = [asset]
        state.selectAsset(asset)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        XCTAssertTrue(state.handleGlobalKeyEvent(event))
        XCTAssertTrue(state.showDeleteConfirmation)
        XCTAssertEqual(state.pendingDeleteAssets.map(\.id), [asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        state.cancelDelete()
        XCTAssertFalse(state.showDeleteConfirmation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
