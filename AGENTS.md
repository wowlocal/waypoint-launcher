# Waypoint: notes for agents

## TODO

- [x] **Remove SwiftUI.** The app's UI (`Sources/Waypoint`) is AppKit now; no
  file imports SwiftUI. See the rule below for why.

## Never use SwiftUI

Build UI with AppKit only: `NSWindow`, `NSView`, `NSTableView`, `NSMenu`,
`NSStatusItem`. Do not add SwiftUI views, scenes, `NSHostingView` or
`import SwiftUI` anywhere. SwiftUI performs badly and uses a lot of memory
for what Waypoint shows.

Measured on macOS 27 (Apple silicon) with `footprint`, which reports the same
number as Activity Monitor's Memory column:

| One window with one label | Memory |
|---|---|
| AppKit, Objective-C | 16 MB |
| AppKit, Swift | 17 MB |
| SwiftUI | 20 MB |

The gap grows with every view. In the SwiftUI library window, SwiftUI's own
view-graph bookkeeping was ~4.3 MB of live heap. Waypoint's own objects (the
games, the model, Sparkle's controller) were ~50 KB.

`@Observable` models (`AppModel`, `AppUpdater`) are fine: Observation is its
own framework, not SwiftUI. Views follow them with `observeChanges`
(`Observe.swift`), which re-runs a render function whenever anything it read
changes.

SwiftUI.framework still shows up among the loaded libraries. That's Apple's
WebKit, which links it on macOS 27; Waypoint uses WebKit for the Battle.net
sign-in. No Waypoint code calls SwiftUI.

To check memory yourself:

- `footprint <pid>`: total and per-category breakdown.
- `heap <pid> -s`: live objects by class.
- Launch with `MallocStackLogging=lite`, then `malloc_history <pid> -callTree`
  to see which code made each allocation. Logging inflates the footprint, so
  take totals from an uninstrumented run.

## The menu bar item is opt-in

Lots of apps add a menu bar item by default, even ones as basic as Waypoint,
and people's menu bars are crowded with them. Waypoint must not do that. By
default it creates no status item at all, not even a hidden one: no
`NSStatusItem`, no SwiftUI `MenuBarExtra`. `MenuBarItem.swift` creates it only
after the user turns on Waypoint ▸ Show in Menu Bar (the `showsMenuBarItem`
default), and removes it again when they turn it off. Keep it that way.
