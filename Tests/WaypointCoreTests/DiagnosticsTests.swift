import Foundation
import Testing
@testable import WaypointCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-diag-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func writesOneStructuredJSONObjectPerLine() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Diagnostics(directory: dir, processName: "test")
    log.log(.info, .gameUpdate, "plan_ready", nil, ["files": 3, "bytes": UInt64(44_912_000), "verify": false, "path": URL(fileURLWithPath: "/x")])
    log.log(.error, .cdn, "all_mirrors_failed", "boom", ["error": TACTError.notFound("thing")])
    log.flush()

    let lines = try String(contentsOf: dir.appendingPathComponent("test.jsonl"), encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(first["event"] as? String == "plan_ready")
    #expect(first["category"] as? String == "game_update")
    #expect(first["process"] as? String == "test")
    let fields = try #require(first["fields"] as? [String: Any])
    #expect(fields["files"] as? Int == 3)
    #expect(fields["bytes"] as? Int == 44_912_000)
    #expect(fields["verify"] as? Bool == false)
    #expect(fields["path"] as? String == "/x")

    let events = log.events()
    #expect(events.map(\.event) == ["plan_ready", "all_mirrors_failed"])
    #expect(log.events(minimumLevel: .warning).map(\.event) == ["all_mirrors_failed"])
    #expect(events[1].message == "boom")
}

@Test func debugEventsNeedVerbose() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Diagnostics(directory: dir, processName: "test")
    log.verbose = false
    log.log(.debug, .app, "noise")
    log.verbose = true
    log.log(.debug, .app, "wanted")
    #expect(log.events().map(\.event) == ["wanted"])
}

@Test func rotatesAndCapsFiles() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = Diagnostics(directory: dir, maxFileBytes: 2_000, maxFiles: 3, processName: "test")
    for i in 0..<200 { log.log(.info, .app, "event_\(i)", String(repeating: "x", count: 40)) }
    log.flush()
    let files = log.logFiles()
    #expect(files.count <= 3)
    #expect(files.contains { $0.lastPathComponent == "test.jsonl" })
    // The newest events survive rotation.
    #expect(log.events().last?.event == "event_199")
    // A line past the limit on its own still leaves a current file.
    log.log(.info, .app, "big", String(repeating: "y", count: 3_000))
    log.flush()
    #expect(log.logFiles().contains { $0.lastPathComponent == "test.jsonl" })
    #expect(log.events().last?.event == "big")
}

@Test func readsProductConfigsLikeTheAgent() throws {
    let hearthstone = try ProductConfig(json: Data("""
    {"all":{"config":{"data_dir":"Data/","supported_locales":["enUS","ruRU"]}},
     "platform":{"mac":{"config":{"update_method":"containerless ngdp","tags":["OSX","manifest","base"],
       "binaries":{"game":{"relative_path":"Hearthstone.app","launch_arguments":["-launch"]}}}}}}
    """.utf8))
    #expect(hearthstone.isContainerless)
    #expect(hearthstone.subfolder == "")
    #expect(hearthstone.tagString(region: .eu, language: "ruRU") == "OSX manifest base EU? ruRU speech?:OSX manifest base EU? ruRU text?")

    let wow = try ProductConfig(json: Data("""
    {"all":{"config":{"data_dir":"Data/","shared_container_default_subfolder":"_classic_era_"}},
     "platform":{"mac":{"config":{"tags":["OSX"],"tags_64bit":["x86_64"],
       "binaries":{"game":{"relative_path":"World of Warcraft Classic.app","launch_arguments":[]}}}}}}
    """.utf8))
    #expect(!wow.isContainerless)
    #expect(wow.subfolder == "_classic_era_")
    #expect(wow.tagString(region: .us, language: "enUS").hasPrefix("OSX x86_64 arm64 US? enUS speech?"))

    let starcraft = try ProductConfig(json: Data("""
    {"all":{"config":{"data_dir":"Data/","noigr_tags":["noigr"]}},
     "platform":{"mac":{"config":{"tags":["OSX"],"binaries":{"game":{"relative_path":"x86/StarCraft.app",
       "relative_path_64":"x86_64/StarCraft.app","launch_arguments":["-launch"]}}}}}}
    """.utf8))
    #expect(starcraft.gameBinary == "x86_64/StarCraft.app")
    #expect(starcraft.extraTags == ["noigr"])
}

@Test func mapsSystemLanguagesToGameLanguages() {
    let hs = InstallableProduct.hearthstone
    #expect(hs.defaultLanguage(preferred: ["ru-RU"]) == "ruRU")
    #expect(hs.defaultLanguage(preferred: ["en-GB"]) == "enUS")
    #expect(hs.defaultLanguage(preferred: ["es-MX"]) == "esMX")
    #expect(hs.defaultLanguage(preferred: ["es-ES"]) == "esES")
    #expect(hs.defaultLanguage(preferred: ["zh-Hant-TW"]) == "zhTW")
    #expect(hs.defaultLanguage(preferred: ["zh-Hans-CN"]) == "zhCN")
    #expect(hs.defaultLanguage(preferred: ["uk-UA", "de-DE"]) == "deDE")
    #expect(hs.defaultLanguage(preferred: ["xx"]) == "enUS")
    #expect(Region.default(for: "CZ") == .eu)
    #expect(Region.default(for: "BR") == .us)
    #expect(Region.default(for: "TW") == .kr)
}

@Test func libraryFindsGamesWaypointInstalled() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = InstallStateStore(file: dir.appendingPathComponent("installs.json"))
    let folder = dir.appendingPathComponent("Hearthstone")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let install = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU? enUS speech?:OSX EU? enUS text?")
    try store.record(uid: install.uid, InstalledBuild(buildConfig: "abc", version: "36.6.3", install: install))

    let library = GameLibrary(agentDatabase: dir.appendingPathComponent("missing.db"), searchRoots: [], stateStore: store)
    let found = library.installs()
    #expect(found.map(\.uid) == ["hs_beta"])
    #expect(found.first?.installPath == folder.standardizedFileURL.path)
    #expect(found.first?.version == "36.6.3")
    #expect(found.first?.tagString == install.tagString)

    try FileManager.default.removeItem(at: folder)
    #expect(library.installs().isEmpty, "a deleted install disappears")
}

@Test func errorsLogAsOneCompactLine() {
    let lost = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [
        NSLocalizedDescriptionKey: "The network connection was lost.",
        NSURLErrorFailingURLStringErrorKey: "https://cdn.example/tpr/wow/data/aa/bb/aabb",
        "_NSURLErrorRelatedURLSessionTaskErrorKey": ["LocalDownloadTask <x>"],
    ])
    #expect(Diagnostics.describe(lost) == "NSURLErrorDomain -1005: The network connection was lost. (https://cdn.example/tpr/wow/data/aa/bb/aabb)")
    #expect(Diagnostics.describe(TACTError.notFound("thing")) == "Not found: thing")
}

@Test func newInstallsDefaultToTheRegionInstalledGamesUse() {
    func game(_ uid: String, _ region: String) -> Game {
        GameCatalog.game(for: ProductInstall(uid: uid, productCode: uid, installPath: "/nonexistent", region: region))
    }
    #expect(Region.preferred(games: [game("hs_beta", "eu"), game("w3", "eu"), game("wow", "us")]) == .eu)
    #expect(Region.preferred(games: []) == Region.default())
}

@Test func testRunsDontLogIntoTheUsersLogs() {
    #expect(Diagnostics.shared.directory != Diagnostics.defaultDirectory)
    #expect(Diagnostics.shared.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
}
