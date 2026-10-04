import AppKit
import Observation
import Sparkle
import WaypointCore

/// Keeps Waypoint itself up to date with Sparkle, quietly: updates are found
/// and downloaded in the background and installed when Waypoint quits.
/// Sparkle's own windows never appear; progress shows inline in the window
/// footer and the menu bar menu instead.
///
/// Only release builds carry a feed URL (see scripts/bundle.sh), so
/// development builds never replace themselves.
@MainActor
@Observable
final class AppUpdater: NSObject {
    /// One line for the window footer; nil when there's nothing to say.
    private(set) var status: String?
    private(set) var isBusy = false
    /// A downloaded update waiting for Waypoint to restart.
    private(set) var readyVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    var isEnabled: Bool { controller != nil }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            Log.info(.selfUpdate, "disabled", "no feed in this build")
            return
        }
        Log.info(.selfUpdate, "enabled", nil, ["feed": feed])
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.automaticallyDownloadsUpdates = true
        self.controller = controller
        controller.updater.checkForUpdatesInBackground()
    }

    /// "Check for Updates": still a background check, so the answer shows
    /// inline rather than in a Sparkle window.
    func checkNow() {
        guard let controller else { return }
        if let readyVersion {
            show("Waypoint \(readyVersion) is ready. Restart to update.")
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        userInitiated = true
        Log.info(.selfUpdate, "check_requested")
        show("Checking for Waypoint updates…", busy: true)
        controller.updater.checkForUpdatesInBackground()
    }

    /// Installs the downloaded update now; Sparkle quits and relaunches Waypoint.
    /// Games keep running, they don't depend on Waypoint.
    func restartToUpdate() {
        guard let installNow else { return }
        Log.notice(.selfUpdate, "restart_to_update", nil, ["version": readyVersion ?? "?"])
        show("Installing update…", busy: true)
        installNow()
    }

    private func show(_ text: String?, busy: Bool = false, clearAfter seconds: Double? = nil) {
        clearTask?.cancel()
        status = text
        isBusy = busy
        guard let seconds else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.status = nil
            self?.isBusy = false
        }
    }

    private nonisolated static func version(of item: SUAppcastItem) -> String {
        item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
    }
}

// Sparkle calls its delegate on the main thread.
extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = Self.version(of: item)
        Log.notice(.selfUpdate, "found", nil, ["version": version, "build": item.versionString])
        MainActor.assumeIsolated { show("Downloading Waypoint \(version)…", busy: true) }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        let message = error.localizedDescription
        Log.error(.selfUpdate, "download_failed", nil, ["version": item.displayVersionString, "error": message])
        MainActor.assumeIsolated { show("Update download failed: \(message)", clearAfter: 8) }
    }

    /// The update is downloaded and will install when Waypoint quits. Keep the
    /// handler so the user can apply it right away, and tell Sparkle we'll
    /// handle the UI (so it shows none).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = Self.version(of: item)
        Log.notice(.selfUpdate, "ready", "installs on quit", ["version": version])
        // Sparkle hands this over on the main thread, where it's also called.
        nonisolated(unsafe) let handler = immediateInstallHandler
        MainActor.assumeIsolated {
            installNow = handler
            readyVersion = version
            show("Waypoint \(version) is ready. It installs when you quit, or restart now.")
        }
        return true
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info(.selfUpdate, "up_to_date")
        MainActor.assumeIsolated {
            if userInitiated { show("Waypoint is up to date.", clearAfter: 4) }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.code != Int(SUError.noUpdateError.rawValue) {
            Log.warning(.selfUpdate, "aborted", nil, ["code": error.code, "domain": error.domain, "error": error.localizedDescription])
        }
        MainActor.assumeIsolated {
            switch error.code {
            case Int(SUError.noUpdateError.rawValue):
                if userInitiated { show("Waypoint is up to date.", clearAfter: 4) }
            case Int(SUError.installationCanceledError.rawValue):
                show("Update installation canceled.", clearAfter: 5)
            default:
                // Background checks fail quietly (offline is normal); only
                // report when someone asked or a download was under way.
                if userInitiated || isBusy {
                    show("Update failed: \(error.localizedDescription)", clearAfter: 8)
                }
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated {
            userInitiated = false
            if readyVersion == nil, isBusy, status?.hasPrefix("Checking") == true { show(nil) }
        }
    }
}
