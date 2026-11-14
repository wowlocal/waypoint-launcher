import Foundation

/// Everything needed to start one game the way Battle.net would.
public struct LaunchPlan: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    /// `Launch Options/<key>/…` in the `net.battle` preferences, and the
    /// `app=` code for the web login. Battle.net calls this the game's codename.
    public var codename: String
    public var region: Region
    public var locale: String?
    /// WoW licence name for `GAME_ACCOUNT`; nil lets the game pick. Fill it
    /// in from `WoWAccountStore.launchAccount(for:uid:region:)` with the token
    /// actually being launched, so it can't belong to another account.
    public var gameAccount: String? = nil
    var windows: WindowsLaunchTarget? = nil
    public var isWindows: Bool { windows != nil }
}

public enum LaunchError: Error, CustomStringConvertible {
    case notInstalled(String)
    case intelOnly(String)
    case unsupported(String)
    case spawnFailed(String, Error)

    public var description: String {
        switch self {
        case .notInstalled(let name): "\(name): game files not found"
        case .intelOnly(let name): "\(name) only ships an Intel build and needs Rosetta"
        case .unsupported(let name): "\(name) is not supported yet"
        case .spawnFailed(let name, let error): "Could not start \(name): \(error.localizedDescription)"
        }
    }
}

public enum GameLauncher {
    public static func plan(for game: Game, region override: Region? = nil,
                            display: WindowsDisplay? = nil, windowsResources: URL? = WindowsRuntime.resources,
                            windowsBridge: URL? = WindowsRuntime.bridgeResources,
                            windowsGraphics: URL? = WindowsGraphics.resources) throws -> LaunchPlan {
        if game.install.platform == .windows {
            guard let title = WindowsTitle.forInstall(game.install), title.isEnabled else { throw LaunchError.unsupported(game.displayName) }
            guard game.isInstalled else { throw LaunchError.notInstalled(game.displayName) }
            guard Rosetta.isInstalled else { throw LaunchError.intelOnly(game.displayName) }
            guard let resources = windowsResources else { throw WindowsHeroes.Failure.unavailable }
            let root = URL(fileURLWithPath: game.install.installPath, isDirectory: true)
            return LaunchPlan(executable: resources.appendingPathComponent("wine/bin/wine"),
                arguments: [resources.appendingPathComponent("waypoint-launch-options.exe").path],
                workingDirectory: root, codename: title.codename,
                region: override ?? game.install.region.flatMap(Region.init(rawValue:)) ?? .us,
                locale: game.install.tagString.flatMap(TagLanguages.text(in:)) ?? game.install.textLanguage,
                windows: WindowsLaunchTarget(install: game.install, resources: resources, display: display,
                    bridgeResources: windowsBridge, graphicsResources: windowsGraphics))
        }
        guard let appURL = game.appURL else { throw LaunchError.notInstalled(game.displayName) }
        guard game.runsNatively || Rosetta.isInstalled else { throw LaunchError.intelOnly(game.displayName) }
        guard let product = InstallableProduct.forProduct(game.install.productCode), product.supportedPlatforms.contains(.macOS),
              let executable = Bundle(url: appURL)?.executableURL
        else { throw LaunchError.unsupported(game.displayName) }

        let region = override
            ?? game.install.region.flatMap(Region.init(rawValue:))
            ?? .us

        // Battle.net starts Hearthstone as `Hearthstone -launch -uid hs_beta`
        // from the install folder (observed with ps/lsof); `-launch` is the
        // product config's argument and stops the game from bouncing back to
        // the Battle.net app. Other games get their product config's
        // arguments plus `-uid` the same way. WoW gets `-launcherlogin -uid
        // <flavor>` (seen in Windows client crash logs) and runs from its
        // flavor folder.
        let root = URL(fileURLWithPath: game.install.installPath, isDirectory: true)
        let workingDirectory = product.flavorFolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root

        return LaunchPlan(
            executable: executable,
            arguments: product.launchArguments + ["-uid", game.install.uid],
            workingDirectory: workingDirectory,
            codename: product.codename,
            region: region,
            // Unknown: leave whatever Battle.net set.
            locale: game.install.tagString.flatMap(TagLanguages.text(in:)) ?? game.install.textLanguage
        )
    }

    /// Hands the token to the game and starts it. The game outlives us.
    @discardableResult
    public static func launch(_ plan: LaunchPlan, token: LoginToken, gameName: String) throws -> Int32 {
        guard !plan.isWindows else { throw LaunchError.unsupported("Launch Windows games from Waypoint") }
        let options = LaunchOptions(gameKey: plan.codename)
        try options.write(token: token.value, region: plan.region, locale: plan.locale, gameAccount: plan.gameAccount)
        var fields: [String: Any] = ["codename": plan.codename, "region": plan.region.rawValue, "locale": plan.locale ?? "-"]
        if options.usesGameAccount { fields["game_account"] = plan.gameAccount == nil ? "automatic" : "selected" }
        Log.info(.launch, "launch_options_written", nil, fields)

        do {
            let pid = try Spawn.detached(executable: plan.executable, arguments: plan.arguments,
                                         workingDirectory: plan.workingDirectory)
            Log.notice(.launch, "spawned", nil, ["game": gameName, "pid": pid, "executable": plan.executable.path,
                                                "args": plan.arguments.joined(separator: " "), "cwd": plan.workingDirectory.path])
            return pid
        } catch {
            Log.error(.launch, "spawn_failed", nil, ["game": gameName, "executable": plan.executable.path, "error": error])
            throw LaunchError.spawnFailed(gameName, error)
        }
    }

    public static func prepareWindows(_ plan: LaunchPlan,
                                      progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws -> WindowsGameSession? {
        guard let target = plan.windows else { return nil }
        let session = try WindowsGameSession(target: target)
        do { try await session.prepare(progress: progress) }
        catch { await session.preparationFailed(); throw error }
        return session
    }

    public static func launchWindows(_ plan: LaunchPlan, token: LoginToken,
                                     session: WindowsGameSession, gameName: String) async throws -> Int32 {
        guard let target = plan.windows, await session.matches(target) else { throw LaunchError.unsupported(gameName) }
        let pid = try await session.launch(token: token, region: plan.region, locale: plan.locale)
        Log.notice(.launch, "spawned", nil, ["game": gameName, "pid": pid, "platform": "windows", "backend": WindowsTitle.forInstall(target.install)?.backend.rawValue ?? "unknown"])
        return pid
    }
}

/// URLs for the Battle.net web login that hands out launch tokens.
public enum BattleNetLogin {
    public static func url(codename: String, region: Region) -> URL {
        let host = region == .cn ? "account.battlenet.com.cn" : "\(region.rawValue).battle.net"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/login/en/"
        components.queryItems = [
            URLQueryItem(name: "externalChallenge", value: "login"),
            URLQueryItem(name: "app", value: codename),
        ]
        return components.url!
    }

    /// The login page finishes by redirecting to `http://localhost:0/?ST=<token>&…`.
    public static func token(fromCallback url: URL) -> LoginToken? {
        guard url.host == "localhost" else { return nil }
        return LoginToken(callbackURL: url)
    }
}
