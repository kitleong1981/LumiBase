import SwiftUI

@MainActor final class PerformanceSettings: ObservableObject {
    static let shared = PerformanceSettings()
    private let defaults: UserDefaults
    private let cache: LibraryJPEGROICache
    @Published var sharpnessEnabled: Bool {
        didSet { defaults.set(sharpnessEnabled, forKey: "previewSharpnessEnabled") }
    }
    @Published var roiRadius: Int {
        didSet {
            let value = min(2, max(0, roiRadius))
            if roiRadius != value { roiRadius = value }
            defaults.set(value, forKey: "libraryJPEGROIRadius")
            apply()
        }
    }
    @Published var cacheBudgetMiB: Int {
        didSet {
            let value = [64, 128, 256].contains(cacheBudgetMiB) ? cacheBudgetMiB : 64
            if cacheBudgetMiB != value { cacheBudgetMiB = value }
            defaults.set(value, forKey: "libraryJPEGROIBudgetMiB")
            apply()
        }
    }
    init(defaults: UserDefaults = .standard, cache: LibraryJPEGROICache = .shared) {
        self.defaults = defaults
        self.cache = cache
        sharpnessEnabled = defaults.bool(forKey: "previewSharpnessEnabled")
        roiRadius = min(2, max(0, defaults.integer(forKey: "libraryJPEGROIRadius")))
        let saved = defaults.integer(forKey: "libraryJPEGROIBudgetMiB")
        cacheBudgetMiB = [64, 128, 256].contains(saved) ? saved : 64
        apply()
    }
    private func apply() {
        cache.configure(budget: cacheBudgetMiB * 1024 * 1024, maxEntries: roiRadius * 2)
    }
    func clearCache() { cache.cancel(clear: true) }
}

struct PerformanceSettingsView: View {
    @ObservedObject var settings: PerformanceSettings
    @State private var expanded = true
    var body: some View {
        Form {
            DisclosureGroup("Performance / Cache", isExpanded: $expanded) {
                Text("Library JPEG ROI — Experimental").font(.headline)
                Picker("Neighbor preload", selection: $settings.roiRadius) {
                    Text("OFF (default)").tag(0)
                    Text("Previous / next 1").tag(1)
                    Text("Previous / next 2").tag(2)
                }.accessibilityIdentifier("libraryROIRadius")
                Picker("ROI cache budget", selection: $settings.cacheBudgetMiB) {
                    ForEach([64, 128, 256], id: \.self) { Text("\($0) MiB").tag($0) }
                }.accessibilityIdentifier("libraryROIBudget")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("\(LibraryJPEGROICache.shared.entryCount) entries · \(LibraryJPEGROICache.shared.bytes / 1024 / 1024) MiB cached")
                }
                Button("Clear ROI cache") { settings.clearCache() }
                    .accessibilityIdentifier("clearLibraryROICache")
                Text("Only Library JPEG inspection at 100%. No Grid/Fit or Develop RAW neighbor decoding. Choices are remembered. The byte budget includes ROI pixels and reduced fallbacks, not app + helper RSS. Full JPEG decoding has a transient memory peak; warm native hits may be faster. One utility helper at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sharpness / Preview — Experimental") {
                Toggle("Show preview sharpness score (default OFF)", isOn: $settings.sharpnessEnabled)
                    .accessibilityIdentifier("previewSharpnessEnabled")
                Text("Relative preview metric only: fixed 1024px Laplacian, sharpest 10% of 64px blocks. Uses the selected displayed full-frame preview, never extra RAW decoding or a folder scan. Compare the same view / preview quality. Noise and sharpening bias scores; not focus confidence, no automatic reject, no full-resolution thresholds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width: 560, height: 520)
            .background(SettingsEscapeSurface())
    }
}

/// Window-scoped Escape handling; preserve native editor and tracking-menu cancellation.
private struct SettingsEscapeSurface: NSViewRepresentable {
    final class Surface: NSView {
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var trackingMenus = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.trackingMenus = max(0, self.trackingMenus + (name == NSMenu.didBeginTrackingNotification ? 1 : -1))
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window === window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      window.attachedSheet == nil, self.trackingMenus == 0 else { return event }
                if window.firstResponder is NSTextView || window.firstResponder is NSTextField { return event }
                window.performClose(nil)
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll(); trackingMenus = 0
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.removeMonitor() }
}
