import Foundation
import Testing
@testable import WaypointCore

private func install(_ w: inout ProtoWriter, uid: String, code: String, path: String, region: String, version: String) {
    w.message(1) { p in
        p.string(1, uid)
        p.string(2, code)
        p.message(3) { s in
            s.string(1, path)
            s.string(2, region)
            s.varint(3, 2)
            s.string(6, "enUS")
            s.string(7, "deDE")
        }
        p.message(4) { c in
            c.message(1) { b in
                b.varint(1, 1)
                b.string(7, version)
            }
        }
    }
}

@Test func parsesAgentDatabaseAndSkipsInfrastructure() throws {
    var w = ProtoWriter()
    install(&w, uid: "agent", code: "agent", path: "/Users/Shared/Battle.net/Agent", region: "us", version: "2.41.1.9824")
    install(&w, uid: "battle.net", code: "bna", path: "/Applications/Battle.net.app", region: "us", version: "2.53.4.17896")
    install(&w, uid: "hs_beta", code: "hsb", path: "/Applications/Hearthstone", region: "eu", version: "36.6.3.253932.253216")
    install(&w, uid: "wow", code: "wow", path: "/Applications/World of Warcraft", region: "eu", version: "12.0.1.66000")
    w.varint(6, 4057155)
    w.string(7, "hs_beta")

    let installs = try ProductDB.parseDatabase(w.data)
    #expect(installs.map(\.uid) == ["hs_beta", "wow"])
    #expect(installs[0] == ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/Applications/Hearthstone",
                                          region: "eu", textLanguage: "enUS", speechLanguage: "deDE",
                                          version: "36.6.3.253932.253216"))
}

@Test func parsesPerInstallFile() throws {
    var w = ProtoWriter()
    w.string(1, "hs_beta")
    w.string(2, "hsb")
    w.message(3) { s in s.string(1, "/Applications/Hearthstone"); s.string(2, "eu") }
    let install = try #require(try ProductDB.parseInstallFile(w.data))
    #expect(install.uid == "hs_beta")
    #expect(install.region == "eu")
    #expect(install.version == nil)
}

@Test(arguments: [false, true])
func parsesFolderDatabaseDespiteUnknownSingleRecordShapedFields(validUnknownSettings: Bool) throws {
    var writer = ProtoWriter()
    install(&writer, uid: "wow", code: "wow", path: "/Games/WoW", region: "eu", version: "1.0")
    writer.string(2, "unknown database field")
    if validUnknownSettings {
        writer.message(3) { $0.string(1, "/Games/other") }
    } else {
        writer.bytes(3, Data([0xff]))
    }

    #expect(try ProductDB.parseFolderInstalls(writer.data).map(\.uid) == ["wow"])
}

@Test func rejectsTruncatedData() {
    #expect(throws: (any Error).self) { try ProductDB.parseDatabase(Data([0x0a, 0x10, 0x01])) }
}

private let invalidProtobufLengths: [Data] = [
    // UInt64.max cannot be represented as a Data index.
    Data([0x0a] + [UInt8](repeating: 0xff, count: 9) + [0x01]),
    // Int.max fits, but adding it to the cursor used to overflow.
    Data([0x0a] + [UInt8](repeating: 0xff, count: 8) + [0x7f]),
    Data([0x0a, 0x02, 0x00]),
    Data([0x0a, 0x80]),
]
@Test(arguments: invalidProtobufLengths)
func rejectsInvalidProtobufLengths(_ data: Data) {
    #expect(throws: (any Error).self) { try ProductDB.parseDatabase(data) }
}

private let invalidProtobufVarints: [Data] = [
    // The tenth byte can hold only bit 63, not bit 64 or a continuation.
    Data([0x30] + [UInt8](repeating: 0xff, count: 9) + [0x02]),
    Data([0x30] + [UInt8](repeating: 0x80, count: 10) + [0x00]),
    Data([0x30, 0x80]),
]
@Test(arguments: invalidProtobufVarints)
func rejectsOverflowingOrTruncatedProtobufVarints(_ data: Data) {
    #expect(throws: (any Error).self) { try ProductDB.parseDatabase(data) }
}

@Test func acceptsMaximumProtobufValuesAndExactPayloadBounds() throws {
    var w = ProtoWriter()
    install(&w, uid: "wow", code: "wow", path: "/Games/World of Warcraft", region: "eu", version: "12.0.1")
    w.varint(99, UInt64.max)
    w.fixed64(100, UInt64.max)
    w.bytes(101, Data())

    let fields = try ProtoReader(w.data).fields()
    #expect(fields[99]?.first?.uint == UInt64.max)
    #expect(try ProductDB.parseDatabase(w.data).map(\.uid) == ["wow"])
    #expect(try ProductDB.parseDatabase(Data([0x0a, 0x00])).isEmpty)
}

@Test func wowFlavorsMapToFolders() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root.appendingPathComponent("_classic_era_/World of Warcraft Classic.app/Contents"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("_retail_/World of Warcraft.app/Contents"), withIntermediateDirectories: true)

    let era = GameCatalog.game(for: ProductInstall(uid: "wow_classic_era", productCode: "wow_classic_era", installPath: root.path))
    #expect(era.appURL?.lastPathComponent == "World of Warcraft Classic.app")
    #expect(era.family == .worldOfWarcraft)

    let retail = GameCatalog.game(for: ProductInstall(uid: "wow", productCode: "wow", installPath: root.path))
    #expect(retail.appURL?.lastPathComponent == "World of Warcraft.app")

    let classic = GameCatalog.game(for: ProductInstall(uid: "wow_classic", productCode: "wow_classic", installPath: root.path))
    #expect(classic.appURL == nil)
}
