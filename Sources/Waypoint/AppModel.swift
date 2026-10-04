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
        case failed(String)
    }

    private(set) var games: [Game] = []
    /// Game uid -> phase, so each row shows its own progress.
    private(set) var phases: [String: Phase] = [:]
    private(set) var running: Set<String> = []

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
    }

    func reload() {
        games = library.games()
        refreshRunning()
    }

    func phase(of game: Game) -> Phase { phases[game.id] ?? .idle }

    func isBusy(_ game: Game) -> Bool {
        switch phase(of: game) {
        case .signingIn, .launching: true
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
