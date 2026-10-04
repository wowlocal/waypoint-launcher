import AppKit
import WaypointCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let model = AppModel()
    let appUpdater = AppUpdater()
    private var libraryWindow: NSWindow?
    private var menuBarItem: MenuBarItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Also makes `swift run` builds, which have no bundle, a regular app.
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(for: self)
        menuBarItem = MenuBarItem(model: model, appUpdater: appUpdater)
        showLibrary(nil)
    }

    /// Closing the window doesn't quit (AppKit's default): game downloads and
    /// Sparkle's install-on-quit keep going. Reopening Waypoint (Dock click,
    /// Spotlight, Raycast, `open`) brings the library back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showLibrary(nil) }
        return true
    }

    // MARK: Library window

    @objc func showLibrary(_ sender: Any?) {
        let window = libraryWindow ?? makeLibraryWindow()
        libraryWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeLibraryWindow() -> NSWindow {
        let window = NSWindow(contentViewController: LibraryViewController(model: model, appUpdater: appUpdater))
        window.title = "Waypoint"
        window.contentMinSize = NSSize(width: 420, height: 260)
        window.setContentSize(NSSize(width: 460, height: 380))
        window.isReleasedWhenClosed = false
        // Window ▸ Waypoint reopens it; no second entry for the open window.
        window.isExcludedFromWindowsMenu = true
        window.delegate = self
        if !window.setFrameUsingName("Library") { window.center() }
        window.setFrameAutosaveName("Library")
        return window
    }

    /// A closed library is let go, views and all; reopening builds a new one.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === libraryWindow { libraryWindow = nil }
    }

    // MARK: Commands

    /// One command for everything: games (Blizzard's version service) and
    /// Waypoint itself (Sparkle, in the background).
    @objc func checkForUpdates(_ sender: Any?) {
        appUpdater.checkNow()
        Task { await model.checkForUpdates(force: true) }
    }

    @objc func restartToUpdate(_ sender: Any?) {
        appUpdater.restartToUpdate()
    }

    @objc func toggleMenuBarItem(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: MenuBarItem.defaultsKey), forKey: MenuBarItem.defaultsKey)
    }

    @objc func signOut(_ sender: Any?) {
        Task { await model.signOut() }
    }

    /// Saves a diagnostics snapshot plus the last week of logs as one JSONL
    /// file, for bug reports.
    @objc func exportDiagnostics(_ sender: Any?) {
        let panel = NSSavePanel()
        let stamp = Diagnostics.timestampString(Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Waypoint-Diagnostics-\(stamp).jsonl"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsReport.export(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Log.error(.app, "diagnostics_export_failed", nil, ["error": error])
            NSAlert(error: error).runModal()
        }
    }

    @objc func showLogs(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.directory])
    }

    /// The app menu: shows whichever update command applies as it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let ready = appUpdater.readyVersion
        for item in menu.items {
            switch item.action {
            case #selector(checkForUpdates(_:)):
                item.isHidden = ready != nil || !appUpdater.isEnabled
            case #selector(restartToUpdate(_:)):
                item.isHidden = ready == nil
                item.title = "Restart to Update Waypoint \(ready ?? "")"
            case #selector(toggleMenuBarItem(_:)):
                item.state = UserDefaults.standard.bool(forKey: MenuBarItem.defaultsKey) ? .on : .off
            default:
                break
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? appUpdater.canCheck : true
    }
}
