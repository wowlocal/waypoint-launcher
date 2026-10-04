import AppKit
import Observation
import WaypointCore

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case signingIn
        case launching
        case updating(UpdateProgress?)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.signingIn, .signingIn), (.launching, .launching), (.updating, .updating): true
            case (.failed(let x), .failed(let y)): x == y
            default: false
            }
        }
    }

    private(set) var games: [Game] = []
    /// Game uid -> phase, so each row shows its own progress.
    private(set) var phases: [String: Phase] = [:]
    private(set) var running: Set<String> = []
    /// Game uid -> result of the last update check.
    private(set) var updates: [String: UpdateCheck] = [:]
    private var lastUpdateCheck: Date?

    /// nil = use the region each game was installed for.
    var regionOverride: Region? {
        didSet { UserDefaults.standard.set(regionOverride?.rawValue, forKey: "regionOverride") }
    }

    /// Saved Battle.net accounts, each with its own web session and last
    /// tokens, so switching between them needs no sign-in.
    private var accountList = AccountList.load() {
        didSet { accountList.save() }
    }
    var accounts: [Account] { accountList.accounts }
    /// The account games launch with.
    var activeAccount: Account? { accountList.active }
    /// The login window is open to add an account.
    private(set) var isAddingAccount = false
    private var profileFetches: Set<String> = []

    private let library = GameLibrary()
    private let silentFetcher = SilentTokenFetcher()
    private let loginWindow = LoginWindow()
    /// Per bundle id, like the web sessions, so test builds never share
    /// keychain items with the installed app.
    private let tokenVault = TokenVault(service: "\(Bundle.main.bundleIdentifier ?? "Waypoint"): Battle.net login tokens")
    private var observers: [NSObjectProtocol] = []

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
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        // Coming back to Waypoint picks up games installed or removed
        // meanwhile, and checks for updates (throttled).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                _ = Task { await self?.checkForUpdates() }
            }
        })
        Task { await checkForUpdates(force: true) }
        Task { await setUpAccounts() }
    }

    func reload() {
        games = library.games()
        refreshRunning()
        Log.info(.library, "scanned", nil, ["games": games.map { "\($0.install.uid)@\($0.install.version ?? "?")" }.joined(separator: ",")])
    }

    // MARK: Updates

    func availableUpdate(for game: Game) -> UpdateCheck? {
        guard let check = updates[game.id], check.isUpdateAvailable else { return nil }
        return check
    }

    func canUpdate(_ game: Game) -> Bool {
        GameUpdate.canUpdate(game.install) && game.appURL != nil && !running.contains(game.id) && !isBusy(game)
    }

    /// Asks Blizzard's version service which build is live. Cheap (one small
    /// request per game), throttled to every 15 minutes unless forced.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 15 * 60 { return }
        lastUpdateCheck = Date()
        for game in games where (game.family != .other || GameUpdate.canUpdate(game.install)) && game.appURL != nil {
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
        guard canUpdate(game) else { return }
        defer { ProcessMemory.releaseFreed() }
        Log.info(.gameUpdate, "requested", nil, ["uid": game.id, "verify": verify])
        phases[game.id] = .updating(nil)
        do {
            let updater = GameUpdate(install: game.install)
            let plan = try await updater.plan(target: updates[game.id]?.latest, verify: verify)
            // A CASC game's new build can need no new files and still have to
            // be recorded (configs, .build.info).
            if !plan.isEmpty || plan.target.buildConfig != game.install.buildConfig {
                try await updater.apply(plan) { [weak self] progress in
                    Task { @MainActor in
                        if case .updating = self?.phases[game.id] { self?.phases[game.id] = .updating(progress) }
                    }
                }
            }
            reload()
            await checkForUpdates(force: true)
            phases[game.id] = .idle
        } catch {
            Log.error(.gameUpdate, "failed", nil, ["uid": game.id, "error": error])
            phases[game.id] = .failed(String(describing: error))
        }
    }

    // MARK: Installs

    /// Games Waypoint can install that aren't installed yet.
    var installable: [InstallableProduct] {
        InstallableProduct.all.filter { product in !games.contains { $0.install.uid == product.uid } }
    }

    func phase(of product: InstallableProduct) -> Phase { phases[product.uid] ?? .idle }

    /// What a fresh install would download, for the install sheet.
    func installSize(_ product: InstallableProduct, folder: URL, region: Region, language: String) async throws -> UInt64 {
        defer { ProcessMemory.releaseFreed() }
        return try await GameInstaller(product: product, folder: folder, region: region, language: language).plan().downloadSize
    }

    func install(_ product: InstallableProduct, folder: URL, region: Region, language: String) async {
        defer { ProcessMemory.releaseFreed() }
        guard !isBusy(uid: product.uid) else { return }
        Log.notice(.install, "requested", nil, ["uid": product.uid, "path": folder.path, "region": region.rawValue, "language": language])
        phases[product.uid] = .updating(nil)
        do {
            let installer = GameInstaller(product: product, folder: folder, region: region, language: language)
            let plan = try await installer.plan()
            try await installer.apply(plan) { [weak self] progress in
                Task { @MainActor in
                    if case .updating = self?.phases[product.uid] { self?.phases[product.uid] = .updating(progress) }
                }
            }
            Log.notice(.install, "finished", nil, ["uid": product.uid, "version": plan.version, "path": folder.path])
            phases[product.uid] = .idle
            reload()
            await checkForUpdates(force: true)
        } catch {
            Log.error(.install, "failed", nil, ["uid": product.uid, "path": folder.path, "error": error])
            phases[product.uid] = .failed(String(describing: error))
        }
    }

    private func isBusy(uid: String) -> Bool {
        switch phases[uid] ?? .idle {
        case .signingIn, .launching, .updating: true
        default: false
        }
    }

    func phase(of game: Game) -> Phase { phases[game.id] ?? .idle }

    func isBusy(_ game: Game) -> Bool {
        switch phase(of: game) {
        case .signingIn, .launching, .updating: true
        default: false
        }
    }

    /// Only one sign-in at a time: the login window and the hidden web view
    /// each serve a single request.
    var isSigningIn: Bool { isAddingAccount || phases.values.contains(.signingIn) }

    func canPlay(_ game: Game) -> Bool {
        game.isSupported && !running.contains(game.id) && !isBusy(game) && !isSigningIn
    }

    /// `forceSignIn` skips the saved session and token, for when the game
    /// rejects them or the user wants another account.
    func play(_ game: Game, forceSignIn: Bool = false) async {
        guard canPlay(game) else { return }
        Log.info(.launch, "requested", nil, ["uid": game.id, "version": game.install.version ?? "?", "force_sign_in": forceSignIn])
        do {
            let plan = try GameLauncher.plan(for: game, region: regionOverride)
            phases[game.id] = .signingIn
            guard let token = await token(for: plan, gameName: game.displayName, forceSignIn: forceSignIn) else {
                Log.notice(.auth, "sign_in_cancelled", nil, ["uid": game.id])
                phases[game.id] = .idle
                return
            }
            phases[game.id] = .launching
            try GameLauncher.launch(plan, token: token, gameName: game.displayName)
            // Keep "launching" until the game shows up in the running list.
            try? await Task.sleep(for: .seconds(4))
            refreshRunning()
            Log.info(.launch, "running_check", nil, ["uid": game.id, "running": running.contains(game.id)])
            phases[game.id] = .idle
        } catch {
            Log.error(.launch, "failed", nil, ["uid": game.id, "error": error])
            phases[game.id] = .failed(String(describing: error))
        }
    }

    // MARK: Accounts

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
        guard !isSigningIn else { return }
        isAddingAccount = true
        defer { isAddingAccount = false }
        let target = loginTarget()
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": target.codename, "region": target.region.rawValue, "reason": "add_account"])
        guard let token = await loginWindow.run(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                title: "Add a Battle.net Account", session: session)
        else {
            Log.notice(.auth, "sign_in_cancelled", nil, ["reason": "add_account"])
            await WebSession.delete(session)
            return
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": target.codename])
        await adopt(token, codename: target.codename, session: session)
    }

    /// Signs the active account out: its web session and saved tokens are
    /// deleted, and the next saved account, if any, becomes active.
    func signOut() async {
        guard let account = activeAccount else { return }
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
        let token = await SilentTokenFetcher().fetch(BattleNetLogin.url(codename: target.codename, region: target.region),
                                                     session: .shared)
        // Someone may have signed in meanwhile.
        guard let token, accounts.isEmpty else { return }
        Log.info(.auth, "token", nil, ["source": "web_session", "codename": target.codename, "reason": "adopt"])
        await adopt(token, codename: target.codename, session: .shared)
    }

    /// The login page asks which game it signs in to (`app=`): the first
    /// game that can be played, else Hearthstone, which every account has.
    private func loginTarget() -> (codename: String, region: Region) {
        let plan = games.lazy.compactMap { try? GameLauncher.plan(for: $0, region: self.regionOverride) }.first
        return (plan?.codename ?? InstallableProduct.hearthstone.codename, plan?.region ?? regionOverride ?? .us)
    }

    /// Remembers who signed in where: that account, new or saved, becomes
    /// active and keeps the token for next time. A session it no longer uses
    /// is deleted.
    private func adopt(_ token: LoginToken, codename: String, session: WebSessionID) async {
        let id = token.accountID
        let isNew = accountList[id] == nil
        let unused = accountList.signedIn(id, session: session)
        do {
            try tokenVault.save(token, codename: codename)
        } catch {
            Log.warning(.auth, "token_save_failed", nil, ["error": error])
        }
        if isNew { Log.notice(.auth, "account_added", nil, ["accounts": accounts.count]) }
        if let unused { await WebSession.delete(unused) }
        if accountList[id]?.battleTag == nil { Task { await refreshProfile(id) } }
    }

    /// Looks up the account's BattleTag and email on Blizzard's account page.
    private func refreshProfile(_ id: String) async {
        guard let account = accountList[id], profileFetches.insert(id).inserted else { return }
        defer { profileFetches.remove(id) }
        switch await ProfileFetcher().fetch(session: account.session) {
        case .signedIn(let profile):
            if let other = profile.accountID, other != id { Log.warning(.auth, "profile_other_account") }
            accountList.setProfile(id, battleTag: profile.battleTag, email: profile.email)
            Log.info(.auth, "profile", nil, ["battletag": profile.battleTag != nil, "email": profile.email != nil])
        case .signedOut:
            Log.info(.auth, "profile_signed_out")
        case .failed:
            Log.info(.auth, "profile_failed")
        }
    }

    /// Prefers a fresh token, like Battle.net: silently from the active
    /// account's web session. Battle.net's session cookie doesn't always
    /// survive a restart, so next we reuse the account's token from its last
    /// launch (tokens last for months), kept in the keychain, or the one
    /// Battle.net left in `net.battle`. Only if none of that works do we show
    /// the login window, and whoever signs in there becomes the active account.
    private func token(for plan: LaunchPlan, gameName: String, forceSignIn: Bool) async -> LoginToken? {
        // Only where the token came from is logged, never the token.
        let url = BattleNetLogin.url(codename: plan.codename, region: plan.region)
        if !forceSignIn {
            let account = activeAccount
            // With no accounts yet, try the session from before there were any.
            let session = account?.session ?? .shared
            let started = Date()
            if await WebSession.hasCookies(session), let token = await silentFetcher.fetch(url, session: session) {
                Log.info(.auth, "token", nil, ["source": "web_session", "codename": plan.codename,
                                               "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
                await adopt(token, codename: plan.codename, session: session)
                return token
            }
            let stored = (try? LaunchOptions(gameKey: plan.codename).storedToken()).flatMap { LoginToken($0) }
            if let account {
                if let token = tokenVault.token(account: account.id, codename: plan.codename) {
                    Log.info(.auth, "token", nil, ["source": "keychain", "codename": plan.codename])
                    return token
                }
                if let stored, stored.accountID == account.id {
                    Log.info(.auth, "token", nil, ["source": "stored", "codename": plan.codename])
                    return stored
                }
            } else if let stored {
                Log.info(.auth, "token", nil, ["source": "stored", "codename": plan.codename])
                await adopt(stored, codename: plan.codename, session: .shared)
                return stored
            }
        }
        let session = WebSessionID.fresh()
        Log.notice(.auth, "login_window_shown", nil, ["codename": plan.codename, "region": plan.region.rawValue, "forced": forceSignIn])
        guard let token = await loginWindow.run(url, title: "Sign in to play \(gameName)", session: session) else {
            await WebSession.delete(session)
            return nil
        }
        Log.info(.auth, "token", nil, ["source": "login_window", "codename": plan.codename])
        await adopt(token, codename: plan.codename, session: session)
        return token
    }

    private func refreshRunning() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL }
        running = Set(games.filter { game in
            guard let app = game.appURL?.standardizedFileURL else { return false }
            return runningApps.contains(app)
        }.map(\.id))
    }
}
