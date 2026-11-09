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

@Test func highResMetadataPreservesUnknownFieldsAndOtherEditions() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let old = f.install("wowf")
    var completed = old
    completed.tagString = InstallContent.tags(for: old, from: old.tagString!)
    var record = BattleNetInstallMetadata.encode(old, subfolder: "_forever_")
    record = try ProtoReader(record).mappingBytes(3) { settings in
        var opaque = ProtoWriter(); opaque.varint(90, 123)
        return try ProtoReader(settings + opaque.data).replacingBytes(9, with: Data("OtherContent".utf8))
    }
    var extra = ProtoWriter(); extra.string(99, "opaque Agent state")
    record += extra.data
    let patched = try BattleNetInstallMetadata.updatingContentSelection(record, for: completed)
    #expect(patched.suffix(extra.data.count) == extra.data)
    let settings = try #require(try ProtoReader(patched).fields()[3]?.first?.message?.fields())
    #expect(settings[9]?.first?.string == "OtherContent HighRes")
    #expect(settings[90]?.first?.uint == 123)
    #expect(try ProductDB.parseInstallFile(patched)?.tagString == completed.tagString)
    #expect(try BattleNetInstallMetadata.updatingContentSelection(patched, for: completed) == patched)

    var envelope = ProtoWriter()
    let retail = BattleNetInstallMetadata.encode(f.install(), subfolder: "_retail_")
    envelope.bytes(1, retail); envelope.bytes(1, record); envelope.string(100, "database extension")
    let updated = try BattleNetInstallMetadata.updatingContentSelection(envelope.data, for: completed)
    let entries = try ProtoReader(updated).fields()[1] ?? []
    if case .bytes(let bytes) = entries[0] { #expect(bytes == retail) }
    if case .bytes(let bytes) = entries[1] { #expect(bytes == patched) }
    #expect(try ProtoReader(updated).fields()[100]?.first?.string == "database extension")

    var stale = completed; stale.buildConfig = String(repeating: "b", count: 32)
    let olderAgent = try BattleNetInstallMetadata.updatingContentSelection(record, for: stale)
    #expect(try ProductDB.parseInstallFile(olderAgent)?.buildConfig == old.buildConfig)
    #expect(try ProductDB.parseInstallFile(olderAgent)?.tagString == old.tagString)
    #expect(try ProtoReader(olderAgent).fields()[3]?.first?.message?.fields()[9]?.first?.string == "OtherContent HighRes")
    var changedLanguage = completed
    changedLanguage.tagString = TagLanguages.replacing(in: completed.tagString!, with: GameLanguages(text: "deDE"))
    let languageChange = try BattleNetInstallMetadata.updatingContentSelection(record, for: changedLanguage)
    #expect(try ProductDB.parseInstallFile(languageChange)?.tagString == old.tagString)
    #expect(try ProtoReader(languageChange).fields()[3]?.first?.message?.fields()[9]?.first?.string == "OtherContent HighRes")
    #expect(try BattleNetInstallMetadata.updatingContentSelection(record, for: old) == record)
    #expect(try ProtoReader(BattleNetInstallMetadata.encode(completed, subfolder: "_forever_")).fields()[3]?.first?.message?.fields()[9]?.first?.string == "HighRes")
}

@Test func highResAlreadyOnDiskStillCommitsTagsWithoutChangingInGameLanguages() async throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let old = f.install("wowf")
    var selected = old
    selected.tagString = InstallContent.tags(for: old, from: old.tagString!)
    let product = try #require(InstallableProduct.forProduct("wowf"))
    let config = try ProductConfig(json: Data(#"{"all":{"config":{"shared_container_default_subfolder":"_forever_"}}}"#.utf8))
    let store = InstallStateStore(file: f.root.appendingPathComponent("installs.json"))
    let target = ProductVersion(region: "eu", buildConfig: f.build, cdnConfig: String(repeating: "b", count: 32),
                                buildID: 1, name: old.version!)
    let cdn = CDNClient(product: "wowf", path: "tpr/wow", servers: [])
    let loose = UpdatePlan(install: selected, target: target, cdn: cdn, files: [], deletions: [])
    let plan = CASCInstallPlan(install: selected, product: product, config: config, target: target, cdn: cdn,
                               buildConfig: Data(), cdnConfig: Data(), archives: [], storage: [], loose: loose,
                               setsLanguages: true, replacedTags: old.tagString)
    #expect(!plan.isEmpty)
    let wtf = f.game.appendingPathComponent("_forever_/WTF/Config.wtf")
    try FileManager.default.createDirectory(at: wtf.deletingLastPathComponent(), withIntermediateDirectories: true)
    let inGame = Data("SET textLocale \"deDE\"\nSET audioLocale \"frFR\"\n".utf8)
    try inGame.write(to: wtf)
    try await CASCInstaller(product: product, install: selected, config: config, store: store).apply(plan)
    #expect(try Data(contentsOf: wtf) == inGame)
    #expect(store.apply(to: old).tagString == selected.tagString)
    #expect(try String(contentsOf: f.game.appendingPathComponent(".build.info"), encoding: .utf8).contains(selected.tagString!))
    let folder = try Data(contentsOf: f.game.appendingPathComponent(".product.db"))
    #expect(try ProductDB.parseInstallFile(folder)?.tagString == selected.tagString)
    #expect(try ProtoReader(folder).fields()[3]?.first?.message?.fields()[9]?.first?.string == "HighRes")
}

/// An installation that does not have HighRes must not gain it in the
/// Agent's `UserSettings.additional_tags` (9): Battle.net would then treat
/// the package as selected and download it. Only the install's own completed
/// tags put it there, in full.
@Test func metadataLeavesContentSelectionOfInstallsWithoutHighResAlone() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let install = f.install("wowf")
    #expect(try ProtoReader(BattleNetInstallMetadata.encode(install, subfolder: "_forever_"))
        .fields()[3]?.first?.message?.fields()[9] == nil)
    #expect(try BattleNetInstallMetadata.repair(installs: [install], agentDatabase: f.database, ensureNotRunning: {}) == 2)
    func additionalTags(_ settings: [Int: [ProtoReader.Value]]?) throws -> String? {
        try settings?[3]?.first?.message?.fields()[9]?.first?.string
    }
    let folder = try Data(contentsOf: f.game.appendingPathComponent(".product.db"))
    #expect(try additionalTags(try ProtoReader(folder).fields()) == nil)
    #expect(try additionalTags(try ProtoReader(Data(contentsOf: f.database)).fields()[1]?.first?.message?.fields()) == nil)
    #expect(try BattleNetInstallMetadata.repair(installs: [install], agentDatabase: f.database, ensureNotRunning: {}) == 0)

    // The Agent's own record keeps whatever packages it selected.
    let record = try ProtoReader(BattleNetInstallMetadata.encode(install, subfolder: "_forever_")).mappingBytes(3) {
        try ProtoReader($0).replacingBytes(9, with: Data("OtherContent".utf8))
    }
    #expect(try BattleNetInstallMetadata.updatingContentSelection(record, for: install) == record)
    // HighRes in one set selects files, but does not establish that every set
    // selects it. Do not advertise a complete selection to the Agent.
    var partial = install
    partial.tagString = "OSX x86_64 arm64 EU? HighRes ruRU text?:OSX x86_64 arm64 EU? enUS speech?"
    #expect(try BattleNetInstallMetadata.updatingContentSelection(record, for: partial) == record)
    // A completed install that does select it throughout still reaches it.
    var completed = install
    completed.tagString = InstallContent.tags(for: install, from: install.tagString!)
    #expect(try additionalTags(try ProtoReader(BattleNetInstallMetadata.updatingContentSelection(record, for: completed)).fields())
        == "OtherContent HighRes")
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

