import SwiftUI

@MainActor final class PerformanceSettings: ObservableObject {
    static let shared = PerformanceSettings()
    private let defaults: UserDefaults
    private let cache: LibraryJPEGROICache
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
        }.formStyle(.grouped).padding().frame(width: 520, height: 360)
    }
}
