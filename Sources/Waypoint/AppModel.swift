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

    private let library = GameLibrary()
    private let silentFetcher = SilentTokenFetcher()
    private let loginWindow = LoginWindow()
    private var observers: [NSObjectProtocol] = []

    init() {
        regionOverride = UserDefaults.standard.string(forKey: "regionOverride").flatMap(Region.init(rawValue:))
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.checkForUpdates() } }
        })
        Task { await checkForUpdates(force: true) }
    }

    func reload() {
        games = library.games()
        refreshRunning()
    }

    // MARK: Updates

    func availableUpdate(for game: Game) -> UpdateCheck? {
        guard let check = updates[game.id], check.isUpdateAvailable else { return nil }
        return check
    }

    func canUpdate(_ game: Game) -> Bool {
        GameUpdater.canUpdate(game.family) && game.appURL != nil && !running.contains(game.id) && !isBusy(game)
    }

    /// Asks Blizzard's version service which build is live. Cheap (one small
    /// request per game), throttled to every 15 minutes unless forced.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 15 * 60 { return }
        lastUpdateCheck = Date()
        for game in games where game.family != .other && game.appURL != nil {
            if let check = try? await GameUpdater(install: game.install).check() {
                updates[game.id] = check
            }
        }
    }

    /// Downloads and installs the latest build; with `verify`, re-checks
    /// every file and repairs what's broken.
    func update(_ game: Game, verify: Bool = false) async {
        guard canUpdate(game) else { return }
        phases[game.id] = .updating(nil)
        do {
            let updater = GameUpdater(install: game.install)
            let plan = try await updater.plan(target: updates[game.id]?.latest, verify: verify)
            if !plan.isEmpty {
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
            phases[game.id] = .failed(String(describing: error))
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
    var isSigningIn: Bool { phases.values.contains(.signingIn) }

    func canPlay(_ game: Game) -> Bool {
        game.isSupported && !running.contains(game.id) && !isBusy(game) && !isSigningIn
    }

    /// `forceSignIn` skips the saved session and token, for when the game
    /// rejects them or the user wants another account.
    func play(_ game: Game, forceSignIn: Bool = false) async {
        guard canPlay(game) else { return }
        do {
            let plan = try GameLauncher.plan(for: game, region: regionOverride)
            phases[game.id] = .signingIn
            guard let token = await token(for: plan, gameName: game.displayName, forceSignIn: forceSignIn) else {
                phases[game.id] = .idle
                return
            }
            phases[game.id] = .launching
            try GameLauncher.launch(plan, token: token, gameName: game.displayName)
            // Keep "launching" until the game shows up in the running list.
            try? await Task.sleep(for: .seconds(4))
            refreshRunning()
            phases[game.id] = .idle
        } catch {
            phases[game.id] = .failed(String(describing: error))
        }
    }

    func signOut() async {
        await WebSession.signOut()
        for codename in ["WTCG", "WoW"] {
            LaunchOptions(gameKey: codename).clearToken()
        }
    }

    /// Prefers a fresh token, like Battle.net: silently from the saved web
    /// session. Battle.net's session cookie doesn't always survive a restart,
    /// so next we reuse the token from the last launch (it stays in
    /// `net.battle`, where Battle.net keeps it too, and lasts for months).
    /// Only if neither works do we show the login window.
    private func token(for plan: LaunchPlan, gameName: String, forceSignIn: Bool) async -> LoginToken? {
        let url = BattleNetLogin.url(codename: plan.codename, region: plan.region)
        if !forceSignIn {
            if let token = await silentFetcher.fetch(url) { return token }
            if let stored = try? LaunchOptions(gameKey: plan.codename).storedToken(),
               let token = LoginToken(stored) {
                return token
            }
        }
        return await loginWindow.run(url, title: "Sign in to play \(gameName)")
    }

    private func refreshRunning() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL }
        running = Set(games.filter { game in
            guard let app = game.appURL?.standardizedFileURL else { return false }
            return runningApps.contains(app)
        }.map(\.id))
    }
}
