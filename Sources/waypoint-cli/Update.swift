import Foundation
import WaypointCore

func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func catalogRegion() -> Region {
    option("--region", in: Array(CommandLine.arguments)).flatMap(Region.init(rawValue:))
        ?? Region.preferred(games: GameLibrary().games())
}

func refreshCatalog(force: Bool = false) async {
    let region = catalogRegion()
    do { try await ProductCatalog.shared.refresh(region: region, force: force) }
    catch { log("Catalog refresh failed; using saved games: \(error)") }
}

func game(_ uid: String) -> Game {
    guard let game = GameLibrary().games().first(where: { $0.install.uid == uid }) else { fail("no game with uid \(uid)") }
    return game
}

func checkUpdates() async {
    for game in GameLibrary().games() where game.family != .other || GameUpdate.canUpdate(game.install) {
        do {
            let check = try await GameUpdate(install: game.install).check()
            let state = check.isUpdateAvailable ? "UPDATE → \(check.latest.name)" : "up to date"
            print("\(game.install.uid): installed \(game.install.version ?? "?"), latest \(check.latest.name) — \(state)")
        } catch {
            print("\(game.install.uid): \(error)")
        }
    }
}

/// Value of `--name value` in an argument list.
func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func stateStore(_ args: [String]) -> InstallStateStore {
    option("--state", in: args).map { InstallStateStore(file: URL(fileURLWithPath: $0)) } ?? InstallStateStore()
}

/// The install a command names: `<uid>`, optionally `--path` for a specific
/// copy (e.g. a test install next to Battle.net's own) and `--state`.
func resolveInstall(_ args: [String], usage: String) -> (ProductInstall, InstallStateStore) {
    var positional: [String] = []
    var i = 0
    while i < args.count {
        if ["--path", "--state", "--language", "--speech"].contains(args[i]) { i += 2; continue }
        if !args[i].hasPrefix("--") { positional.append(args[i]) }
        i += 1
    }
    guard positional.count == 1 else { fail(usage) }
    let store = stateStore(args)
    let games = GameLibrary(stateStore: store).games().filter { $0.install.uid == positional[0] }
    if let path = option("--path", in: args) {
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        let recorded = store.load()[positional[0]].flatMap { $0.install(uid: positional[0]) }
        guard let match = ([recorded].compactMap { $0 } + games.map(\.install)).first(where: { resolved($0.installPath) == resolved(path) })
        else { fail("no \(positional[0]) install at \(path)") }
        return (store.apply(to: match), store)
    }
    guard let game = games.first else { fail("no game with uid \(positional[0])") }
    return (game.install, store)
}

/// `cleanup <uid> [--path root] [--state file] [--dry-run]`: removes from the
/// game's storage what no installed build needs, and gives the space back.
func cleanup(_ args: [String]) async {
    let (install, store) = resolveInstall(args, usage: "usage: waypoint-cli cleanup <uid> [--path install-root] [--state file] [--dry-run]")
    guard let product = InstallableProduct.forProduct(install.productCode) else { fail("\(install.productCode) has no local storage Waypoint knows") }
    let region = install.region.flatMap(Region.init(rawValue:)) ?? .us
    do {
        let config = try await VersionService().productConfig(product: install.productCode, region: region, platform: install.platform)
        guard !config.isContainerless else { fail("\(product.displayName) keeps no local storage") }
        let result = try await CASCInstaller(product: product, install: install, config: config, store: store)
            .cleanStorage(dryRun: args.contains("--dry-run"), log: log)
        print("\(args.contains("--dry-run") ? "would remove" : "removed") \(result.removedFiles) files (\(byteString(result.removedBytes)))"
              + (args.contains("--dry-run") ? "" : ", gave back \(byteString(result.reclaimedBytes)) of disk")
              + "; old CDN indexes: \(byteString(result.removedIndexBytes))")
    } catch {
        fail("\(error)")
    }
}

/// `update <uid> [--path root] [--state file] [--verify] [--language xxXX [--speech xxXX]] [--dry-run]`.
/// With `--language`, the game switches to that text language (and spoken
/// language: `--speech`, else the same).
func update(_ args: [String]) async {
    let usage = "usage: waypoint-cli update <uid> [--path install-root] [--state file] [--verify] [--language xxXX [--speech xxXX]] [--dry-run]"
    let (install, store) = resolveInstall(args, usage: usage)
    var languages: GameLanguages?
    if let text = option("--language", in: args) {
        languages = GameLanguages(text: text, speech: option("--speech", in: args))
    } else if option("--speech", in: args) != nil {
        fail(usage)
    }
    if let languages, let product = InstallableProduct.forProduct(install.productCode) {
        checkLanguages(languages, for: product)
    }
    let updater = GameUpdate(install: install, store: store)
    do {
        let plan = try await updater.plan(verify: args.contains("--verify"), languages: languages, log: log)
        let from = install.languages
        if let languages { print("languages: text \(from.text) → \(languages.text), speech \(from.speech) → \(languages.speech)") }
        print("target: \(plan.target.name)")
        print("download: \(plan.fileCount) files, \(byteString(plan.downloadSize))")
        print("delete: \(plan.deletions.count) files")
        if case .loose(let p) = plan {
            for file in p.files.prefix(10) { print("  + \(file.path) (\(byteString(file.size)))") }
        } else if case .casc(let p) = plan {
            print("  storage: \(p.storage.count) files, \(byteString(p.storage.reduce(0) { $0 + $1.size }))")
            for file in p.loose.files.prefix(10) { print("  + \(file.path) (\(byteString(file.size)))") }
        }
        for path in plan.deletions.prefix(10) { print("  - \(path)") }
        guard !args.contains("--dry-run") else { return }
        guard !plan.isEmpty || plan.target.buildConfig != install.buildConfig || (languages != nil && languages != from) else {
            // Nothing to download: index files an older Waypoint left too
            // short for the game's update section still get their room back.
            let repair = try updater.repairIndexes(plan)
            if !repair.isEmpty {
                print("repaired \(repair.repaired.count) index files")
            }
            return
        }
        try await updater.apply(plan) { p in
            log(String(format: "%.1f%%  %@ / %@  (%d/%d files)", p.fraction * 100,
                       byteString(p.completedBytes), byteString(p.totalBytes), p.completedFiles, p.totalFiles))
        }
        print("installed \(plan.target.name)")
    } catch {
        fail("\(error)")
    }
}

