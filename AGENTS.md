# Waypoint: notes for agents

## TODO

- [ ] **Remove SwiftUI.** Rewrite the app's UI (`Sources/Waypoint`) in AppKit
  and drop `import SwiftUI` everywhere. See the rule below for why.

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

The current UI predates this rule and is still SwiftUI, until the TODO above
is done. Until then, keep SwiftUI edits to the minimum a fix needs, and write
new UI in AppKit.

To check memory yourself:

- `footprint <pid>`: total and per-category breakdown.
- `heap <pid> -s`: live objects by class.
- Launch with `MallocStackLogging=lite`, then `malloc_history <pid> -callTree`
  to see which code made each allocation. Logging inflates the footprint, so
  take totals from an uninstrumented run.

## The menu bar item is opt-in

Waypoint must not add a menu bar item by default: most people's menu bars are
crowded already. Today it is off until the user turns on Waypoint ▸ Show in
Menu Bar (the `showsMenuBarItem` default). Keep it that way.
