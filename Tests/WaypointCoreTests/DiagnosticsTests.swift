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
}

@Test func freshInstallTagsMatchBattleNetShape() {
    let tags = InstallableProduct.hearthstone.tagString(region: .eu, language: "ruRU")
    #expect(tags.hasPrefix("OSX adventure base bgs dbf"))
    #expect(tags.contains("EU? ruRU speech?:OSX"))
    #expect(tags.hasSuffix("EU? ruRU text?"))
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
    let install = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS")
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