func checkLanguages(_ languages: GameLanguages, for product: InstallableProduct) {
    if let unknown = [languages.text, languages.speech].first(where: { !product.languages.contains($0) }) {
        fail("\(product.displayName) has no \(unknown); pick one of \(product.languages.joined(separator: " "))")
    }
    if languages.speech != languages.text, !product.hasSpokenLanguage {
        fail("\(product.displayName) has no separate spoken language: a second one would only add its files")
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

/// `install <uid> <dir> [--language xxXX] [--speech xxXX] [--region eu] [--only regex] [--dry-run] [--state file]`:
/// installs a game from scratch into `<dir>` (its install root, e.g. /Applications/World of Warcraft).
func install(_ args: [String]) async {
    let usage = "usage: waypoint-cli install <uid> <dir> [--platform mac|win] [--language enUS] [--speech enUS] [--region eu|us|kr|cn] [--only regex] [--dry-run] [--state file]"
        + "\n  uids: " + InstallableProduct.all.map(\.uid).joined(separator: " ")
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 0
    while i < args.count {
        if ["--platform", "--language", "--speech", "--region", "--only", "--state", "--dump-keys"].contains(args[i]), i + 1 < args.count {
            options[args[i]] = args[i + 1]
            i += 2
            continue
        }
        if args[i].hasPrefix("--") { flags.insert(args[i]) } else { positional.append(args[i]) }
        i += 1
    }
    guard let region = options["--region"].map({ Region(rawValue: $0) }) ?? Region.preferred(games: GameLibrary().games()) else { fail(usage) }
    guard positional.count == 2,
          let product = InstallableProduct.available(for: region).first(where: { $0.uid == positional[0] || $0.productCode == positional[0] })
    else { fail(usage) }
    guard let platform = options["--platform"].map({ InstallPlatform(rawValue: $0) })
            ?? (product.supportedPlatforms == [.windows] ? .windows : .macOS) else { fail(usage) }
    let languages = GameLanguages(text: options["--language"] ?? product.defaultLanguage(), speech: options["--speech"])
    checkLanguages(languages, for: product)
    let pattern = options["--only"]
    if let pattern, (try? NSRegularExpression(pattern: pattern)) == nil { fail("bad regex") }

    let store = options["--state"].map { InstallStateStore(file: URL(fileURLWithPath: $0)) } ?? InstallStateStore()
    let installer = GameInstaller(product: product, folder: URL(fileURLWithPath: positional[1]).standardizedFileURL,
                                  region: region, languages: languages, store: store, platform: platform)
    print("\(product.displayName) → \(installer.folder.path) (\(region.displayName), text \(languages.text), speech \(languages.speech))")
    do {
        var only: (@Sendable (String) -> Bool)?
        if let pattern {
            only = { path in path.range(of: pattern, options: .regularExpression) != nil }
        }
        let plan = try await installer.plan(only: only, log: log)
        switch plan {
        case .loose(let p):
            print("version \(p.target.name): \(p.files.count) files, \(byteString(p.downloadSize))")
        case .casc(let p):
            print("version \(p.target.name): \(p.storage.count) files into \(p.config.dataDirectory)data "
                  + "(\(byteString(p.storage.reduce(0) { $0 + $1.size }))), \(p.loose.files.count) loose files "
                  + "(\(byteString(p.loose.downloadSize))); \(p.storage.filter { !$0.isInArchive }.count) outside archives")
            if p.storedBytes > 0 {
                print("already downloaded \(byteString(p.storedBytes)); \(byteString(p.downloadSize)) left")
            }
        }
        // Debugging aid: the encoded keys a CASC install would store, one hex per line.
        if let dump = options["--dump-keys"], case .casc(let p) = plan {
            try p.storage.map { $0.encodedKey.hex + ($0.fullKey ? " full" : "") }.joined(separator: "\n")
                .write(toFile: dump, atomically: true, encoding: .utf8)
        }
        guard !flags.contains("--dry-run") else { return }
        let started = Date()
        try await installer.apply(plan) { p in
            log(String(format: "%.1f%%  %@ / %@", p.fraction * 100, byteString(p.completedBytes), byteString(p.totalBytes)))
        }
        print("installed \(plan.version) in \(Int(Date().timeIntervalSince(started)))s")
    } catch {
        fail("\(error)")
    }
}
