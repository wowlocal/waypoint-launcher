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
                                          region: "eu", textLanguage: "enUS", version: "36.6.3.253932.253216"))
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

@Test func rejectsTruncatedData() {
    #expect(throws: (any Error).self) { try ProductDB.parseDatabase(Data([0x0a, 0x10, 0x01])) }
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
