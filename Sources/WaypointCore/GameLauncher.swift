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
    public static func codename(for family: GameFamily) -> String? {
        switch family {
        case .hearthstone: "WTCG"
        // Every WoW flavor shares one entry; the flavor is picked with -uid.
        case .worldOfWarcraft: "WoW"
        case .other: nil
        }
    }

    public static func plan(for game: Game, region override: Region? = nil) throws -> LaunchPlan {
        guard let appURL = game.appURL else { throw LaunchError.notInstalled(game.displayName) }
        guard game.runsNatively else { throw LaunchError.intelOnly(game.displayName) }
        guard let codename = codename(for: game.family),
              let executable = Bundle(url: appURL)?.executableURL
        else { throw LaunchError.unsupported(game.displayName) }

        let region = override
            ?? game.install.region.flatMap(Region.init(rawValue:))
            ?? .us

        // Battle.net starts Hearthstone as `Hearthstone -launch -uid hs_beta`
        // from the install folder (observed with ps/lsof). `-launch` is what
        // stops the game from bouncing back to the Battle.net app.
        // For WoW it passes `-launcherlogin -uid <flavor>` (seen in client
        // crash logs on Windows; not yet observed on macOS).
        let arguments: [String]
        let workingDirectory: URL
        switch game.family {
        case .hearthstone:
            arguments = ["-launch", "-uid", game.install.uid]
            workingDirectory = URL(fileURLWithPath: game.install.installPath, isDirectory: true)
        case .worldOfWarcraft:
            arguments = ["-launcherlogin", "-uid", game.install.uid]
            workingDirectory = appURL.deletingLastPathComponent()
        case .other:
            throw LaunchError.unsupported(game.displayName)
        }

        return LaunchPlan(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            codename: codename,
            region: region,
            locale: game.install.textLanguage
        )
    }

    /// Hands the token to the game and starts it. The game outlives us.
    @discardableResult
    public static func launch(_ plan: LaunchPlan, token: LoginToken, gameName: String) throws -> Int32 {
        try LaunchOptions(gameKey: plan.codename).write(token: token.value, region: plan.region, locale: plan.locale)
        Log.info(.launch, "launch_options_written", nil, ["codename": plan.codename, "region": plan.region.rawValue, "locale": plan.locale ?? "-"])

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
