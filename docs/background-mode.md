# Optional background mode

The menu bar remains opt-in. A normal icon click toggles the library window;
right-click or Control-click opens the quick-action menu. Closing the library
(including its red close button) keeps Waypoint and downloads running. Quit
Waypoint exits as before. Minimized or hidden windows are restored on a click.

Hide Dock Icon opts into the status item. Disabling or removing the status item
restores the Dock icon so Waypoint remains reachable. Start at Login uses
SMAppService.mainApp and reflects the system approval state. A login or menu-only
start does not open the library automatically.

While running, game checks refresh the existing off-main installation scan and
check version metadata every 30 minutes and after wake, with the existing
15-minute throttle. Manual/post-download checks remain available and concurrent
forced requests receive a fresh follow-up pass. No game files or account
credentials are changed by polling. Disconnected-drive listing is preserved.

Update notifications require explicit opt-in and macOS approval. Alerts are
remembered per game build after successful scheduling. Clicking an alert opens
the library. Send Test Notification distinguishes scheduling acceptance from
confirmed Notification Center delivery; Focus or screen sharing can hide banners.
Existing Sparkle checks and installation behavior are unchanged; feed-enabled
builds can also announce an update once it is ready.

Unbundled development launches disable notification and login-item controls.
No first-launch prompts or new dependencies are added. Actual startup after a
logout/reboot is not exercised by automated tests.
