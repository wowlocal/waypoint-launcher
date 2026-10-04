import Foundation
import WaypointCore

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch args.first {
case "list", nil:
    for game in GameLibrary().games() {
        let archs = game.architectures.map(\.rawValue).sorted().joined(separator: "+")
        let status = game.isSupported ? "ok" : (game.appURL == nil ? "app not found" : (game.runsNatively ? "unsupported" : "x86 only"))
        print("\(game.install.uid.padding(toLength: 18, withPad: " ", startingAt: 0)) \(game.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(game.install.region ?? "-")  \(game.install.version ?? "-")  [\(archs.isEmpty ? "-" : archs)] \(status)")
    }

case "check-tokens":
    // Decrypts what Battle.net last wrote, to prove our cipher matches.
    // Prints only the token's shape, never the token.
    var tokens: [String: String] = [:]
    for key in args.dropFirst().isEmpty ? ["WTCG", "WoW", "W3", "Hero"] : Array(args.dropFirst()) {
        let options = LaunchOptions(gameKey: key)
        do {
            guard let token = try options.storedToken() else { print("\(key): no token"); continue }
            let parsed = LoginToken(token)
            tokens[key] = token
            print("\(key): decrypted, valid shape=\(parsed != nil), \(parsed?.redacted ?? "\(token.count) chars"), region=\(options.storedRegion() ?? "-"), locale=\(options.storedLocale() ?? "-")")
        } catch {
            print("\(key): decrypt failed: \(error)")
        }
    }
    let distinct = Set(tokens.values).count
    print("distinct tokens: \(distinct) of \(tokens.count)")

case "plan":
    // Dry run: shows how a game would be started, touches nothing.
    guard args.count == 2 else { fail("usage: waypoint-cli plan <uid>") }
    guard let game = GameLibrary().games().first(where: { $0.install.uid == args[1] }) else { fail("no game with uid \(args[1])") }
    do {
        let plan = try GameLauncher.plan(for: game)
        print("executable: \(plan.executable.path)")
        print("arguments:  \(plan.arguments.joined(separator: " "))")
        print("cwd:        \(plan.workingDirectory.path)")
        print("prefs:      net.battle \"Launch Options/\(plan.codename)/{WEB_TOKEN,REGION=\(plan.region.launchOptionValue)\(plan.locale.map { ",LOCALE=\($0)" } ?? "")}\"")
        print("login:      \(BattleNetLogin.url(codename: plan.codename, region: plan.region))")
    } catch {
        fail("\(error)")
    }

default:
    fail("usage: waypoint-cli [list | plan <uid> | check-tokens [GAMEKEY…]]")
}
