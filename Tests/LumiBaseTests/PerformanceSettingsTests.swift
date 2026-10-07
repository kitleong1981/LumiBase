import XCTest
import SwiftUI
import AppKit
@testable import LumiBase

final class PerformanceSettingsTests: XCTestCase {
    @MainActor func testHostedSettingsReadUpdateAndClear() async throws {
        let name = "LumiBase.HostSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PerformanceSettings(defaults: defaults, cache: LibraryJPEGROICache())
        let host = NSHostingView(rootView: PerformanceSettingsView(settings: settings))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        func assertValues(_ radius: String, _ budget: String) async throws {
            try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
            let values = descendants(host).compactMap { ($0 as? NSPopUpButton)?.title }
            XCTAssertTrue(values.contains(radius), "Actual hosted radius: \(values)")
            XCTAssertTrue(values.contains(budget), "Actual hosted budget: \(values)")
        }
        try await assertValues("OFF (default)", "64 MiB")
        settings.roiRadius = 1
        try await assertValues("Previous / next 1", "64 MiB")
        settings.roiRadius = 2; settings.cacheBudgetMiB = 128
        try await assertValues("Previous / next 2", "128 MiB")
        settings.cacheBudgetMiB = 256
        try await assertValues("Previous / next 2", "256 MiB")
        settings.roiRadius = 0
        try await assertValues("OFF (default)", "256 MiB")
        settings.clearCache()
        XCTAssertEqual(PerformanceSettings(defaults: defaults, cache: LibraryJPEGROICache()).cacheBudgetMiB, 256)
    }

    @MainActor func testDefaultsPersistAndClamp() {
        let name = "LumiBase.SettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PerformanceSettings(defaults: defaults, cache: LibraryJPEGROICache())
        XCTAssertEqual(settings.roiRadius, 0)
        XCTAssertEqual(settings.cacheBudgetMiB, 64)
        settings.roiRadius = 2
        settings.cacheBudgetMiB = 128
        let restored = PerformanceSettings(defaults: defaults, cache: LibraryJPEGROICache())
        XCTAssertEqual(restored.roiRadius, 2)
        XCTAssertEqual(restored.cacheBudgetMiB, 128)
        restored.roiRadius = 99
        restored.cacheBudgetMiB = -1
        XCTAssertEqual(restored.roiRadius, 2)
        XCTAssertEqual(restored.cacheBudgetMiB, 64)
    }
}
