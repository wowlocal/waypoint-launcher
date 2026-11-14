import AppKit

/// AppKit propagates this choice to existing and newly opened native windows.
/// System deliberately clears the override so macOS can keep changing it.
@MainActor
enum AppAppearance {
    static let defaultsKey = "applicationAppearance"
    enum Mode: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
        }
    }
    static var selected: Mode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Mode.init(rawValue:)) ?? .system
    }
    static func select(_ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
        apply()
    }
    static func apply() {
        switch selected {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
