import Foundation
import WaypointCore

func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func game(_ uid: String) -> Game {
    guard let game = GameLibrary().games().first(where: { $0.install.uid == uid }) else { fail("no game with uid \(uid)") }
    return game
}

func checkUpdates() async {
    for game in GameLibrary().games() where game.family != .other {
        do {
            let check = try await GameUpdater(install: game.install).check()
            let state = check.isUpdateAvailable ? "UPDATE → \(check.latest.name)" : "up to date"
            print("\(game.install.uid): installed \(game.install.version ?? "?"), latest \(check.latest.name) — \(state)")
        } catch {
            print("\(game.install.uid): \(error)")
        }
    }
}

/// `update <uid> [--verify] [--dry-run]`
func update(_ args: [String]) async {
    guard let uid = args.first(where: { !$0.hasPrefix("--") }) else { fail("usage: waypoint-cli update <uid> [--verify] [--dry-run]") }
    let updater = GameUpdater(install: game(uid).install)
    do {
        let plan = try await updater.plan(verify: args.contains("--verify"), log: log)
        print("target: \(plan.target.name)")
        print("download: \(plan.files.count) files, \(byteString(plan.downloadSize))")
        print("delete: \(plan.deletions.count) files")
        for file in plan.files.prefix(10) { print("  + \(file.path) (\(byteString(file.size)))") }
        for path in plan.deletions.prefix(10) { print("  - \(path)") }
        guard !args.contains("--dry-run"), !plan.isEmpty else { return }
        try await updater.apply(plan) { p in
            log(String(format: "%.1f%%  %@ / %@  (%d/%d files)", p.fraction * 100,
                       byteString(p.completedBytes), byteString(p.totalBytes), p.completedFiles, p.totalFiles))
        }
        print("installed \(plan.target.name)")
    } catch {
        fail("\(error)")
    }
}

/// `fetch <uid> <regex> <dir>`: downloads matching files of the live build
/// into an empty folder. Tests the download path without touching the game.
func fetch(_ args: [String]) async {
    guard args.count == 3 else { fail("usage: waypoint-cli fetch <uid> <regex> <dir>") }
    var install = game(args[0]).install
    install.installPath = URL(fileURLWithPath: args[2]).standardizedFileURL.path
    install.buildConfig = nil
    let pattern = args[1]
    guard (try? Regex(pattern)) != nil else { fail("bad regex") }
    let updater = GameUpdater(install: install, store: InstallStateStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-fetch-state.json")))
    do {
        try FileManager.default.createDirectory(atPath: install.installPath, withIntermediateDirectories: true)
        let plan = try await updater.plan(only: { path in (try? Regex(pattern)).map { path.contains($0) } ?? false }, log: log)
        print("fetching \(plan.files.count) files, \(byteString(plan.downloadSize)); in archives: \(plan.files.filter { $0.location != nil }.count)")
        try await updater.apply(plan)
        print("done")
    } catch {
        fail("\(error)")
    }
}
