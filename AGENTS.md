# Waypoint: notes for agents

## Principles

Waypoint does one job: get people into their games. Every change must keep it
clean, simple, fast, minimal and intuitive. When a change works but makes the
app heavier or the common path longer, it isn't done.

- **The golden path stays short.** Sign in once, install, Play. Nothing may add
  a step, prompt or choice to it. Optional features live off to the side (the
  game's ••• menu, Settings) and fall back silently to the golden path when
  they fail or don't apply.
- **Defaults over settings.** Ship the default that is right for most people.
  Add a setting only when no default can work for a real group of users. When
  there is only one option, choose it; when the user has chosen before,
  remember it instead of asking again.
- **Don't interrupt.** No prompts on launch, onboarding or Play. When something
  needs the user, use a sheet on the window it came from with one clear
  action, not an app-modal alert or a free-floating window.
- **Show less.** Show information only when it helps a decision, for example a
  WoW account name only when there is more than one. No jargon in the UI: say
  "Windows", not "D3DMetal/Wine"; put details in a tooltip if anywhere.
- **No surprises with people's games.** Never re-download what is already on
  disk, never touch files the user didn't ask to change, and keep a game on a
  disconnected drive visible as disconnected rather than offering it again.
- **Fast and light.** AppKit only (see below). No disk or network I/O on the
  main thread. Check memory with `footprint` before adding views or
  dependencies.
- **One of each thing.** Reuse the existing implementation (protocol code,
  stores, sheets) instead of adding a parallel one.
- **Native and consistent.** Follow the macOS Human Interface Guidelines: Title
  Case for menu items and buttons, an ellipsis when a command asks for more
  input, standard controls, American spelling.

## Review changes

Reviews check each change against the principles above, as well as for bugs.

Before committing code changes, run an independent sub-agent review and address
its findings. Include installation/update migrations and real client behavior
in the review when a change affects downloaded content or Battle.net metadata.

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
after the user turns on "Show Waypoint in the menu bar" in Settings ▸
Background (the `showsMenuBarItem` default), and removes it again when they
turn it off. Keep it that way.

## Add-ons

`Sources/WaypointCore/AddOns` manages WoW add-ons; the ••• menu's
"Add-Ons…" opens the sheet. Keep these rules:

- **Only sources any app may download from:** GitHub releases with the
  BigWigs packager's `release.json` (through GitHub's web links, not its
  API), Tukui and WoWInterface. CurseForge's API needs a private key its
  terms forbid shipping in an open-source app; Wago needs a paid key. Their
  add-ons are listed as "Not Updated by Waypoint".
- **GitHub repositories come only from `AddOnIndex`,** hand-checked to be the
  author's own (`tools/addon-index/check.py` reads their folders and IDs).
  No fuzzy matching, no third-party catalogue: a fork must never take over
  an add-on's updates.
- **Never touch `WTF`,** and change only folders an add-on owns. A replaced
  copy Waypoint didn't install, or one someone changed, goes to the Trash.
- **Automatic updates after one say-so per game:** the first Update, Update
  All or Install in a game's sheet. Then every add-on Waypoint recognizes by
  an ID in its TOC (or installed itself) updates on its own: with the game's
  update, the background check, and when the game quits. One recognized by
  folder name alone waits for its own first update. Never while the game is
  open or starting, never on Play, never an add-on someone edited, never to
  a lower version or a release for another patch line.
- **The sheet says only what's known:** `AddOnListing` decides every line
  and is tested; change it there, not in the view.