@Test func metadataRepairsNestedDataAndManagedStoragePermissionsWithoutFollowingLinks() throws {
    let f = try MetadataFixture(); defer { f.remove() }
    let fm = FileManager.default
    let data = f.game.appendingPathComponent("Data")
    let config = data.appendingPathComponent("config")
    let nested = config.appendingPathComponent("aa/bb")
    let storage = data.appendingPathComponent("data")
    let indices = data.appendingPathComponent("indices")
    let restricted = data.appendingPathComponent("private")
    let restrictedChild = restricted.appendingPathComponent("child")
    let outside = f.root.appendingPathComponent("outside")
    for directory in [nested, storage, indices, restrictedChild, outside] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for directory in [data, config, config.appendingPathComponent("aa"), nested, storage, indices,
                      restricted, restrictedChild, outside] {
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    let archive = storage.appendingPathComponent("data.000")
    let privateArchive = storage.appendingPathComponent("data.001")
    let index = storage.appendingPathComponent("0000000001.idx")
    let shmem = storage.appendingPathComponent("shmem")
    let unrelated = storage.appendingPathComponent("notes.txt")
    try Data([1, 2, 3]).write(to: archive)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.path)
    for file in [privateArchive, index, shmem, unrelated] {
        try Data([4, 5, 6]).write(to: file)
        try fm.setAttributes([.posixPermissions: file == unrelated ? 0o644 : 0o600], ofItemAtPath: file.path)
    }
    try fm.createSymbolicLink(at: data.appendingPathComponent("external"), withDestinationURL: outside)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
    try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: config.path)
    #expect(try BattleNetInstallMetadata.prepareDataDirectory(data))
    func mode(_ url: URL) throws -> Int { try #require(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }
    for directory in [data, config, config.appendingPathComponent("aa"), nested, storage, indices] {
        #expect(try mode(directory) == 0o777)
    }
    #expect(try mode(archive) == 0o666)
    #expect(try mode(index) == 0o666)
    #expect(try mode(shmem) == 0o666)
    #expect(try mode(privateArchive) == 0o600)
    #expect(try mode(unrelated) == 0o644)
    #expect(try Data(contentsOf: archive) == Data([1, 2, 3]))
    #expect(try mode(outside) == 0o755)
    #expect(try mode(restricted) == 0o700)
    #expect(try mode(restrictedChild) == 0o755)
    #expect(try !BattleNetInstallMetadata.prepareDataDirectory(data))
}
