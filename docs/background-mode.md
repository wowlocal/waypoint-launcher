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

## Automatic game updates

Each game opts in separately with **Update Automatically** in its **…** menu.
All games start with this off. The choice is independent of update
notifications, the menu bar item and opening at login; with notifications on,
an update Waypoint will download by itself isn't announced while the hours are
open. Outside them it's announced as usual.

**Settings → Downloads** offers optional hours, in local time. They can cross
midnight; equal start and end times mean all day. A boundary timer pauses
automatic downloads at the end and resumes them in the next allowed hours; the
row says when (“Resumes at 2:00 AM”), and a waiting update says when it
downloads. Wake, clock and time-zone changes re-evaluate the hours. Waypoint
must be running and the Mac awake; this does not wake a sleeping Mac.

Automatic updates run one at a time in library order, after active downloads
finish. Dragging games in the library changes this priority. Running the
scheduler is cheap: it rescans the drives and asks for the current build only
when the last known results say an update could start now. A game whose last
version check failed waits for a successful one (its Update button stays).
Running games, shared WoW folders in use, disconnected drives, Battle.net and
its Agent prevent automatic work. An already-started final commit may finish
after a pause request.

Only scheduler-owned updates resume automatically, including after a restart;
older unfinished downloads stay manual. A person's Pause or Resume ends
scheduler ownership and is remembered in the checkpoint: no other automatic
update starts until that download finishes, fails or is canceled. Canceling a
scheduler-owned download, or one the person took over, skips that build; a later build still updates
automatically. Canceling a manual download, Play and uninstalling never skip a
build. Failed automatic updates wait for manual retry. Turning a game's
automatic updates off turns its download into an ordinary one and ends any
hold. Uninstalling or removing a game turns its automatic updates off.
Downloads already completed by another launcher lose their obsolete
checkpoint; game files and staged data are retained.

**File → Update All Games** runs available updates sequentially in library
order without changing per-game preferences or applying the hours. It skips
unavailable or busy games and unfinished downloads, and stops the batch on
pause or failure.

Not covered by automated tests: a real login launch after logout or reboot.
