import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `WaypointApp`, which is where SwiftUI hands it out.
    var openWindow: OpenWindowAction?

    /// Reopening Waypoint (Dock click, Spotlight, Raycast, `open`) after its
    /// window was closed brings the library back. SwiftUI won't do it on its
    /// own: the menu bar extra keeps the app running with the window hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openWindow?(id: "main") }
        return true
    }
}
