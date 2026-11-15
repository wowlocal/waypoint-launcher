# Background mode

Everything here is opt-in, in Settings ▸ Background. Without it, Waypoint
behaves as before: a Dock icon, the library window on launch, no status item
and no notifications.

- **Menu bar.** "Show Waypoint in the menu bar" adds the status item. A click
  opens its menu: Open Waypoint, Settings…, Play/Update/Pause per game, and
  Quit. "Hide Dock icon" is available only while the status item is on. If
  the status item goes away (unchecked, or ⌘-dragged out of the menu bar), the
  Dock icon comes back, so Waypoint is never unreachable.
- **Login.** "Open Waypoint at login" registers `SMAppService.mainApp`. A login
  launch starts without the library window (detected with
  `keyAELaunchedAsLogInItem`, best effort: if macOS doesn't mark it, the window
  opens). Opening Waypoint by hand always shows the window. When macOS wants
  approval, Settings says so and offers Login Items Settings….
- **Notifications.** "Notify me about updates" asks macOS for permission.
  Each new build of a game, and a downloaded Waypoint update, is announced
  once (`UpdateAlertLedger`), silently; while Waypoint is in front it goes
  straight to Notification Center without a banner. Clicking one opens the
  library. Only people who turn this on connect to Notification Center.

Waypoint checks installed games for updates at launch, when it comes back to
the front, every 30 minutes and after wake (throttled to every 15 minutes
unless forced). The 30-minute and wake checks use the installs as last read,
so external drives aren't woken. With notifications on, a build not seen
before has the installs read again and checked once more before it is
announced. A forced check that arrives while another runs becomes that check's
follow-up pass, and keeps its wish to announce.

Closing the library window keeps Waypoint, its downloads and these checks
running; Quit ends them.

Not covered by automated tests: a real login launch after logout or reboot.
