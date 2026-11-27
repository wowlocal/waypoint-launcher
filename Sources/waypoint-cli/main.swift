import Foundation
import WaypointCore

let args = Array(CommandLine.arguments.dropFirst())
if args.first != "logs" {
    Log.info(.cli, "command", nil, ["args": args.joined(separator: " ")])
}

func fail(_ message: String) -> Never {
    Log.error(.cli, "failed", message)
    Diagnostics.shared.flush()
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

case "check-updates":
    await refreshCatalog()
    await checkUpdates()

case "update":
    await refreshCatalog()
    await update(Array(args.dropFirst()))

case "cleanup":
    await refreshCatalog()
    await cleanup(Array(args.dropFirst()))

case "fetch":
    await fetch(Array(args.dropFirst()))

case "install":
    await refreshCatalog()
    await install(Array(args.dropFirst()))

case "catalog":
    await refreshCatalog(force: args.contains("--refresh"))
    for product in InstallableProduct.available(for: catalogRegion()) {
        print("\(product.uid)  \(product.productCode)  \(product.displayName)  [\(product.supportedPlatforms.map(\.rawValue).sorted().joined(separator: ","))]")
    }

case "logs":
    await logs(Array(args.dropFirst()))

case "launch":
    launch(Array(args.dropFirst()))

case "repair-install-metadata":
    do { print("Restored \(try BattleNetInstallMetadata.repair()) metadata records") }
    catch { fail("\(error)") }

case "diagnose":
    diagnose()

case "storage-check":
    // `storage-check <Data/data> [--repair]`: what the game checks before
    // reading a local storage (issue #19); `--repair` fixes what it can prove.
    let rest = Array(args.dropFirst())
    guard let path = rest.first(where: { !$0.hasPrefix("--") }) else { fail("usage: waypoint-cli storage-check <Data/data> [--repair]") }
    let dir = URL(fileURLWithPath: path)
    do {
        func show(_ r: CASC.StructureReport) {
            for (k, v) in r.logFields.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
            for e in (r.outOfBounds + r.displaced).prefix(20) {
                print("  entry \(e.key.hex) archive \(e.archive) offset \(e.offset) size \(e.size)")
            }
        }
        if rest.contains("--repair") {
            // Like the app: never while the game or Battle.net may be writing.
            let root = dir.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
            guard RunningProcesses.inside(root).isEmpty else { fail("\(UpdateError.gameRunning)") }
            try BattleNet.ensureNotRunning()
            let repair = try CASC.repairStructure(dir)
            print("before:"); show(repair.before)
            print("rebuilt header slots \(repair.rebuiltHeaderSlots), indexed header slots \(repair.indexedHeaderSlots), dropped entries \(repair.droppedEntries)")
            print("after:"); show(repair.after)
        } else {
            let report = try CASC.inspectStructure(dir, checkOverlaps: true)
            print(report.isDamaged ? "DAMAGED" : (report.isEmpty ? "sound" : "sound (with notes)")); show(report)
        }
    } catch { fail("\(error)") }

default:
    fail("usage: waypoint-cli [list | catalog [--refresh] | plan <uid> | check-tokens [GAMEKEY…] | check-updates | update <uid> [--path root] [--state file] [--verify] [--language xxXX [--speech xxXX]] [--dry-run] | cleanup <uid> [--path root] [--state file] [--dry-run [--without product]] | fetch <uid> <regex> <dir> | install <uid> <dir> [options] | launch <uid> [--state file] [--dry-run] | logs [options] | repair-install-metadata | diagnose | storage-check <Data/data> [--repair]]")
}

Diagnostics.shared.flush()
