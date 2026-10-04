import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let appUpdater = AppUpdater()
    /// Set by `WaypointApp`, which is where SwiftUI hands it out.
    var openWindow: OpenWindowAction?
    private var menuBarItem: MenuBarItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarItem = MenuBarItem(model: model, appUpdater: appUpdater)
    }

    /// Closing the window doesn't quit: game downloads and Sparkle's
    /// install-on-quit keep going. SwiftUI quits a single-`Window` app when
    /// that window closes unless the delegate says otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopening Waypoint (Dock click, Spotlight, Raycast, `open`) after its
    /// window was closed brings the library back. SwiftUI won't do it on its
    /// own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openWindow?(id: "main") }
        return true
    }
}
