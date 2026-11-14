import AppKit
import Observation
import CryptoKit
import WaypointCore

/// What a look at the library reads from outside Waypoint: the installed
/// games (records and folders on disk) and the running processes. Reading
/// takes several milliseconds, and may be done off the main thread.
private struct LibraryScan: Sendable {
    var games: [Game]
    var processes: [(pid: pid_t, path: String)]

    init(_ library: GameLibrary) {
        games = library.games()
        processes = RunningProcesses.executables()
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case signingIn
        case preparingWindows(UpdateProgress?)
        case launching
        case updating(UpdateProgress?)
        case pausing(UpdateProgress?)
        case paused(UpdateProgress?)
        /// Moving to the Trash, then freeing shared storage: what it's doing.
        case uninstalling(String)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.signingIn, .signingIn), (.launching, .launching),
                 (.updating, .updating), (.pausing, .pausing), (.paused, .paused): true
            case (.preparingWindows(let x), .preparingWindows(let y)): x == y
            case (.uninstalling(let x), .uninstalling(let y)): x == y
            case (.failed(let x), .failed(let y)): x == y
            default: false
            }
        }
    }

    private(set) var games: [Game] = []
    private var catalogRevision = 0
    /// Whether rows show the games' pictures and icons from Blizzard's
    /// catalog (Settings). Off: none is shown or downloaded, and those
    /// downloaded are deleted.
    var showsArtwork = UserDefaults.standard.object(forKey: "showsArtwork") as? Bool ?? true {
        didSet {
            guard showsArtwork != oldValue else { return }
            UserDefaults.standard.set(showsArtwork, forKey: "showsArtwork")
            artworkFiles = [:]
            missingArtwork = []
            if showsArtwork {
                downloadArtwork(region: regionOverride ?? Region.preferred(games: games))
            } else {
                // After a download in flight has stopped, or a file it was
                // saving would be left behind. A download started meanwhile
                // (the setting turned back on) waits for this.
                let download = artworkDownload, removal = artworkRemoval, cache = artworkCache
                download?.cancel()
                GameBanners.shared.removeAll()
                artworkRemoval = Task.detached(priority: .utility) {
                    await removal?.value
                    await download?.value
                    cache.removeAll()
                }
            }
        }
    }
    /// Goes up when pictures arrive, so the rows showing them render again.
    private var artworkRevision = 0
    @ObservationIgnored private let artworkCache = ArtworkCache()
    @ObservationIgnored private var artworkDownload: Task<Void, Never>?
    /// Deleting the pictures, after the setting was turned off.
    @ObservationIgnored private var artworkRemoval: Task<Void, Never>?
    /// Hash -> its file, for those found here since pictures last arrived:
    /// a row that has its picture doesn't ask the disk again on each render.
    @ObservationIgnored private var artworkFiles: [String: URL] = [:]
    /// Pictures that failed to download: left alone until the next launch,
    /// or until artwork is turned off and on.
    @ObservationIgnored private var missingArtwork: Set<String> = []
    /// A catalog saved by a version that didn't record pictures has none
    /// until it is read again. That is asked for once a launch, rather than
    /// waiting out the hour between readings.
    @ObservationIgnored private var askedForArtwork = false
    private var isRefreshingCatalog = false
    private var lastCatalogAttempt: Date?
    private var lastCatalogRegion: Region?
    private var discoveredGames: [Game] = []
    private var pendingHeroesInstall: ProductInstall? {
        downloads.values.compactMap(\.request).first { $0.install.productCode == "hero" }?.install
    }
    private var heroesPlatform = UserDefaults.standard.string(forKey: "heroesPlatform").flatMap(InstallPlatform.init(rawValue:)) ?? .windows
    @ObservationIgnored private var windowsSessions: [String: WindowsGameSession] = [:]
    @ObservationIgnored private var windowsObservers: [Int32: any DispatchSourceProcess] = [:]
    /// Game uid -> phase, so each row shows its own progress.
    private(set) var phases: [String: Phase] = [:]
    /// Each job owns its task and retains the original install/update options.
    private let downloadQueue = DownloadQueue()
    private var downloads: [String: DownloadJob] { downloadQueue.jobs }
    private(set) var isPreparingToQuit = false
    /// Job uid -> the install folder it writes to.
    private var jobFolders: [String: String] {
        downloads.compactMapValues { $0.request.map { Self.folderKey($0.install.installPath) } }
    }
    /// Install folders a game is being uninstalled from: nothing else may
    /// touch them meanwhile (WoW versions share one).
    private var uninstallingFolders: Set<String> = []
    /// Folders whose shared storage is being cleaned after an uninstall. The
    /// other versions there can play meanwhile (the cleaner then leaves the
    /// storage alone), but nothing may write to it or be uninstalled.
    private var cleaningFolders: Set<String> = []
    private(set) var running: Set<String> = []
    /// Game uid -> result of the last update check.
    private(set) var updates: [String: UpdateCheck] = [:]
    private var lastUpdateCheck: Date?

    /// nil = use the region each game was installed for.
    var regionOverride: Region? {
        didSet {
            UserDefaults.standard.set(regionOverride?.rawValue, forKey: "regionOverride")
            Task { await refreshCatalog() }
        }
    }

    /// Saved Battle.net accounts, each with its own web session and last
    /// tokens, so switching between them needs no sign-in.
    private var accountList = AccountList.load() {
        didSet { accountList.save() }
    }
    var accounts: [Account] { accountList.accounts }
    /// The account games launch with.
    var activeAccount: Account? { accountList.active }
    /// The login window is open to add an account or sign one in again.
    private(set) var isAddingAccount = false
    private(set) var isManagingSavedLogin = false
    private var autoLoginStates = AutoLoginState.load() {
        didSet { AutoLoginState.save(autoLoginStates) }
    }
    private var wowAccountStore = WoWAccountStore.load() {
        didSet { wowAccountStore.save() }
    }
    private var isFindingWoWAccounts = false
    private var profileFetches: Set<String> = []

    /// Where games are found. Its remembered locations (File ▸ Locate
    /// Installed Games) are `locatedStore`'s, as last scanned off the main
    /// thread: the main thread doesn't read their records or mount drives.
    /// Like any other game's, a located game's app is looked up by a scan
    /// on the main thread (`rescan`).
    @ObservationIgnored private var library = GameLibrary()
    @ObservationIgnored private let locatedStore = LocatedGames.Store()
    /// Goes up when a location is remembered or forgotten: a scan of the
    /// locations begun before then is out of date.
    @ObservationIgnored private var locationsRevision = 0
    private(set) var isLocatingGames = false

    /// File ▸ Locate Installed Games: lists games already on disk (on
    /// another drive, say) without moving or downloading anything, and
    /// remembers where they are. Asks in sheets on `window`.
    func locateInstalledGames(in window: NSWindow) async {
        guard !isLocatingGames else { return }
        isLocatingGames = true
        defer { isLocatingGames = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Locate"
        panel.message = "Choose a game’s folder, or a folder of games. Nothing is moved or downloaded."
        guard await panel.beginSheetModal(for: window) == .OK, let selection = panel.url else { return }
        var found = await Task.detached(priority: .userInitiated) { LocatedGames.locate(at: selection) }.value
        guard !found.isEmpty else {
            showAlert("No installed games found", "Choose the game’s folder (for World of Warcraft, the one with the Data folder), or a folder of games.", in: window)
            return
        }
        let imports = found.flatMap(\.installs)
        let keys = Set(imports.map(\.key))
        let folders = Set(imports.map { Self.folderKey($0.installPath) })
        guard !downloads.values.contains(where: { job in
                  guard job.state != .completed, let install = job.request?.install else { return false }
                  return keys.contains(install.key) || folders.contains(Self.folderKey(install.installPath))
              }),
              !keys.contains(where: { isBusy(uid: $0) || running.contains($0) }),
              !games.contains(where: { folders.contains(Self.folderKey($0.install.installPath)) && (isBusy($0) || running.contains($0.id)) }) else {
            showAlert("This game is in use", "Quit the game, and finish or cancel its download, then try again.", in: window)
            return
        }
        // Another copy already in the library stays the one listed.
        var kept: [Game] = []
        for index in found.indices {
            for install in found[index].installs {
                // A copy on disk; one on a drive that isn't connected gives way.
                guard let other = discoveredGames.first(where: { $0.id == install.key }),
                      Self.folderKey(other.install.installPath) != Self.folderKey(install.installPath) else { continue }
                found[index].removedKeys.append(install.key)
                kept.append(other)
            }
        }
        found.removeAll { $0.listedInstalls.isEmpty }
        let listed = Set(games.map(\.id))
        if !found.isEmpty {
            locatedStore.add(found)
            locationsChanged()
        }
        Log.notice(.library, "located", nil, ["games": found.flatMap(\.listedInstalls).map(\.key).joined(separator: ","),
                                              "kept": kept.map(\.id).joined(separator: ",")])
        if !kept.isEmpty {
            let names = ListFormatter.localizedString(byJoining: kept.map(\.displayName))
            let copy = kept.count == 1
                ? "the copy in “\((kept[0].install.installPath as NSString).abbreviatingWithTildeInPath)”" : "the copies it has"
            showAlert("\(names) \(kept.count == 1 ? "is" : "are") already in your library", "Waypoint keeps using \(copy).", in: window)
        } else if Set(games.map(\.id)) == listed {
            // Nothing new to see (Battle.net already knew them): say it worked.
            let keys = Set(found.flatMap(\.listedInstalls).map(\.key))
            let names = discoveredGames.filter { keys.contains($0.id) }.map(\.displayName)
            showAlert(names.isEmpty ? "Your games are in your library"
                      : "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "is" : "are") in your library", nil, in: window)
        }
    }

    func canRemoveFromLibrary(_ game: Game) -> Bool {
        game.locationID != nil && downloads[game.id] == nil && !isBusy(game) && !isRunning(game)
    }

    /// Forgets a game listed from a remembered location (one whose drive
    /// isn't connected, or a folder located by mistake). Its files stay.
    func removeFromLibrary(_ game: Game) {
        guard canRemoveFromLibrary(game), let id = game.locationID else { return }
        Log.notice(.library, "removed_from_library", nil, ["uid": game.id, "offline": game.isOffline])
        locatedStore.remove(key: game.install.key, from: id)
        // Waypoint's own record of it too, should it have updated the game.
        // Battle.net's record, if it has one, is Battle.net's.
        if game.isOffline { try? library.stateStore.remove(game.install) }
        updates.removeValue(forKey: game.id)
        locationsChanged()
    }

    /// The remembered locations changed here: the library takes them as
    /// they are now. Those already scanned keep what the scan found.
    /// Without `rescanning`, the caller reloads next.
    private func locationsChanged(rescanning: Bool = true) {
        locationsRevision += 1
        library.located = LocatedGames.Scan(locations: locatedStore.locations(), disconnected: library.located.disconnected)
        if rescanning { rescan() }
    }

    private func showAlert(_ message: String, _ information: String?, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = message
        if let information { alert.informativeText = information }
        alert.beginSheetModal(for: window)
    }

    private let loginWindow = LoginWindow()
    /// Per bundle id, like the web sessions, so test builds never share
    /// keychain items with the installed app.
    private let tokenVault = TokenVault(service: "\(Bundle.main.bundleIdentifier ?? "Waypoint"): Battle.net login tokens")
    private let credentialVault = CredentialVault(service: "\(Bundle.main.bundleIdentifier ?? "Waypoint"): Battle.net passwords")
    private var observers: [NSObjectProtocol] = []
    /// The repair of Battle.net's records that is running, off the main thread.
    @ObservationIgnored private var metadataRepair: Task<Void, Never>?
    /// Another repair was asked for meanwhile; it runs when this one ends.
    @ObservationIgnored private var repairsMetadataAgain = false
    /// Waits for Battle.net to quit, then repairs.
    @ObservationIgnored private var metadataRepairRetry: Task<Void, Never>?
    /// How many times the games (`show`) and which of them run
    /// (`refreshRunning`) have been set. What a scan read off the main thread
    /// isn't shown if the same was set meanwhile: that came from a read on
    /// the main thread, and there's no telling which of the two is later.
    @ObservationIgnored private var scansShown = 0
    @ObservationIgnored private var runningShown = 0
    @ObservationIgnored private var scanOffMainThread: Task<Void, Never>?
    /// Waypoint was returned to again while a scan was being read; another
    /// follows it.
    @ObservationIgnored private var scansAgain = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        Log.notice(.app, "started", nil, [
            "version": info["CFBundleShortVersionString"] as? String ?? "dev",
            "build": info["CFBundleVersion"] as? String ?? "dev",
            "path": Bundle.main.bundlePath,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Log.notice(.app, "quitting")
            Diagnostics.shared.flush()
        })
        regionOverride = UserDefaults.standard.string(forKey: "regionOverride").flatMap(Region.init(rawValue:))
        // Artwork is off: nothing of it should be left, even if the last
        // run ended before it could delete it.
        if !showsArtwork {
            let cache = artworkCache
            Task.detached(priority: .utility) { cache.removeAll() }
        }
        // Reads the logs only while that one-time import is still to do.
        downloadQueue.recoverLegacyInstalls(events: Diagnostics.shared.events())
        // Until they're scanned (when Waypoint becomes active): which drives
        // are there, from the list of mounted volumes alone.
        library.located = .unscanned(locatedStore.locations())
        reload()
        rememberEarlierInstallLocations()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        // A drive connected or ejected: its remembered games come online or
        // go offline.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scanOffMainThreadOnce()
                    if name == NSWorkspace.didMountNotification { self?.rememberEarlierInstallLocations() }
                }
            })
        }
        // Coming back to Waypoint picks up games installed or removed
        // meanwhile, and checks for updates (throttled).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadOffMainThread()
                _ = Task {
                    // Both go by the games the scan finds.
                    while let scan = self?.scanOffMainThread { await scan.value }
                    await self?.refreshCatalog()
                    await self?.checkForUpdates()
                }
            }
        })
        Task {
            await refreshCatalog()
            await checkForUpdates(force: true)
        }
        Task { await setUpAccounts() }
    }

    /// Fills in Battle.net's records of the games Waypoint installed, off
    /// the main thread: a repair looks through every process several times,
    /// and with World of Warcraft installed walks the game's Data folder.
    /// Run inline, that held up every return to Waypoint. One repair runs at
    /// a time; a request made meanwhile runs when it ends.
    private func repairInstallMetadata() {
        guard metadataRepair == nil else {
            repairsMetadataAgain = true
            return
        }
        let store = library.stateStore, database = library.agentDatabase
        // Detached, and not awaited from here: awaiting would lend it the
        // main thread's priority, and it would compete with the launch.
        metadataRepair = Task.detached(priority: .utility) { [weak self] in
            // nil: Battle.net is running. Otherwise, how much was repaired.
            var repaired: Int? = 0
            if !BattleNet.running().isEmpty {
                repaired = nil
            } else {
                do {
                    repaired = try BattleNetInstallMetadata.repair(store: store, agentDatabase: database)
                } catch UpdateError.battleNetRunning {
                    repaired = nil // It started meanwhile.
                } catch {
                    Log.warning(.install, "battlenet_metadata_repair_failed", nil, ["error": error])
                }
            }
            await self?.metadataRepairEnded(repaired)
        }
    }

    private func metadataRepairEnded(_ repaired: Int?) {
        metadataRepair = nil
        if repairsMetadataAgain {
            repairsMetadataAgain = false
            repairInstallMetadata()
        } else if repaired == nil {
            repairWhenBattleNetQuits()
        } else {
            metadataRepairRetry?.cancel()
            metadataRepairRetry = nil
        }
        // The scan reads the records a repair adds.
        if let repaired, repaired > 0 { rescan() }
    }

    /// An app update can restart Waypoint while Battle.net is open. Wait for
    /// its background Agent too; never race its database writer.
    private func repairWhenBattleNetQuits() {
        guard metadataRepairRetry == nil else { return }
        metadataRepairRetry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard await Task.detached(priority: .utility, operation: { BattleNet.running().isEmpty }).value else { continue }
                guard let self, !Task.isCancelled else { return }
                self.metadataRepairRetry = nil
                self.reload()
                return
            }
        }
    }

    func reload() {
        repairInstallMetadata()
        rescan()
    }

    /// `reload` for coming back to Waypoint, which happens far more often
    /// than anything changes: the disk and the process list are read off the
    /// main thread, so the window comes forward without waiting for them.
    private func reloadOffMainThread() {
        repairInstallMetadata()
        scanOffMainThreadOnce()
    }

    private func scanOffMainThreadOnce() {
        guard scanOffMainThread == nil else {
            scansAgain = true
            return
        }
        let library = library, scans = scansShown, running = runningShown, revision = locationsRevision
        scanOffMainThread = Task.detached(priority: .userInitiated) { [weak self] in
            var library = library
            // The remembered locations are read here only, never on the main thread.
            library.located = LocatedGames.scan(library.located.locations)
            let scan = LibraryScan(library)
            await self?.scannedOffMainThread(scan, located: library.located, revision: revision, afterScans: scans, running: running)
        }
    }

    private func scannedOffMainThread(_ scan: LibraryScan, located: LocatedGames.Scan, revision: Int,
                                      afterScans scans: Int, running: Int) {
        scanOffMainThread = nil
        let locatedChanged = revision == locationsRevision && located != library.located
        // A location was remembered or forgotten meanwhile: what this scan
        // found out about the others (a drive ejected) is read again.
        if revision != locationsRevision { scansAgain = true }
        if locatedChanged {
            library.located = located
            // Where a renamed drive's folder is now, and the games there.
            locatedStore.update(with: located.locations)
        }
        if scans == scansShown {
            show(scan.games, processes: running == runningShown ? scan.processes : nil)
        } else if locatedChanged {
            // What was shown meanwhile went by the locations as they were.
            rescan()
        }
        if scansAgain {
            scansAgain = false
            scanOffMainThreadOnce()
        }
    }

    /// Reads which games are installed and running, and shows that. Cheap
    /// next to the repair of Battle.net's records, which runs beside it (see
    /// `repairInstallMetadata`).
    private func rescan() {
        show(library.games(), processes: nil)
    }

    /// `found`: the games on record, installed or not. `processes`: the
    /// process list read with them, or nil to read it now.
    private func show(_ found: [Game], processes: [(pid: pid_t, path: String)]?) {
        scansShown += 1
        downloadQueue.restoreAvailableJobs()
        // Battle.net's records outlive a game whose files are gone (moved to
        // the Trash, or uninstalled here): only what's on disk is listed.
        discoveredGames = found.filter(\.isInstalled)
        // Except those on a remembered drive that isn't connected: they stay,
        // and aren't offered for download again.
        var all = found.filter(\.isListed)
        if let pendingHeroesInstall {
            all.removeAll { $0.id == pendingHeroesInstall.key }
            all.append(GameCatalog.game(for: pendingHeroesInstall))
        }
        // A game being uninstalled keeps its row until that's done.
        for game in games where !all.contains(where: { $0.id == game.id }) {
            if case .uninstalling = phases[game.id] { all.append(game) }
        }
        let heroes = all.filter { $0.install.uid == "heroes" }
        let preferred = WindowsHeroes.isAvailable ? heroesPlatform : .macOS
        let selected = heroes.first { $0.id == pendingHeroesInstall?.key }
            ?? heroes.first { $0.install.platform == preferred } ?? heroes.first
        var addedHeroes = false
        games = all.filter { game in
            guard game.install.uid == "heroes" else { return true }
            guard !addedHeroes, game.id == selected?.id else { return false }
            addedHeroes = true
            return true
        }
        refreshRunning(processes: processes)
        Log.info(.library, "scanned", nil, ["games": games.map { "\($0.install.uid)@\($0.install.version ?? "?")" }.joined(separator: ","),
                                            "missing": found.filter { !$0.isInstalled && !$0.isOffline }.map(\.id).joined(separator: ","),
                                            "offline": found.filter(\.isOffline).map(\.id).joined(separator: ",")])
    }

    func heroesEdition(_ platform: InstallPlatform) -> Game? {
        discoveredGames.first { $0.install.uid == "heroes" && $0.install.platform == platform }
    }

    func selectHeroesEdition(_ platform: InstallPlatform) {
        heroesPlatform = platform
        UserDefaults.standard.set(platform.rawValue, forKey: "heroesPlatform")
        reload()
    }

    func defaultPlatform(for product: InstallableProduct) -> InstallPlatform {
        if let pending = downloads.values.compactMap(\.request).first(where: { $0.install.uid == product.uid }) {
            return pending.install.platform
        }
        if product.productCode == "hero" {
            return pendingHeroesInstall?.platform ?? (WindowsHeroes.isAvailable ? .windows : .macOS)
        }
        if product.supportedPlatforms == [.windows] { return .windows }
        return .macOS
    }

    /// The platform a not-yet-installed game's row names: its download's, or
    /// the only one it has. nil for HotS without a download: the install sheet
    /// picks its edition, so the row doesn't promise one.
    func shownPlatform(for product: InstallableProduct) -> InstallPlatform? {
        downloads.values.compactMap(\.request).first { $0.install.uid == product.uid }?.install.platform
            ?? product.onlyPlatform
    }

    func isRunning(_ game: Game) -> Bool {
        game.install.uid == "heroes" ? (running.contains("heroes") || running.contains("heroes@windows")) : running.contains(game.id)
    }

    // MARK: Updates

    func availableUpdate(for game: Game) -> UpdateCheck? {
        guard let check = updates[game.id], check.isUpdateAvailable else { return nil }
        return check
    }

    func canUpdate(_ game: Game) -> Bool {
        !isPreparingToQuit && downloads[game.id] == nil && GameUpdate.canUpdate(game.install) && game.isInstalled && !isRunning(game) && !isBusy(game) &&
            !cleaningFolders.contains(Self.folderKey(game.install.installPath))
    }

    /// Asks Blizzard's version service which build is live. Cheap (one small
    /// request per game), throttled to every 15 minutes unless forced.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 15 * 60 { return }
        lastUpdateCheck = Date()
        for game in discoveredGames where (game.family != .other || GameUpdate.canUpdate(game.install)) && game.isInstalled {
            do {
                let check = try await GameUpdate(install: game.install).check()
                updates[game.id] = check
                Log.info(.gameUpdate, "checked", nil, ["uid": game.id, "installed": game.install.version ?? "?",
                                                       "latest": check.latest.name, "update_available": check.isUpdateAvailable])
            } catch {
                Log.warning(.gameUpdate, "check_failed", nil, ["uid": game.id, "error": error])
            }
        }
    }

    /// Downloads and installs the latest build; with `verify`, re-checks
    /// every file and repairs what's broken.
    func update(_ game: Game, verify: Bool = false) async {
        let volume = await Self.volumeUUID(game.install.installPath)
        guard canUpdate(game) else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.info(.gameUpdate, "requested", nil, ["uid": game.id, "verify": verify])
        await startDownload(DownloadRequest(kind: .update, install: game.install,
            product: InstallableProduct.forProduct(game.install.productCode), target: updates[game.id]?.latest, verify: verify),
            volumeUUID: volume)
    }

    // MARK: Languages

    /// What switching `game` to `languages` downloads (with the update, when
    /// one is waiting), for the language sheet.
    func languageChangeSize(_ game: Game, to languages: GameLanguages) async throws -> UInt64 {
        defer { ProcessMemory.releaseFreed() }
        do {
            return try await GameUpdate(install: game.install).plan(target: updates[game.id]?.latest, languages: languages).downloadSize
        } catch {
            if !Task.isCancelled {
                Log.warning(.gameUpdate, "language_size_failed", nil, ["uid": game.id, "error": error])
            }
            throw error
        }
    }

    /// Switches `game` to other text and spoken languages: their files come
    /// down like an update's (with the update, when one is waiting), and the
    /// game is told (`.build.info`, WoW's Config.wtf, the launch locale).
    func changeLanguages(_ game: Game, to languages: GameLanguages) async {
        let volume = await Self.volumeUUID(game.install.installPath)
        guard canUpdate(game), languages != game.install.languages else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.notice(.gameUpdate, "languages_requested", nil, ["uid": game.id, "text": languages.text, "speech": languages.speech,
                                                            "from_text": game.install.languages.text,
                                                            "from_speech": game.install.languages.speech])
        await startDownload(DownloadRequest(kind: .languages, install: game.install,
            product: InstallableProduct.forProduct(game.install.productCode), target: updates[game.id]?.latest, languages: languages),
            volumeUUID: volume)
    }

    // MARK: Installs

    private func refreshCatalog() async {
        let region = regionOverride ?? Region.preferred(games: games)
        guard !isRefreshingCatalog,
              lastCatalogRegion != region || (lastCatalogAttempt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true) else { return }
        isRefreshingCatalog = true
        lastCatalogAttempt = Date()
        lastCatalogRegion = region
        defer {
            isRefreshingCatalog = false
            if region != (regionOverride ?? Region.preferred(games: games)) { Task { await refreshCatalog() } }
        }
        do {
            let withoutArtwork = !askedForArtwork && ProductCatalog.shared.lacksArtwork
            try await ProductCatalog.shared.refresh(region: region, force: withoutArtwork)
            askedForArtwork = true
            catalogRevision += 1
            reload()
            downloadArtwork(region: region)
        } catch {
            Log.warning(.library, "catalog_refresh_failed", nil, ["error": error])
        }
    }

    // MARK: Artwork

    /// Fetches the pictures and icons the catalog names for the games
    /// Waypoint knows, after launch and off the main thread; a row shows its
    /// own as soon as it has arrived. Those already here cost a look at the
    /// disk and no request, and one that failed isn't asked for again in
    /// this run.
    private func downloadArtwork(region: Region) {
        guard showsArtwork, artworkDownload == nil else { return }
        let hashes = Set(InstallableProduct.all.compactMap(\.artwork).flatMap { [$0.keyArt, $0.icon].compactMap { $0 } })
            .subtracting(missingArtwork)
        guard !hashes.isEmpty else { return }
        let cache = artworkCache, removal = artworkRemoval
        artworkDownload = Task.detached(priority: .utility) { [weak self] in
            await removal?.value
            let failed = await cache.download(hashes, region: region) { _ in
                Task { @MainActor in self?.artworkArrived() }
            }
            await self?.artworkDownloadEnded(failed: failed, region: region, stopped: Task.isCancelled)
        }
    }

    private func artworkArrived() {
        artworkFiles = [:]
        artworkRevision += 1
    }

    private func artworkDownloadEnded(failed: Set<String>, region: Region, stopped: Bool) {
        artworkDownload = nil
        guard showsArtwork else { return }
        missingArtwork.formUnion(failed)
        // Turned off and on again while it ran: it was stopped, so start over.
        if stopped { downloadArtwork(region: region) }
    }

    /// The picture and the icon the catalog has for a game, where they have
    /// been downloaded.
    func artwork(productCode: String) -> (picture: URL?, icon: URL?) {
        guard showsArtwork else { return (nil, nil) }
        _ = artworkRevision
        _ = catalogRevision
        let artwork = InstallableProduct.forProduct(productCode)?.artwork
        func downloaded(_ hash: String?) -> URL? {
            guard let hash else { return nil }
            if let file = artworkFiles[hash] { return file }
            guard let file = artworkCache.file(hash) else { return nil }
            artworkFiles[hash] = file
            return file
        }
        return (downloaded(artwork?.keyArt), downloaded(artwork?.icon))
    }

    /// Games Waypoint can install that aren't installed yet.
    var installable: [InstallableProduct] {
        _ = catalogRevision
        var products = InstallableProduct.available(for: regionOverride ?? Region.preferred(games: games))
        for request in downloads.values.compactMap(\.request) {
            if let product = request.product, !products.contains(where: { $0.uid == product.uid }) { products.append(product) }
        }
        return products.filter { product in
            !games.contains { $0.install.uid == product.uid } &&
            (downloads[installKey(for: product)] != nil || product.supportedPlatforms != [.windows] || WindowsTitle(rawValue: product.productCode)?.isAvailable == true)
        }
    }

    func installKey(for product: InstallableProduct) -> String { defaultPlatform(for: product).installKey(uid: product.uid) }
    func phase(of product: InstallableProduct) -> Phase { phase(uid: installKey(for: product)) }

    /// `phase(of:)` for the library's rows. An install that has just
    /// finished still counts as installing until its job is gone and its
    /// game is in the list: for that moment it is neither, and its row would
    /// drop back among the games on offer and return.
    func rowPhase(of product: InstallableProduct) -> Phase {
        let phase = phase(of: product)
        guard phase == .idle, let job = downloads[installKey(for: product)], case .completed = job.state else { return phase }
        return .updating(job.progress)
    }

    /// What an install would download, for the install sheet, and what an
    /// interrupted install into that folder already has.
    func installSize(_ product: InstallableProduct, folder: URL, region: Region,
                     languages: GameLanguages, platform requestedPlatform: InstallPlatform? = nil) async throws -> (download: UInt64, stored: UInt64) {
        let platform = requestedPlatform ?? defaultPlatform(for: product)
        defer { ProcessMemory.releaseFreed() }
        do {
            try await ProductCatalog.shared.validateDownload(product, region: region, platform: platform)
            let plan = try await GameInstaller(product: product, folder: folder, region: region, languages: languages, platform: platform).plan()
            return (plan.downloadSize, plan.storedBytes)
        } catch {
            if !Task.isCancelled {
                Log.warning(.install, "size_failed", nil, ["uid": product.uid, "path": folder.path, "error": error])
            }
            throw error
        }
    }

    /// The parent of the folder named `folderName` that a game already
    /// installed or downloading uses: another WoW edition's, which a new
    /// edition shares rather than downloading the data again elsewhere.
    func sharedFolderParent(named folderName: String, platform: InstallPlatform) -> URL? {
        // Offline ones too: the sheet then asks for their drive, rather
        // than making a second folder elsewhere.
        let installs = games.map(\.install) + downloads.values.compactMap(\.request).map(\.install)
        return installs.first { $0.platform == platform && URL(fileURLWithPath: $0.installPath).lastPathComponent == folderName }
            .map { URL(fileURLWithPath: $0.installPath, isDirectory: true).deletingLastPathComponent() }
    }

    /// `remembersFolder`: the folder was chosen in the install sheet, and is
    /// offered there first from now on, once the download starts.
    func install(_ product: InstallableProduct, folder: URL, region: Region, languages: GameLanguages,
                 platform requestedPlatform: InstallPlatform? = nil, remembersFolder: Bool = false) async {
        let volume = await Self.volumeUUID(folder.path)
        let platform = requestedPlatform ?? defaultPlatform(for: product)
        defer { ProcessMemory.releaseFreed() }
        let uid = platform.installKey(uid: product.uid)
        let folderKey = Self.folderKey(folder.path)
        guard !isPreparingToQuit, downloads[uid] == nil, !isBusy(uid: uid), !uninstallingFolders.contains(folderKey), !cleaningFolders.contains(folderKey) else { return }
        guard platform != .windows || acceptGraphicsLicense(for: WindowsTitle(rawValue: product.productCode)) else { return }
        if product.productCode == "hero" {
            guard !isBusy(uid: "heroes"), !isBusy(uid: "heroes@windows") else { return }
        }
        Log.notice(.install, "requested", nil, ["uid": product.uid, "path": folder.path, "region": region.rawValue,
                                                "language": languages.text, "speech_language": languages.speech])
        if remembersFolder { rememberInstallFolder(folder.deletingLastPathComponent(), for: platform) }
        let install = product.install(at: folder, region: region, languages: languages,
            tagString: "\(platform.manifestTag) \(region.launchOptionValue) \(languages.text) text \(languages.speech) speech", platform: platform)
        await startDownload(DownloadRequest(kind: .install, install: install, product: product), volumeUUID: volume)
    }

    /// The drive a download goes to, read off the main thread. Callers
    /// read it before their checks, so nothing changes between those and
    /// the download being queued.
    private static func volumeUUID(_ path: String) async -> String? {
        let folder = URL(fileURLWithPath: path)
        return await Task.detached(priority: .userInitiated) { InstallVolume.volumeUUID(at: folder) }.value
    }

    private func startDownload(_ request: DownloadRequest, volumeUUID: String?) async {
        var request = request
        request.volumeUUID = volumeUUID
        do {
            try downloadQueue.enqueue(request)
            phases.removeValue(forKey: request.key)
            if request.kind == .install, request.install.productCode == "hero" { selectHeroesEdition(request.install.platform) }
            await runDownload(uid: request.key)
        } catch {
            Log.error(.cdn, "enqueue_failed", nil, ["uid": request.key, "error": error])
            NSAlert(error: error).runModal()
        }
    }

    /// The folder chosen in the install sheet with Change…, offered there
    /// first from now on for `platform`'s games.
    private func rememberInstallFolder(_ folder: URL, for platform: InstallPlatform) {
        Task {
            let remembered = await Task.detached(priority: .utility) { InstallLocations.Remembered(at: folder) }.value
            InstallLocations().remember(remembered, for: platform)
            Log.info(.install, "folder_remembered", nil, ["platform": platform.rawValue, "path": remembered.path])
        }
    }

    /// A game installed outside the built-in folders (on another drive,
    /// say) is remembered like a located one: while its drive is away it
    /// stays in the library as disconnected, rather than offered again.
    private func rememberInstallLocation(_ install: ProductInstall) async {
        guard InstallLocations().isChosen(installPath: install.installPath) else { return }
        let url = URL(fileURLWithPath: install.installPath, isDirectory: true)
        let location = await Task.detached(priority: .utility) { LocatedGames.Location(installedAt: url, install: install) }.value
        locatedStore.record(location, installed: install.key)
        Log.info(.library, "install_location_remembered", nil, ["uid": install.key, "path": location.path])
        locationsChanged(rescanning: false)
    }

    /// Games an earlier version installed outside the built-in folders are
    /// remembered as if installed now, each once, when its drive is
    /// connected: afterwards, Remove from Library and uninstalling forget
    /// them for good.
    private func rememberEarlierInstallLocations() {
        let adoptedKey = "adoptedInstallLocations"
        let adopted = UserDefaults.standard.stringArray(forKey: adoptedKey) ?? []
        let store = library.stateStore, known = locatedStore.locations(), chosen = InstallLocations()
        Task {
            let (found, considered) = await Task.detached(priority: .utility) {
                let installs = store.standaloneInstalls().filter {
                    chosen.isChosen(installPath: $0.installPath) && !adopted.contains("\($0.key)|\($0.installPath)")
                }
                let found = LocatedGames.unremembered(installs, known: known, chosen: chosen)
                let paths = Set(found.map(\.path))
                // Each looked at once: what's remembered now, or was
                // already. One whose drive isn't connected, or that isn't on
                // disk, is looked at again next time.
                let considered = installs.filter { install in
                    let path = URL(fileURLWithPath: install.installPath).standardizedFileURL.path
                    return paths.contains(path) || known.contains { $0.contains(path) }
                }
                return (found, considered.map { "\($0.key)|\($0.installPath)" })
            }.value
            if !considered.isEmpty { UserDefaults.standard.set(adopted + considered, forKey: adoptedKey) }
            guard !found.isEmpty else { return }
            for location in found { locatedStore.record(location, installed: nil) }
            Log.notice(.library, "earlier_install_locations_remembered", nil, ["paths": found.map(\.path).joined(separator: ",")])
            locationsChanged()
        }
    }

    private func runDownload(uid: String) async {
        let request = downloads[uid]?.request
        if await downloadQueue.run(key: uid) == .completed {
            if let request, request.kind == .install { await rememberInstallLocation(request.install) }
            reload()
            await checkForUpdates(force: true)
        }
    }

    func canPauseDownload(uid: String) -> Bool { downloads[uid]?.canPause == true && !isUninstalling(uid: uid) }

    func pauseDownload(uid: String) { downloads[uid]?.pause() }

    func downloadBytesPerSecond(uid: String) -> Double? { downloads[uid]?.bytesPerSecond }

    func keepsMacAwake(uid: String) -> Bool { downloads[uid]?.keepsMacAwake == true }

    func toggleKeepAwake(uid: String) {
        guard let job = downloads[uid], job.canPause || job.canResume else { return }
        job.keepsMacAwake.toggle()
    }

    func canCancelDownload(uid: String) -> Bool { downloads[uid]?.canCancel == true && !isUninstalling(uid: uid) }

    /// A new install's download, rather than an update of an installed game.
    func isInstallDownload(uid: String) -> Bool { downloads[uid]?.request?.kind == .install }

    /// Stop tracking a paused job. Its verified data stays available for a
    /// later install/update; no writer is active when canCancel is true.
    func cancelDownload(uid: String) {
        guard canCancelDownload(uid: uid) else { return }
        guard discardDownload(uid: uid) else { return }
        reload()
        phases.removeValue(forKey: uid)
        Log.notice(.cdn, "cancelled", "keeping downloaded data", ["uid": uid])
    }

    /// An install that never finished, which cancelling can also clear away.
    struct UnfinishedInstall {
        var name: String
        /// What would go to the Trash.
        var plan: UninstallPlan
        fileprivate var uninstaller: GameUninstaller
    }

    /// The install behind `uid`, when cancelling it can offer to move what
    /// it downloaded to the Trash: a paused or failed install of a game
    /// that isn't on disk, into a folder nothing else uses. Nil for updates
    /// and language changes, whose data is the installed game's own, for a
    /// folder other games or downloads share, and when nothing in the
    /// folder is plainly this install's (see `GameUninstaller.unfinishedPlan`).
    func unfinishedInstall(uid: String) -> UnfinishedInstall? {
        guard canCancelDownload(uid: uid), let request = downloads[uid]?.request, request.kind == .install else { return nil }
        let folder = Self.folderKey(request.install.installPath)
        guard !uninstallingFolders.contains(folder), !cleaningFolders.contains(folder),
              !downloads.keys.contains(where: { $0 != uid && jobFolders[$0] == folder }) else { return nil }
        let name = request.product?.displayName ?? GameCatalog.game(for: request.install).displayName
        // Other downloads count as games too: one into a folder inside this
        // one keeps the folder from going.
        let others = discoveredGames.map(\.install) + downloads.filter { $0.key != uid }.values.compactMap(\.request).map(\.install)
        let uninstaller = GameUninstaller(install: request.install, displayName: name, keepsUserFiles: true, otherInstalls: others)
        guard let plan = try? uninstaller.unfinishedPlan() else { return nil }
        return UnfinishedInstall(name: name, plan: plan, uninstaller: uninstaller)
    }

    /// Cancels an install that never finished and moves what it downloaded
    /// to the Trash. Checks again that it is one: if anything changed since
    /// the question was asked, nothing happens and the download stays.
    func cancelDownloadMovingToTrash(uid: String) async {
        guard let install = unfinishedInstall(uid: uid) else { return }
        let folder = Self.folderKey(install.plan.root.path)
        uninstallingFolders.insert(folder)
        phases[uid] = .uninstalling("Moving to the Trash…")
        Log.notice(.cdn, "cancel_requested", "moving downloaded data to the Trash", ["uid": uid, "path": folder])
        var failure: Error?
        do {
            try await install.uninstaller.removeUnfinished()
        } catch {
            failure = error
        }
        // Either way the row is the download's again: gone with it, or back
        // to paused or failed.
        uninstallingFolders.remove(folder)
        phases.removeValue(forKey: uid)
        if let failure {
            Log.error(.cdn, "cancel_failed", "downloaded data stays", ["uid": uid, "error": failure])
            // Said in full: the errors that stop this (Battle.net running,
            // another writer) have no text of their own for an alert.
            let alert = NSAlert()
            alert.messageText = "Waypoint couldn’t move \(install.name)’s download to the Trash"
            alert.informativeText = "Nothing was moved, and the download is still there to resume or cancel.\n\n\(errorMessage(failure))"
            alert.runModal()
            return
        }
        discardDownload(uid: uid)
        reload()
        Log.notice(.cdn, "cancelled", "moved downloaded data to the Trash", ["uid": uid])
    }

    func canResumeDownload(uid: String) -> Bool {
        !isPreparingToQuit && downloads[uid]?.canResume == true && !running.contains(uid) && !isUninstalling(uid: uid) &&
            !games.contains { $0.id == uid && $0.isOffline }
    }

    func resumeDownload(uid: String) async {
        guard canResumeDownload(uid: uid) else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.notice(.cdn, "resume_requested", nil, ["uid": uid])
        await runDownload(uid: uid)
    }

    @discardableResult
    private func discardDownload(uid: String) -> Bool {
        do { try downloadQueue.remove(key: uid); return true }
        catch { NSAlert(error: error).runModal(); return false }
    }

    var hasActiveDownloads: Bool { downloadQueue.hasActiveJobs }
    var downloadRecoveryError: String? {
        downloadQueue.restoreErrors.first.map { "Some unfinished downloads could not be restored. \($0)" }
    }

    func prepareToQuit() async -> Bool {
        isPreparingToQuit = true
        do {
            try await downloadQueue.pauseAll()
            return true
        } catch {
            isPreparingToQuit = false
            NSAlert(error: error).runModal()
            return false
        }
    }

    // MARK: Uninstalling

    /// Whether `game` can be uninstalled now: it's on disk, and nothing in
    /// its folder is running, busy or has a download to resume (a paused
    /// WoW install keeps its data in the shared storage).
    func canUninstall(_ game: Game) -> Bool {
        let folder = Self.folderKey(game.install.installPath)
        let neighbours = discoveredGames.filter { Self.folderKey($0.install.installPath) == folder }
        return game.isInstalled && !isBusy(game) && !isRunning(game) && !cleaningFolders.contains(folder) &&
            !neighbours.contains { isRunning($0) || isBusy(uid: $0.id) } &&
            !downloads.keys.contains { $0 != game.id && jobFolders[$0] == folder }
    }

    private func isUninstalling(uid: String) -> Bool {
        if case .uninstalling = phases[uid] { true } else { false }
    }

    /// What uninstalling `game` takes away, for the confirmation, and how.
    func uninstaller(for game: Game, keepingUserFiles: Bool) -> GameUninstaller {
        GameUninstaller(install: game.install, displayName: game.displayName, keepsUserFiles: keepingUserFiles,
                        otherInstalls: discoveredGames.filter { $0.id != game.id }.map(\.install))
    }

    /// Moves `game` to the Trash and forgets it; with `keepingUserFiles`, a
    /// WoW version's add-ons, settings and screenshots stay. A WoW version
    /// that shared its folder then frees what only it used in the shared
    /// storage.
    func uninstall(_ game: Game, keepingUserFiles: Bool) async {
        guard canUninstall(game) else { return }
        let folder = Self.folderKey(game.install.installPath)
        uninstallingFolders.insert(folder)
        // Shows over a failed download's state (and keeps it from resuming)
        // until the job goes with the game.
        phases[game.id] = .uninstalling("Moving to the Trash…")
        Log.notice(.install, "uninstall_requested", nil, ["uid": game.id, "path": folder, "keep_user_files": keepingUserFiles])
        let uninstaller = uninstaller(for: game, keepingUserFiles: keepingUserFiles)
        let plan: UninstallPlan
        do {
            plan = try await uninstaller.remove()
        } catch {
            uninstallingFolders.remove(folder)
            Log.error(.install, "uninstall_failed", nil, ["uid": game.id, "error": error])
            phases[game.id] = .failed(errorMessage(error))
            reload()
            let gone = !games.contains(where: { $0.id == game.id })
            if gone || downloads[game.id] != nil {
                // No row can say it: the game is gone all the same (putting it
                // back failed), or its row shows a failed download's message.
                phases.removeValue(forKey: game.id)
                if gone { discardDownload(uid: game.id) }
                NSAlert(error: error).runModal()
            }
            return
        }
        discardDownload(uid: game.id)
        uninstallingFolders.remove(folder)
        var cleanupError: Error?
        if plan.sharesStorage {
            // Network fetches can make this take minutes: the other versions
            // stay playable (not updatable), and only this row waits.
            cleaningFolders.insert(folder)
            phases[game.id] = .uninstalling("Freeing up space…")
            do {
                let result = try await uninstaller.cleanSharedStorage()
                Log.notice(.install, "uninstall_storage_cleaned", nil, ["uid": game.id, "reclaimed_bytes": result.reclaimedBytes])
            } catch {
                Log.warning(.install, "uninstall_storage_kept", nil, ["uid": game.id, "error": error])
                cleanupError = error
            }
            cleaningFolders.remove(folder)
        }
        phases.removeValue(forKey: game.id)
        updates.removeValue(forKey: game.id)
        // Forgotten where it was remembered (installed on another drive, or
        // located there), before its drive can be ejected and the game
        // kept as offline.
        if locatedStore.forget(key: game.install.key, at: game.install.installPath) { locationsChanged(rescanning: false) }
        reload()
        // What else a remembered location there holds is read again.
        if library.located.locations.contains(where: { $0.contains(game.install.installPath) }) { scanOffMainThreadOnce() }
        if let cleanupError {
            let alert = NSAlert()
            alert.messageText = "\(game.displayName) is uninstalled, but the space it used in “\(plan.root.lastPathComponent)” isn’t free yet"
            alert.informativeText = "It’s freed the next time another game in that folder updates.\n\n\(errorMessage(cleanupError))"
            alert.runModal()
        }
    }

    private static func folderKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    private func phase(uid: String) -> Phase {
        if isUninstalling(uid: uid) { return phases[uid]! }
        guard let job = downloads[uid] else { return phases[uid] ?? .idle }
        switch job.state {
        case .ready, .running: return .updating(job.progress)
        case .pausing: return .pausing(job.progress)
        case .paused: return .paused(job.progress)
        case .failed(let message): return .failed(message)
        case .completed: return .idle
        }
    }

    private func isBusy(uid: String) -> Bool {
        switch phase(uid: uid) {
        case .signingIn, .preparingWindows, .launching, .updating, .pausing, .paused, .uninstalling: true
        default: false
        }
    }

    func phase(of game: Game) -> Phase { phase(uid: game.id) }

    /// Also while another game is uninstalled from its folder.
    func isBusy(_ game: Game) -> Bool {
        isBusy(uid: game.id) || uninstallingFolders.contains(Self.folderKey(game.install.installPath))
    }

    /// Only one sign-in at a time: the login window and the hidden web view
    /// each serve a single request.
    var isSigningIn: Bool {
        isAddingAccount || isManagingSavedLogin || phases.values.contains {
            switch $0 { case .signingIn, .preparingWindows: true; default: false }
        }
    }

    func canPlay(_ game: Game) -> Bool {
        !isPreparingToQuit && game.isSupported && !isRunning(game) && !isBusy(game) && !isSigningIn &&
            // WoW editions share one launch preference slot. Other games
            // can start while a WoW client consumes its handoff.
            !(isNativeWoW(game) && (isFindingWoWAccounts || games.contains { isNativeWoW($0) && phases[$0.id] == .launching }))
    }

    /// `forceSignIn` skips the saved token, for when the game rejects it.
    /// `accountID`: Play As, another saved account for this launch only; the
    /// active one stays active.
    func play(_ game: Game, forceSignIn: Bool = false, as accountID: String? = nil) async {
        guard canPlay(game) else { return }
        guard acceptGraphicsLicense(for: WindowsTitle.forInstall(game.install)) else { return }
        let account: Account?
        if let accountID {
            guard let other = accountList[accountID] else { return }
            account = other
        } else {
            account = activeAccount
        }
        Log.info(.launch, "requested", nil, ["uid": game.id, "version": game.install.version ?? "?",
                                             "force_sign_in": forceSignIn, "play_as": accountID != nil])
        guard discardDownload(uid: game.id) else { return }
        do {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            let mode = CGDisplayCopyDisplayMode(displayID)
            let display = mode.map { WindowsDisplay(width: $0.pixelWidth, height: $0.pixelHeight,
                                                    framesPerSecond: screen?.maximumFramesPerSecond ?? 60) }
            var plan = try GameLauncher.plan(for: game, region: regionOverride, display: display)
            if plan.isWindows { phases[game.id] = .preparingWindows(nil) }
            else { phases[game.id] = .signingIn }
            let session = try await GameLauncher.prepareWindows(plan) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .preparingWindows = self.phases[game.id] else { return }
                    self.phases[game.id] = .preparingWindows(progress.completedFiles == progress.totalFiles ? nil : progress)
                }
            }
            phases[game.id] = .signingIn
            guard let token = await token(for: plan, gameName: game.displayName, account: account,
                                          activate: accountID == nil, forceSignIn: forceSignIn) else {
                Log.notice(.auth, "sign_in_cancelled", nil, ["uid": game.id])
                phases[game.id] = .idle
                return
            }
            if plan.codename == "WoW", !plan.isWindows {
                plan.gameAccount = wowAccountStore.launchAccount(for: token, uid: game.id, region: plan.region)
                if plan.gameAccount == nil, wowAccountStore.selected(owner: token.accountID, uid: game.id, region: plan.region) != nil {
                    // Gone from the account at the last lookup: WoW chooses.
                    Log.notice(.launch, "wow_account_unavailable", nil, ["uid": game.id])
                }
            }
            phases[game.id] = .launching
            if let session {
                let pid = try await GameLauncher.launchWindows(plan, token: token, session: session, gameName: game.displayName)
                windowsSessions[game.id] = session
                observeWindowsExit(pid: pid, game: game)
                Task { [weak self] in await self?.revealWindowsGame(game) }
            } else {
                try GameLauncher.launch(plan, token: token, gameName: game.displayName)
            }
            UserDefaults.standard.set(game.id, forKey: Self.lastPlayedKey)
            if let title = WindowsTitle.forInstall(game.install), title != .heroes, let session {
                // A Wine process may stall before creating its first window.
                // Keep the process tracked to prevent duplicate launches, but
                // don't present that as a completed launch.
                let result = await waitForWindowsWindow(game, title: title)
                guard !Task.isCancelled else { return }
                refreshRunning()
                Log.info(.launch, result == .created ? "window_created" : "window_missing", nil,
                         ["uid": game.id, "reason": result.rawValue])
                phases[game.id] = result == .created ? .idle : .failed(result == .stalled
                    ? "The game has not opened a window. If its process is still running, quit it in Activity Monitor before trying again."
                    : "The game exited before opening a window.")
                if result == .stalled { watchForLateWindowsWindow(game, title: title, session: session) }
                return
            }
            // Keep "launching" until the game shows up in the running list.
            try? await Task.sleep(for: .seconds(4))
            refreshRunning()
            Log.info(.launch, "running_check", nil, ["uid": game.id, "running": running.contains(game.id)])
            phases[game.id] = .idle
        } catch {
            Log.error(.launch, "failed", nil, ["uid": game.id, "error": error])
            phases[game.id] = .failed(errorMessage(error))
        }
    }

    // MARK: WoW accounts

    private func isNativeWoW(_ game: Game) -> Bool {
        game.install.platform == .macOS && GameCatalog.family(for: game.install.productCode) == .worldOfWarcraft
    }

    func canRefreshWoWAccounts(_ game: Game) -> Bool {
        guard isNativeWoW(game), let owner = activeAccount?.id,
              let plan = try? GameLauncher.plan(for: game, region: regionOverride) else { return false }
        return WoWAccountDiscovery.supports(plan.region) && tokenVault.hasToken(account: owner, codename: "WoW")
    }

    func offersWoWAccounts(_ game: Game) -> Bool {
        activeAccount != nil && isNativeWoW(game) && (canRefreshWoWAccounts(game) || !knownWoWAccounts(for: game).isEmpty)
    }

    /// Captured when a menu is built, so its actions apply to the account
    /// and region it showed.
    func wowAccountScope(for game: Game) -> WoWAccountScope? {
        guard isNativeWoW(game), let owner = activeAccount?.id,
              let plan = try? GameLauncher.plan(for: game, region: regionOverride) else { return nil }
        return WoWAccountScope(owner: owner, uid: game.id, region: plan.region)
    }

    func selectedWoWAccount(for game: Game) -> WoWGameAccount? {
        guard let scope = wowAccountScope(for: game) else { return nil }
        return wowAccountStore.selected(owner: scope.owner, uid: scope.uid, region: scope.region)
    }

    /// The last lookup's licenses, plus the saved choice if that lookup no
    /// longer listed it (shown as unavailable).
    func knownWoWAccounts(for game: Game) -> [WoWGameAccount] {
        guard let scope = wowAccountScope(for: game) else { return [] }
        var accounts = wowAccountStore.cachedAccounts(owner: scope.owner, region: scope.region)
        if let selected = selectedWoWAccount(for: game), !accounts.contains(where: { $0.id == selected.id }) { accounts.append(selected) }
        return accounts
    }

    func isAvailableWoWAccount(_ account: WoWGameAccount, for game: Game) -> Bool {
        guard let scope = wowAccountScope(for: game) else { return false }
        return wowAccountStore.isAvailable(account, owner: scope.owner, region: scope.region)
    }

    /// The license the library row shows, when there's a choice to show.
    func shownWoWAccount(for game: Game) -> WoWGameAccount? {
        wowAccountScope(for: game).flatMap { wowAccountStore.shownChoice(in: $0) }
    }

    /// `nil` lets WoW choose at login. Refused while the game is busy, and
    /// when the account or region changed since `scope` was captured.
    func useWoWAccount(_ account: WoWGameAccount?, for game: Game, in scope: WoWAccountScope) throws {
        guard canPlay(game) else { throw Self.wowGameBusy }
        guard wowAccountStore.select(account, in: scope, current: wowAccountScope(for: game)) else { throw Self.wowScopeChanged }
    }

    /// Looks up the licenses for `scope`. With exactly one, it becomes the
    /// choice; with several, the choice is left to the user.
    func findWoWAccounts(for game: Game, in scope: WoWAccountScope) async throws -> [WoWGameAccount] {
        guard !isRunning(game) else { throw WoWAccountDiscovery.Failure.gameRunning }
        guard canPlay(game) else { throw Self.wowGameBusy }
        guard wowAccountScope(for: game) == scope else { throw Self.wowScopeChanged }
        guard canRefreshWoWAccounts(game), let token = tokenVault.token(account: scope.owner, codename: "WoW"),
              token.accountID == scope.owner else {
            throw NSError(domain: "Waypoint", code: 1, userInfo: [NSLocalizedDescriptionKey: "Play WoW once to sign in, then try again."])
        }
        isFindingWoWAccounts = true
        defer { isFindingWoWAccounts = false }
        guard let app = game.appURL, let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = version.split(separator: ".").last.flatMap({ UInt64($0) }), build > 0 else {
            throw NSError(domain: "Waypoint", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn’t read this WoW installation’s version."])
        }
        let accounts = try await WoWAccountDiscovery().discover(token: token, build: build, region: scope.region)
        try Task.checkCancellation()
        guard accountList[scope.owner] != nil else { throw CancellationError() }
        guard wowAccountStore.cache(accounts, owner: scope.owner, region: scope.region) else {
            throw NSError(domain: "Waypoint", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn’t read Blizzard’s account list."])
        }
        wowAccountStore.selectOnlyAccount(in: scope)
        return wowAccountStore.cachedAccounts(owner: scope.owner, region: scope.region)
    }

    static let wowGameBusy = NSError(domain: "Waypoint", code: 4, userInfo: [
        NSLocalizedDescriptionKey: "Finish the current game action, then try again.",
    ])
    /// Retrying can't help: the sheet or menu shows another account's or
    /// region's choices.
    static let wowScopeChanged = NSError(domain: "Waypoint", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "Your account or region changed. Open the menu again to choose.",
    ])

    // MARK: Accounts

    var hasSavedLogin: Bool { activeAccount.map { autoLoginStates[$0.id] != nil } ?? false }

    var savedLoginStatus: String {
        guard let account = activeAccount else { return "Sign in to save a Battle.net login." }
        guard let state = autoLoginStates[account.id] else { return "Automatic login is off. Save a login to enable it." }
        if state.isPaused {
            return "Automatic login is paused. Update the saved login to enable it again."
        }
        if let retry = state.retryAfter, retry > Date() {
            return "Automatic login will be available after \(retry.formatted(date: .omitted, time: .shortened))."
        }
        return "Login saved in Keychain. Automatic login is on."
    }

    func editSavedLogin() {
        guard !isSigningIn, let account = activeAccount else { return }
        isManagingSavedLogin = true
        defer { isManagingSavedLogin = false }
        do {
            let old = try? credentialVault.credentials(account: account.id, allowInteraction: true)
            guard let credentials = CredentialEditor.run(account: account, username: old?.username,
                                                          replacing: hasSavedLogin) else { return }
            try credentialVault.save(credentials, account: account.id)
            autoLoginStates[account.id] = AutoLoginState()
            Log.notice(.auth, "saved_login_updated")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func removeSavedLogin() {
        guard !isSigningIn, let account = activeAccount else { return }
        do {
            try credentialVault.remove(account: account.id)
            autoLoginStates.removeValue(forKey: account.id)
            Log.notice(.auth, "saved_login_removed")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Makes another saved account the one games launch with. Nothing is
    /// fetched: its own web session and tokens are already here.
    func switchAccount(to id: String) {
        guard !isSigningIn, id != accountList.activeID else { return }
        accountList.activate(id)
        Log.notice(.auth, "account_switched", nil, ["accounts": accounts.count])
    }

    /// Signs in to another account in the login window, in a web session of
    /// its own. It becomes the active account.
    func addAccount() async {
        await signIn(title: "Add a Battle.net Account", reason: "add_account")
    }

    /// Signs the active account in again, for when a game won't take its
    /// token. A changed password or authenticator voids all of an account's
    /// tokens, so the other games' ones go too and each gets a fresh one on
    /// its next launch.
    func signInAgain() async {
        guard let account = activeAccount else { return }
        await signIn(title: "Sign In to \(account.displayName) Again", reason: "sign_in_again", replacing: account.id,
                     accountName: account.email)
    }

    /// `replacing`: the account whose saved tokens a sign-in to it replaces;
    /// `accountName`: its email or phone, filled in for the user.
    private func signIn(title: String, reason: String, replacing: String? = nil, accountName: String? = nil) async {
        guard !isSigningIn else { return }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let target = loginTarget()
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": target.codename, "region": target.region.rawValue, "reason": reason])
        guard let token = await loginWindow.run(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                title: title, session: session, accountName: accountName,
                                                expectedOwner: replacing)
        else {
            Log.notice(.auth, "sign_in_cancelled", nil, ["reason": reason])
            await WebSession.delete(session)
            return
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": target.codename])
        let saved = await adoptFromLoginWindow(token, codename: target.codename, session: session)
        if let replacing, token.accountID == replacing {
            if saved {
                do {
                    try tokenVault.removeAll(account: replacing, except: target.codename)
                    Log.notice(.auth, "other_game_tokens_removed")
                } catch {
                    Log.warning(.auth, "token_remove_failed", nil, ["error": error])
                }
            } else {
                // Better asked again on the next Play than handed a dead token.
                tokenVault.removeAll(account: replacing)
                Log.notice(.auth, "all_tokens_removed")
            }
        }
    }

    /// Signs the active account out: its web session and saved tokens are
    /// deleted, and the next saved account, if any, becomes active.
    func signOut() async {
        guard !isSigningIn, let account = activeAccount else { return }
        // If deletion fails, keep the account and report it rather than
        // silently leaving a password behind after Sign Out.
        do { try credentialVault.remove(account: account.id) } catch {
            NSAlert(error: error).runModal()
            return
        }
        autoLoginStates.removeValue(forKey: account.id)
        wowAccountStore.remove(owner: account.id)
        accountList.remove(account.id)
        tokenVault.removeAll(account: account.id)
        for codename in Set(InstallableProduct.all.map(\.codename)) {
            let options = LaunchOptions(gameKey: codename)
            if let stored = try? options.storedToken(), LoginToken(stored)?.accountID == account.id {
                options.clearToken()
            }
        }
        await WebSession.delete(account.session)
        Log.notice(.auth, "signed_out", nil, ["accounts": accounts.count])
    }

    /// At launch: deletes web sessions no account uses (a cancelled sign-in
    /// leaves one behind), looks up names still missing, and the first time,
    /// finds out who is signed in to the session from before Waypoint had
    /// accounts.
    private func setUpAccounts() async {
        await WebSession.deleteAll(except: Set(accounts.map(\.session)))
        for account in accounts where account.battleTag == nil {
            await refreshProfile(account.id)
        }
        let adoptedKey = "adoptedSharedWebSession"
        guard accounts.isEmpty, !UserDefaults.standard.bool(forKey: adoptedKey) else { return }
        UserDefaults.standard.set(true, forKey: adoptedKey)
        guard await WebSession.hasCookies(.shared) else { return }
        let target = loginTarget()
        let result = await SilentTokenFetcher().fetch(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                      session: .shared)
        // Someone may have signed in meanwhile.
        guard case .token(let token) = result, accounts.isEmpty else { return }
        Log.info(.auth, "token", nil, ["source": "web_session", "codename": target.codename, "reason": "adopt"])
        await adopt(token, codename: target.codename, session: .shared)
    }

    /// The game launched last: signing in to an account gets the token for
    /// it, since each game needs one of its own.
    private static let lastPlayedKey = "lastPlayedGame"

    /// The login page asks which game it signs in to (`app=`): the game
    /// launched last, else the first that can be played, else Hearthstone,
    /// which every account has.
    private func loginTarget() -> (codename: String, region: Region) {
        let last = UserDefaults.standard.string(forKey: Self.lastPlayedKey)
        let candidates = games.filter { $0.id == last } + games.filter { $0.id != last }
        let plan = candidates.lazy.compactMap { try? GameLauncher.plan(for: $0, region: self.regionOverride) }.first
        return (plan?.codename ?? InstallableProduct.hearthstone.codename, plan?.region ?? regionOverride ?? .us)
    }

    /// `adopt` for a token from the login window. One its browser sign-in
    /// returned leaves a saved account's web session as it is, since that
    /// session never signed in, and names the account by what the game
    /// service said.
    @discardableResult
    private func adoptFromLoginWindow(_ token: LoginToken, codename: String, session: WebSessionID,
                                      activate: Bool = true) async -> Bool {
        guard let profile = loginWindow.verifiedProfile, profile.accountID == token.accountID else {
            return await adopt(token, codename: codename, session: session, typedName: loginWindow.typedAccountName,
                               activate: activate)
        }
        Log.info(.auth, "browser_return_adopted", nil, ["codename": codename])
        let kept = accountList[token.accountID]?.session
        if let kept, kept != session { await WebSession.delete(session) }
        return await adopt(token, codename: codename, session: kept ?? session, activate: activate, profile: profile)
    }

    /// Remembers who signed in where: that account, new or saved, becomes
    /// active and keeps the token for next time. A session it no longer uses
    /// is deleted.
    /// `typedName`: the email or phone typed into the login form, which names
    /// the account until (and unless) Blizzard's account page tells the
    /// BattleTag and email.
    /// Returns whether the token made it into the keychain.
    @discardableResult
    private func adopt(_ token: LoginToken, codename: String, session: WebSessionID, typedName: String? = nil,
                       activate: Bool = true, profile: NativeAccountProfile? = nil) async -> Bool {
        let id = token.accountID
        let isNew = accountList[id] == nil
        let unused = accountList.signedIn(id, session: session, activate: activate)
        if let typedName, accountList[id]?.email == nil { accountList.setProfile(id, battleTag: nil, email: typedName) }
        if let profile { accountList.setNativeProfile(profile, for: id) }
        var saved = true
        do {
            try tokenVault.save(token, codename: codename)
        } catch {
            saved = false
            Log.warning(.auth, "token_save_failed", nil, ["error": error])
        }
        if isNew { Log.notice(.auth, "account_added", nil, ["accounts": accounts.count]) }
        if let unused { await WebSession.delete(unused) }
        if accountList[id]?.battleTag == nil { Task { await refreshProfile(id) } }
        return saved
    }

    /// Looks up the account's BattleTag and email on Blizzard's account page.
    private func refreshProfile(_ id: String) async {
        guard let account = accountList[id], profileFetches.insert(id).inserted else { return }
        defer { profileFetches.remove(id) }
        switch await ProfileFetcher().fetch(session: account.session) {
        case .signedIn(let profile):
            if let other = profile.accountID, other != id {
                Log.warning(.auth, "profile_other_account")
                return
            }
            accountList.setProfile(id, battleTag: profile.battleTag, email: profile.email)
            Log.info(.auth, "profile", nil, ["battletag": profile.battleTag != nil, "email": profile.email != nil])
        case .signedOut:
            Log.info(.auth, "profile_signed_out")
        case .failed:
            Log.info(.auth, "profile_failed")
        }
    }

    /// The account's token for the game, from the keychain. Without one (or
    /// when forced), signs in once with the saved password when opted in, then
    /// opens the login window; a rejected saved login goes to the interactive
    /// window instead. `activate`: whether whoever signs in becomes the
    /// active account.
    private func token(for plan: LaunchPlan, gameName: String, account: Account?, activate: Bool,
                       forceSignIn: Bool) async -> LoginToken? {
        // Only where the token came from is logged, never the token.
        let url = BattleNetLogin.url(codename: plan.codename, region: plan.region)
        let title = "Sign in to play \(gameName)" + (activate ? "" : account.map { " as \($0.displayName)" } ?? "")
        // Only tokens Waypoint got itself. The one Battle.net leaves in the
        // game's Launch Options can be long expired: the game then shows
        // "Closed" and Waypoint can't tell, so it would keep handing it over.
        // Nothing is refreshed first: Battle.net's login page keeps no session
        // that signs in again without the form, and a token lasts for months.
        if !forceSignIn, let account, let token = tokenVault.token(account: account.id, codename: plan.codename) {
            Log.info(.auth, "token", nil, ["source": "keychain", "codename": plan.codename])
            return token
        }

        // Hearthstone and Diablo IV can get their ticket from the saved WoW
        // login instead of a sign-in of their own. Whatever stops that, the
        // usual sign-in below follows, without a word about it. Not while WoW
        // accounts are being found: that's a game-service sign-in already.
        if !forceSignIn, !isFindingWoWAccounts, let account, let game = SharedSignIn(codename: plan.codename),
           let issued = await WoWAccountDiscovery(timeout: .seconds(15))
               .sharedTicket(for: game, from: tokenVault.token(account: account.id, codename: "WoW"),
                             account: account.id, region: plan.region),
           accountList[account.id] != nil {
            Log.info(.auth, "token", nil, ["source": "shared_sign_in", "codename": plan.codename])
            do {
                try tokenVault.save(issued, codename: plan.codename)
            } catch {
                Log.warning(.auth, "token_save_failed", nil, ["error": error])
            }
            return issued
        }
        // Cancelled meanwhile: nobody is waiting for a login window.
        guard !Task.isCancelled else { return nil }

        if let account, var state = autoLoginStates[account.id], state.begin() {
            autoLoginStates[account.id] = state // Persist before reading/submitting the password.
            let session = forceSignIn ? WebSessionID.fresh() : account.session
            let result: CredentialTokenFetcher.Result
            do {
                if let credentials = try credentialVault.credentials(account: account.id) {
                    Log.info(.auth, "automatic_login_started")
                    result = await CredentialTokenFetcher().fetch(url, session: session, credentials: credentials)
                } else {
                    state.requiresSignIn()
                    result = .failed
                }
            } catch {
                // A locked/unavailable Keychain counts as a temporary failure.
                result = .failed
            }
            switch result {
            case .token(let token):
                guard token.accountID == account.id else {
                    state.requiresSignIn()
                    autoLoginStates[account.id] = state
                    if session != account.session { await WebSession.delete(session) }
                    showWrongSavedAccount(account)
                    return nil
                }
                state.succeeded()
                autoLoginStates[account.id] = state
                Log.info(.auth, "token", nil, ["source": "saved_login", "codename": plan.codename])
                await adopt(token, codename: plan.codename, session: session, activate: activate)
                return token
            case .interaction(let view):
                state.requiresSignIn()
                autoLoginStates[account.id] = state
                Log.notice(.auth, "automatic_login_paused")
                let notice = "Automatic login is paused. Complete sign-in below. If your password changed, \(updateSavedLoginHint(account))."
                guard let token = await loginWindow.run(url, title: title, session: session,
                                                       preparedWebView: view, notice: notice,
                                                       expectedOwner: account.id) else {
                    if session != account.session { await WebSession.delete(session) }
                    return nil
                }
                guard token.accountID == account.id else {
                    if session != account.session { await WebSession.delete(session) }
                    showWrongSavedAccount(account)
                    return nil
                }
                // Manual sign-in may have used another password: only an
                // explicit Update Saved Login re-enables these credentials.
                await adoptFromLoginWindow(token, codename: plan.codename, session: session, activate: activate)
                return token
            case .failed:
                state.failedTemporarily()
                autoLoginStates[account.id] = state
                if session != account.session { await WebSession.delete(session) }
                Log.notice(.auth, "automatic_login_failed", nil, ["attempts": state.attempts, "paused": state.isPaused])
            }
        }

        var notices: [String] = []
        if let account, autoLoginStates[account.id]?.isPaused == true {
            notices.append("Automatic login is paused. Sign in here, then \(updateSavedLoginHint(account)) to replace the saved password.")
        }
        // Signed in, yet asked again: Battle.net's tokens are per game.
        if account != nil, !forceSignIn {
            notices.append("Battle.net signs in to each game separately, so \(gameName) needs its own sign-in. It’s needed only once.")
        }
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": plan.codename, "region": plan.region.rawValue, "forced": forceSignIn])
        // Play As and Sign In Again and Play are for one account; a browser
        // sign-in to another is refused there.
        guard let token = await loginWindow.run(url, title: title, session: session, accountName: account?.email,
                                               notice: notices.isEmpty ? nil : notices.joined(separator: "\n\n"),
                                               expectedOwner: forceSignIn || !activate ? account?.id : nil) else {
            await WebSession.delete(session)
            return nil
        }
        // Play As names the account; launching another one would surprise.
        if !activate, let account, token.accountID != account.id {
            await WebSession.delete(session)
            Log.warning(.auth, "play_as_other_account")
            let alert = NSAlert()
            alert.messageText = "That’s a different account"
            alert.informativeText = "You signed in to a different Battle.net account than \(account.displayName), so \(gameName) wasn’t started. Try again and sign in as \(account.displayName)."
            alert.runModal()
            return nil
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": plan.codename])
        await adoptFromLoginWindow(token, codename: plan.codename, session: session, activate: activate)
        return token
    }

    /// Where to fix an account's saved login: the menus act on the active one.
    private func updateSavedLoginHint(_ account: Account) -> String {
        account.id == activeAccount?.id
            ? "use Update Saved Login in the account menu or Settings"
            : "switch to \(account.displayName), then use Update Saved Login in the account menu or Settings"
    }

    private func showWrongSavedAccount(_ account: Account) {
        Log.warning(.auth, "saved_login_other_account")
        let alert = NSAlert()
        alert.messageText = "The saved login belongs to a different account"
        alert.informativeText = "Automatic login is paused. To enter this account’s login and password, \(updateSavedLoginHint(account))."
        alert.runModal()
    }

    /// Which games are running, by their processes: a Mac game's run its
    /// app's executable, a Windows game's are found by `WineProcesses`.
    /// `processes`: the list from `RunningProcesses.executables()` to go by;
    /// nil reads it now.
    private func refreshRunning(processes: [(pid: pid_t, path: String)]? = nil) {
        runningShown += 1
        // One read of the process list serves every game. Launch Services
        // knows the running apps too, but telling where each one is costs a
        // round trip per app, on every return to Waypoint.
        let processes = processes ?? RunningProcesses.executables()
        let windowsGames = discoveredGames.filter {
            $0.install.platform == .windows && WindowsTitle.forInstall($0.install)?.isEnabled == true
        }
        var windowsProcesses: [String: [Int32]] = [:]
        for game in windowsGames {
            guard let title = WindowsTitle.forInstall(game.install) else { continue }
            windowsProcesses[game.id] = WineProcesses.gameAndLaunchers(
                in: URL(fileURLWithPath: game.install.installPath), title: title, processes: processes)
        }
        running = Set(discoveredGames.filter { game in
            if game.install.platform == .windows { return windowsProcesses[game.id]?.isEmpty == false }
            guard let app = game.appURL else { return false }
            return RunningProcesses.isRunning(bundle: app, in: processes)
        }.map(\.id)).union(windowsSessions.keys)
        for game in windowsGames {
            for pid in windowsProcesses[game.id] ?? [] { observeWindowsExit(pid: pid, game: game) }
        }
    }

    private func observeWindowsExit(pid: Int32, game: Game) {
        guard windowsObservers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.windowsObservers.removeValue(forKey: pid)?.cancel()
                if let session = self.windowsSessions[game.id] {
                    Task {
                        let survivors = await session.gameExited()
                        if survivors.isEmpty {
                            if self.windowsSessions[game.id] === session { self.windowsSessions.removeValue(forKey: game.id) }
                        } else {
                            for survivor in survivors { self.observeWindowsExit(pid: survivor, game: game) }
                        }
                        self.refreshRunning()
                    }
                } else {
                    Task { await WindowsRuntime.cleanupAfterExit(install: game.install) }
                }
                self.refreshRunning()
            }
        }
        windowsObservers[pid] = source
        source.activate()
    }

    /// A loose Wine executable has no app bundle for Launch Services to
    /// activate. Reveal the GUI after this Play action while Waypoint still
    /// owns focus; switching to another app cancels the request.
    private func revealWindowsGame(_ game: Game) async {
        guard let title = WindowsTitle.forInstall(game.install), title.isEnabled else { return }
        let root = URL(fileURLWithPath: game.install.installPath)
        for _ in 0..<120 {
            guard windowsSessions[game.id] != nil, NSApp.isActive, !Task.isCancelled else { return }
            if let pid = WineProcesses.gameCore(in: root, title: title).first,
               let app = NSRunningApplication(processIdentifier: pid),
               app.isFinishedLaunching, app.activationPolicy == .regular {
                app.activate(options: [.activateAllWindows])
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private enum WindowsWindowWait: String { case created, exited, stalled }

    private func waitForWindowsWindow(_ game: Game, title: WindowsTitle) async -> WindowsWindowWait {
        let root = URL(fileURLWithPath: game.install.installPath)
        var seenProcess = false
        for attempt in 0..<180 {
            guard !Task.isCancelled else { return .stalled }
            if hasWindowsWindow(game, title: title) { return .created }
            if WineProcesses.gameAndLaunchers(in: root, title: title).isEmpty {
                if seenProcess || attempt >= 30 { return .exited }
            } else { seenProcess = true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .stalled
    }

    private func hasWindowsWindow(_ game: Game, title: WindowsTitle) -> Bool {
        let pids = Set(WineProcesses.gameCore(in: URL(fileURLWithPath: game.install.installPath), title: title))
        guard !pids.isEmpty else { return false }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
            // Fullscreen Wine windows can be floating or shielding level.
            return width > 1 && height > 1
        }
    }

    private func watchForLateWindowsWindow(_ game: Game, title: WindowsTitle, session: WindowsGameSession) {
        Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    guard self.windowsSessions[game.id] === session else { return }
                    guard case .failed = self.phases[game.id] else { return }
                    if self.hasWindowsWindow(game, title: title) {
                        self.phases[game.id] = .idle
                        Log.info(.launch, "window_created_late", nil, ["uid": game.id])
                        return
                    }
                } else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Apple's component has separate terms. Keep consent local and keyed to
    /// the actual license bytes, shared by games that use the same component.
    private func acceptGraphicsLicense(for title: WindowsTitle?) -> Bool {
        guard title?.backend == .d3dMetal else { return true }
        guard let data = try? WindowsGraphics.licenseData(),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else {
            let alert = NSAlert()
            alert.messageText = "Graphics component unavailable"
            alert.informativeText = "The graphics license could not be verified. Reinstall or update Waypoint before trying again."
            alert.runModal()
            return false
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "acceptedWindowsGraphicsLicense"
        if UserDefaults.standard.string(forKey: key) == hash { return true }
        let alert = NSAlert()
        alert.messageText = "Apple graphics components"
        alert.informativeText = "\(title!.displayName) uses Apple's D3DMetal graphics component, provided under the license below. Review the terms before continuing."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 250))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Agree and Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(hash, forKey: key)
        return true
    }
}
