import Foundation
import Testing
@testable import WaypointCore

private struct MetadataFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-metadata-\(UUID().uuidString)")
    var database: URL { root.appendingPathComponent("Agent/product.db") }
    var game: URL { root.appendingPathComponent("World of Warcraft") }
    var build: String { String(repeating: "a", count: 32) }

    init() throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: database)
        for folder in ["_retail_", "_forever_"] {
            try FileManager.default.createDirectory(at: game.appendingPathComponent("\(folder)/World of Warcraft.app/Contents"),
                                                    withIntermediateDirectories: true)
        }
        let info = "Product!STRING:0|Active!DEC:1|Build Key!HEX:16\nwow|1|\(build)\nwowf|1|\(build)\n"
        try Data(info.utf8).write(to: game.appendingPathComponent(".build.info"))
    }
    func install(_ code: String = "wow", platform: InstallPlatform = .macOS) -> ProductInstall {
        ProductInstall(uid: code, productCode: code, installPath: game.path, region: "eu",
                       textLanguage: "ruRU", speechLanguage: "enUS", version: "12.1.5.70783", buildConfig: build,
                       tagString: platform == .macOS ? "OSX x86_64 arm64 EU? ruRU text?:OSX x86_64 arm64 EU? enUS speech?" : "Windows", platform: platform)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func sharedWoWMetadataAddsBothEditionsAndIsIdempotent() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    var original = ProtoWriter()
    original.string(100, "preserve unknown Agent data")
    try original.data.write(to: f.database)
    #expect(try BattleNetInstallMetadata.repair(installs: [f.install("wowf"), f.install()], agentDatabase: f.database,
                                              ensureNotRunning: {}) == 3)
    let data = try Data(contentsOf: f.database)
    #expect(data.starts(with: original.data))
    let installs = try ProductDB.parseDatabase(data)
    #expect(installs.map(\.uid) == ["wow", "wowf"])
    #expect(installs.allSatisfy { $0.installPath == f.game.path })
    #expect(installs.allSatisfy { $0.buildConfig == f.build && $0.speechLanguage == "enUS" && $0.textLanguage == "ruRU" })
    let folder = f.game.appendingPathComponent(".product.db")
    let folderData = try Data(contentsOf: folder)
    #expect(try ProductDB.parseInstallFile(folderData)?.uid == "wow")
    #expect(!FileManager.default.fileExists(atPath: f.game.appendingPathComponent("_forever_/.product.db").path))
    #expect(try BattleNetInstallMetadata.repair(installs: [f.install(), f.install("wowf")], agentDatabase: f.database,
                                              ensureNotRunning: {}) == 0)
    #expect(try Data(contentsOf: f.database) == data)
    #expect(try Data(contentsOf: folder) == folderData)
}

@Test func metadataPreservesExistingAgentRecordsAndFolderBytes() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    var existing = f.install()
    existing.installPath = "/another/copy"
    var writer = ProtoWriter()
    writer.bytes(1, BattleNetInstallMetadata.encode(existing, subfolder: "_retail_"))
    writer.varint(99, 42)
    try writer.data.write(to: f.database)
    let folder = f.game.appendingPathComponent(".product.db")
    let opaque = Data([0xff, 0x12, 0x04])
    try opaque.write(to: folder)
    #expect(try BattleNetInstallMetadata.repair(installs: [f.install()], agentDatabase: f.database, ensureNotRunning: {}) == 0)
    #expect(try Data(contentsOf: folder) == opaque)
    #expect(try Data(contentsOf: f.database) == writer.data)
}

@Test func metadataSkipsUnfinishedStaleAndWindowsInstalls() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    var stale = f.install(); stale.buildConfig = String(repeating: "b", count: 32)
    var unfinished = f.install(); unfinished.version = nil
    var missing = f.install(); missing.installPath = f.root.appendingPathComponent("missing").path
    #expect(try BattleNetInstallMetadata.repair(installs: [stale, unfinished, missing, f.install(platform: .windows)],
                                              agentDatabase: f.database, ensureNotRunning: {}) == 0)
    #expect(try Data(contentsOf: f.database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.game.appendingPathComponent(".product.db").path))
}

@Test func metadataDoesNotCreateAgentInfrastructure() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    try FileManager.default.removeItem(at: f.database)
    #expect(try BattleNetInstallMetadata.repair(installs: [f.install()], agentDatabase: f.database, ensureNotRunning: {}) == 1)
    #expect(!FileManager.default.fileExists(atPath: f.database.path))
    #expect(try ProductDB.parseInstallFile(Data(contentsOf: f.game.appendingPathComponent(".product.db")))?.uid == "wow")
}

@Test func metadataRefusesRunningAgentAndConcurrentDatabaseChanges() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    #expect(throws: UpdateError.self) {
        try BattleNetInstallMetadata.repair(installs: [f.install()], agentDatabase: f.database,
                                           ensureNotRunning: { throw UpdateError.battleNetRunning(agentOnly: false) })
    }
    #expect(!FileManager.default.fileExists(atPath: f.game.appendingPathComponent(".product.db").path))
    var checks = 0
    var otherWriter = ProtoWriter(); otherWriter.string(100, "Agent changed it")
    #expect(throws: (any Error).self) {
        try BattleNetInstallMetadata.repair(installs: [f.install()], agentDatabase: f.database, ensureNotRunning: {
            checks += 1
            if checks == 3 { try otherWriter.data.write(to: f.database) }
        })
    }
    #expect(try Data(contentsOf: f.database) == otherWriter.data)
}

@Test func metadataEncodesSeparateLanguageFlagsAndSharedSubfolder() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let data = BattleNetInstallMetadata.encode(f.install("wowf"), subfolder: "_forever_")
    let fields = try ProtoReader(data).fields()
    let settings = try #require(try fields[3]?.first?.message?.fields())
    #expect(settings[13]?.first?.string == "_forever_")
    let languages = try (settings[8] ?? []).compactMap { try $0.message?.fields() }
    #expect(languages.count == 2)
    #expect(languages.first { $0[1]?.first?.string == "ruRU" }?[2]?.first?.uint == 2)
    #expect(languages.first { $0[1]?.first?.string == "enUS" }?[2]?.first?.uint == 1)
    #expect(fields[6]?.first?.string == "wow")
}

@Test func metadataRepairsOnlyKnownOwnedDataDirectoryModes() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let fm = FileManager.default
    let data = f.game.appendingPathComponent("Data")
    try fm.createDirectory(at: data, withIntermediateDirectories: false)
    func mode(_ file: URL) throws -> Int { try #require(fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) }
    for legacyMode in [0o755, 0o666] {
        try fm.setAttributes([.posixPermissions: legacyMode], ofItemAtPath: data.path)
        #expect(try BattleNetInstallMetadata.prepareDataDirectory(data))
        #expect(try mode(data) == 0o777)
        #expect(try !BattleNetInstallMetadata.prepareDataDirectory(data))
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
    #expect(try !BattleNetInstallMetadata.prepareDataDirectory(data))
    #expect(try mode(data) == 0o700)
    let link = f.game.appendingPathComponent("Data-link")
    try fm.createSymbolicLink(at: link, withDestinationURL: data)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
    #expect(try !BattleNetInstallMetadata.prepareDataDirectory(link))
    #expect(try mode(data) == 0o755)
}
