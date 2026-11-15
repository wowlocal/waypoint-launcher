import AppKit
import Observation
import Sparkle
import UserNotifications
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
    @ObservationIgnored var updateAvailable: ((String, String) -> Void)?
    @ObservationIgnored var noUpdateAvailable: (() -> Void)?
    @ObservationIgnored private var readyBuild: String?
    @ObservationIgnored var prepareForRestart: (@MainActor () async -> Bool)?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var isRestarting = false
    /// Whether this copy follows tip builds (Settings ▸ General).
    private(set) var receivesTips = ReleaseChannel.receivesTips()
    /// What this copy is: a release or a tip build.
    let running = ReleaseChannel.running()
    /// Whether this copy updates itself at all (development builds don't).
    var canUpdate: Bool { controller != nil }
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    /// The release downloaded to replace this tip build when Waypoint quits.
    @ObservationIgnored private var stagedReturn: URL?
    @ObservationIgnored private var relaunchAfterReturn = false
    /// Sparkle has an update waiting to install when Waypoint quits.
    @ObservationIgnored private var sparkleStaged = false
    /// A check asked for while Sparkle was busy: runs when its cycle ends.
    @ObservationIgnored private var checkPending = false

    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            Log.info(.selfUpdate, "disabled", "no feed in this build")
            return
        }
        Log.info(.selfUpdate, "enabled", nil, ["feed": feed, "tips": receivesTips])
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.automaticallyDownloadsUpdates = true
        self.controller = controller
        controller.updater.checkForUpdatesInBackground()
        // A tip build whose tips were turned off goes back to the release,
        // quietly: problems are only logged at launch.
        if running == .tip, !receivesTips { returnToRelease(asked: false) }
    }

    /// Settings ▸ General ▸ "Get tip builds". On: check the tip feed now.
    /// Off on a tip build: go back to the latest release, which installs
    /// when Waypoint quits or restarts. Off on a release: nothing changes.
    func setReceivesTips(_ on: Bool) {
        guard on != receivesTips else { return }
        receivesTips = on
        ReleaseChannel.setReceivesTips(on, running: running)
        Log.notice(.selfUpdate, "channel_changed", nil, ["tips": on, "running": running.rawValue])
        returnTask?.cancel()
        returnTask = nil
        discardReturn()
        guard controller != nil else { return }
        if on {
            checkNow()
        } else if running == .tip {
            returnToRelease(asked: true)
        } else if sparkleStaged, ReleaseChannel.isTipBuild(readyBuild ?? "") {
            // That tip must go back once it runs: say so in the defaults.
            ReleaseChannel.remember(false)
            show("A tip build is already downloaded. It installs when you quit; Waypoint then goes back to releases.", clearAfter: 10)
        }
    }

    /// Throws away a downloaded release that isn't wanted any more.
    private func discardReturn() {
        guard let staged = stagedReturn else { return }
        stagedReturn = nil
        relaunchAfterReturn = false
        if !sparkleStaged {
            readyVersion = nil
            readyBuild = nil
            installNow = nil
            show(nil)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["waypoint"])
        }
        let folder = staged.deletingLastPathComponent()
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    /// Downloads the latest release and readies it to replace this tip
    /// build when Waypoint quits. When the release is newer than this tip,
    /// Sparkle takes care of it as a normal update instead. `asked`: the
    /// person just turned tips off, so say what goes wrong.
    private func returnToRelease(asked: Bool) {
        guard returnTask == nil, stagedReturn == nil else { return }
        if sparkleStaged {
            // Sparkle's update installs first; the next launch goes back.
            if asked { show("Waypoint goes back to releases after the waiting update installs.", clearAfter: 8) }
            return
        }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let bundle = Bundle.main.bundleURL
        if asked { show("Downloading the latest release…", busy: true) }
        returnTask = Task { [weak self] in
            do {
                let release = try await ReleaseReturn.latest(feed: URL(string: ReleaseChannel.stableFeed)!)
                try Task.checkCancellation()
                if release.build.compare(current, options: .numeric) == .orderedDescending {
                    // Newer than this tip: Sparkle's own update on the release
                    // feed (at launch, its own check already covers it).
                    self?.returnTask = nil
                    if asked { self?.checkNow() }
                    return
                }
                let team = await Task.detached { ReleaseReturn.runningTeam() }.value
                guard let team else { throw ReleaseReturn.Failure.notInstallable }
                let staged = try await ReleaseReturn.prepare(release, publicKey: publicKey, team: team, replacing: bundle)
                guard let self, !Task.isCancelled, !self.sparkleStaged else {
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                    return
                }
                self.stagedReturn = staged
                self.readyVersion = release.version
                self.readyBuild = release.build
                // Restart: quit, and the swap opens the release.
                self.installNow = { [weak self] in
                    self?.relaunchAfterReturn = true
                    NSApp.terminate(nil)
                }
                self.show("Waypoint \(release.version) is ready. It installs when you quit, or restart now.")
                self.updateAvailable?(release.version, release.build)
            } catch {
                if !(error is CancellationError) {
                    Log.error(.selfUpdate, "release_return_failed", nil, ["error": error])
                    if asked { self?.show(errorMessage(error), clearAfter: 10) }
                }
            }
            self?.returnTask = nil
        }
    }

    /// From `applicationWillTerminate`: a downloaded release replaces this
    /// tip build once Waypoint is gone, unless Sparkle installs instead.
    func willTerminate() {
        guard let staged = stagedReturn, !sparkleStaged else { return }
        do {
            try ReleaseReturn.swapAfterQuit(staged: staged, target: Bundle.main.bundleURL, relaunch: relaunchAfterReturn)
        } catch {
            Log.error(.selfUpdate, "release_return_failed", nil, ["error": error])
        }
    }

    func announceAvailableUpdate() {
        if let readyVersion { updateAvailable?(readyVersion, readyBuild ?? readyVersion) }
    }

    /// "Check for Updates": still a background check, so the answer shows
    /// inline rather than in a Sparkle window.
    func checkNow() {
        guard let controller else { return }
        if let readyVersion {
            show("Waypoint \(readyVersion) is ready. Restart to update.")
            return
        }
        guard controller.updater.canCheckForUpdates else {
            // Sparkle is mid-cycle: run this check when it ends.
            checkPending = true
            return
        }
        userInitiated = true
        Log.info(.selfUpdate, "check_requested")
        show("Checking for Waypoint updates…", busy: true)
        controller.updater.checkForUpdatesInBackground()
    }

    /// Installs the downloaded update now; Sparkle quits and relaunches Waypoint.
    /// Games keep running, they don't depend on Waypoint.
    func restartToUpdate() {
        guard installNow != nil, !isRestarting else { return }
        isRestarting = true
        Log.notice(.selfUpdate, "restart_to_update", nil, ["version": readyVersion ?? "?"])
        show("Installing update…", busy: true)
        Task {
            guard await prepareForRestart?() ?? true else {
                isRestarting = false
                show("Could not save downloads. Try restarting again.")
                return
            }
            // Read again: Sparkle may have staged its own update meanwhile.
            guard let installNow else { isRestarting = false; show(nil); return }
            installNow()
            // Still here: quitting was called off. A later plain quit
            // installs without relaunching.
            isRestarting = false
            relaunchAfterReturn = false
            if let readyVersion { show("Waypoint \(readyVersion) is ready. It installs when you quit, or restart now.") }
        }
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
    /// The tip feed while tips are on, else the release feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ReleaseChannel.feed(receivesTips: ReleaseChannel.receivesTips())
    }

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
            // Sparkle's update wins over going back ourselves: it installs
            // when Waypoint quits, and the swap would race it.
            sparkleStaged = true
            returnTask?.cancel()
            returnTask = nil
            discardReturn()
            let isTip = ReleaseChannel.isTipBuild(item.versionString)
            if running == .tip, receivesTips, !isTip {
                // A release from the tip feed: it must stay on tips.
                ReleaseChannel.remember(true)
            } else if isTip, !receivesTips {
                // Downloaded before tips were turned off: it goes back once it runs.
                ReleaseChannel.remember(false)
            }
            installNow = handler
            readyVersion = version
            readyBuild = item.versionString
            show("Waypoint \(version) is ready. It installs when you quit, or restart now.")
            updateAvailable?(version, item.versionString)
        }
        return true
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.info(.selfUpdate, "up_to_date")
        MainActor.assumeIsolated {
            noUpdateAvailable?()
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
            if checkPending {
                checkPending = false
                DispatchQueue.main.async { [weak self] in self?.checkNow() }
            }
        }
    }

    /// While tips are off, never a tip build, whatever Sparkle finds.
    nonisolated func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                             updateCheck: SPUUpdateCheck) throws {
        if ReleaseChannel.isTipBuild(item.versionString), !ReleaseChannel.receivesTips() {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "Tip builds are turned off."])
        }
    }
}
