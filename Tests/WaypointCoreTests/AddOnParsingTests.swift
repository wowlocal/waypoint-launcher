import Foundation
import Testing
@testable import WaypointCore

// MARK: Flavors

@Test(arguments: [
    (11509, WoWFlavor.vanilla), (16001, .forever), (20506, .tbc), (30405, .wrath), (38002, .titan),
    (40402, .cata), (50504, .mists), (120105, .mainline), (120107, .mainline), (110207, .mainline),
])
func interfaceNumbersNameTheirGame(interface: Int, flavor: WoWFlavor) {
    #expect(WoWFlavor(interface: interface) == flavor)
}

@Test func numbersOutsideEveryGameAreNoFlavor() {
    #expect(WoWFlavor(interface: 0) == nil)
    #expect(WoWFlavor(interface: 20400) == nil)   // the original TBC
    #expect(WoWFlavor(interface: 11299) == nil)
}

@Test func theInstalledVersionDecidesTheFlavorBeforeTheProduct() {
    #expect(WoWFlavor.interface(version: "12.1.5.65432") == 120105)
    #expect(WoWFlavor.interface(version: "1.15.9") == 11509)
    #expect(WoWFlavor.interface(version: "bad") == nil)
    #expect(WoWFlavor.of(productCode: "wow_classic", version: "5.5.4.12345") == .mists)
    // When Blizzard moves _classic_ on, the version follows.
    #expect(WoWFlavor.of(productCode: "wow_classic", version: "6.2.0.1") == .mainline)
    #expect(WoWFlavor.of(productCode: "wow_classic", version: nil) == .mists)
    #expect(WoWFlavor.of(productCode: "wow_anniversary", version: nil) == .tbc)
    #expect(WoWFlavor.of(productCode: "wowf", version: "1.60.1.1") == .forever)
    #expect(WoWFlavor.of(productCode: "wow_classic_era", version: "1.15.9.1") == .vanilla)
    #expect(WoWFlavor.of(productCode: "wow_odd", version: nil) == nil)
}

// MARK: TOC

@Test func tocValuesAreReadLikeTheGameReadsThem() {
    let text = "\u{FEFF}## Interface: 120105, 50504 ,11509\r\n## Title: |cFF33FF99Deadly|r Boss Mods |TInterface\\Icon:16|t [AllowLoadGameType mainline]\r\n" +
        "## Version: 12.1.23\r\n## Version: 9.9.9\r\n##X-Curse-Project-ID:3358\n## x-wowi-id: 8814\n## X-Wago-ID: qv633o6b\n" +
        "## Dependencies: DBM-StatusBarTimers, \n## RequiredDeps: LibStub\n## Group: DBM-Core\n## LoadOnDemand: 1\n# a comment\nCore.lua\n"
    let toc = AddOnTOC(Data(text.utf8))
    #expect(toc.interfaces == [120105, 50504, 11509])
    #expect(toc.title == "Deadly Boss Mods")
    #expect(toc.version == "12.1.23")   // the first wins
    #expect(toc.curseID == "3358" && toc.wowiID == "8814" && toc.wagoID == "qv633o6b")
    #expect(toc.dependencies == ["DBM-StatusBarTimers", "LibStub"])
    #expect(toc.group == "DBM-Core")
    #expect(toc.isLoadOnDemand)
}

@Test func oddTOCsNeverFail() {
    #expect(AddOnTOC(Data()) == AddOnTOC(Data()))
    let latin1 = AddOnTOC(Data([0x23, 0x23, 0x20, 0x54, 0x69, 0x74, 0x6C, 0x65, 0x3A, 0x20, 0x43, 0x61, 0x66, 0xE9]))
    #expect(latin1.title == "Café")
    let utf16 = AddOnTOC("## Version: 2.0\n".data(using: .utf16)!)
    #expect(utf16.version == "2.0")
    let placeholder = AddOnTOC(Data("## Version: @project-version@\n".utf8))
    #expect(placeholder.version == nil)
    let long = AddOnTOC(Data(("## Title: " + String(repeating: "x", count: 5000) + "\n## Version: 1\n").utf8))
    #expect(long.title?.count == 1024 - "## Title: ".count)
    #expect(long.version == "1")
}

@Test(arguments: [
    (["X.toc", "X_Mainline.toc", "X_Standard.toc"], WoWFlavor.mainline, "X_Standard.toc"),
    (["X.toc", "X_Mainline.toc"], .mainline, "X_Mainline.toc"),
    (["X.toc", "X_Mainline.toc"], .mists, "X.toc"),
    (["X.toc", "X_Classic.toc", "X_Mists.toc"], .mists, "X_Mists.toc"),
    (["X.toc", "X_Classic.toc", "X_Mists.toc"], .vanilla, "X_Classic.toc"),
    (["X_Vanilla.toc", "X-TBC.toc"], .tbc, "X-TBC.toc"),
    (["X_Wrath.toc", "X_Classic.toc"], .titan, "X_Wrath.toc"),
    (["X_Mainline.toc", "X_Classic.toc"], .forever, "X_Mainline.toc"),
    (["X_Camelot.toc", "X_Mainline.toc"], .forever, "X_Camelot.toc"),
    (["x_mists.TOC", "X.toc"], .mists, "x_mists.TOC"),
])
func theTOCTheGameLoadsIsChosen(names: [String], flavor: WoWFlavor, chosen: String) {
    #expect(AddOnTOC.choose(from: names, folder: "X", flavor: flavor) == chosen)
}

@Test func onlyTOCsNamedForTheirFolderCount() {
    #expect(AddOnTOC.choose(from: ["Y.toc"], folder: "X", flavor: .mainline) == nil)
    #expect(AddOnTOC.choose(from: ["X_Vanilla.toc"], folder: "X", flavor: .mainline) == nil)
    #expect(AddOnTOC.isTOC("X_Mainline.toc", of: "X"))
    #expect(AddOnTOC.isTOC("X.toc", of: "X"))
    #expect(!AddOnTOC.isTOC("X_Options.toc", of: "X"))
    #expect(!AddOnTOC.isTOC("Y.toc", of: "X"))
}

// MARK: Scanner

@Test func theScanSeesWhatTheGameLoadsAndChangesNothing() throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("Plain", ["Plain.toc": "## Interface: 120105\n## Version: 3\n"])
    try wow.addOn("Blizzard_Debug", ["Blizzard_Debug.toc": "## Interface: 120105\n"])
    try wow.addOn("Classic", ["Classic_Vanilla.toc": "## Interface: 11509\n"])
    try wow.addOn("Questie", ["Questie.toc": "## Interface: 00000\n## Title: not supported\n", "Questie_Vanilla.toc": "## Interface: 11509\n"])
    try wow.addOn("OldPlain", ["OldPlain.toc": "## Interface: 11509\n"])
    try wow.addOn("Dev", ["Dev.toc": "## Interface: 120105\n", ".git/HEAD": "ref"])
    try wow.addOn("NoTOC", ["readme.txt": "x"])
    try Data("x".utf8).write(to: wow.addOns.appendingPathComponent("loose.txt"))
    try FileManager.default.createSymbolicLink(at: wow.addOns.appendingPathComponent("Linked"), withDestinationURL: wow.wtf)
    let before = try TreeSnapshot(wow.root)

    let folders = try AddOnScanner().scan(wow.addOns, flavor: .mainline)
    let kinds = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.kind) })
    #expect(kinds == ["Plain": .addOn, "Blizzard_Debug": .blizzard, "Classic": .notForThisVersion, "Questie": .notForThisVersion,
                      "OldPlain": .notForThisVersion, "Dev": .developmentCopy, "Linked": .link])
    #expect(folders.first { $0.name == "Plain" }?.toc?.version == "3")
    #expect(folders.first { $0.name == "Plain" }?.tocModified != nil)
    #expect(try TreeSnapshot(wow.root) == before)

    let classic = try AddOnScanner().scan(wow.addOns, flavor: .vanilla)
    #expect(classic.first { $0.name == "Questie" }?.kind == .addOn)
    #expect(classic.first { $0.name == "Plain" }?.kind == .notForThisVersion)
}

@Test func aGameThatHasntRunYetHasNoAddOns() throws {
    let wow = try FakeWoW(makeAddOns: false)
    defer { wow.remove() }
    #expect(try AddOnScanner().scan(wow.addOns, flavor: .mainline).isEmpty)
}

// MARK: Zip and package

private func writeZip(_ entries: [TestZip.Entry], deflate: Bool = true) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-zip-\(UUID().uuidString).zip")
    try TestZip.make(entries, deflate: deflate).write(to: url)
    return url
}

@Test(arguments: [true, false])
func zipEntriesComeOutAsTheyWentIn(deflate: Bool) throws {
    let big = Data((0..<300_000).map { UInt8($0 % 251) })
    let zip = try writeZip([.directory("A"), .file("A/A.toc", Data("## Interface: 120105\n".utf8)), .file("A/big.bin", big)], deflate: deflate)
    defer { try? FileManager.default.removeItem(at: zip) }
    let archive = try ZipArchive(zip)
    #expect(archive.entries.map(\.path) == ["A/", "A/A.toc", "A/big.bin"])
    #expect(archive.entries[0].isDirectory)
    #expect(try archive.data(archive.entries[2], maximum: 1 << 20) == big)
}

@Test func damagedZipsAreRefused() throws {
    let lying = try writeZip([.lying("A/A.toc", actual: Data(repeating: 65, count: 100_000), declaredSize: 10)])
    let badCRC = try writeZip([.badCRC("A/A.toc", Data("## Interface: 120105\n".utf8))])
    let good = TestZip.make(TestZip.addOn("A"))
    let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-zip-\(UUID().uuidString).zip")
    try good.prefix(good.count * 6 / 10).write(to: truncated)
    let html = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-zip-\(UUID().uuidString).zip")
    try Data("<html>Not Found</html>".utf8).write(to: html)
    defer { for url in [lying, badCRC, truncated, html] { try? FileManager.default.removeItem(at: url) } }

    for url in [lying, badCRC] {
        let archive = try ZipArchive(url)
        #expect(throws: ZipError.damaged) { try archive.data(archive.entries[0], maximum: 1 << 20) }
    }
    #expect(throws: ZipError.damaged) { try ZipArchive(truncated) }
    #expect(throws: ZipError.damaged) { try ZipArchive(html) }
}

@Test(arguments: [
    [TestZip.Entry.file("../../WTF/Config.wtf", Data("x".utf8))],
    [.file("Foo/../../x.lua", Data("x".utf8))],
    [.file("Foo\\..\\..\\x.lua", Data("x".utf8))],
    [.file("/etc/x", Data("x".utf8))],
    [.file("C:/x/x.toc", Data("x".utf8))],
    [.symlink("Foo/link", target: "../../WTF")],
    [.file("Foo/Foo.toc", Data("x".utf8)), .file("foo/foo.toc", Data("x".utf8))],
    [.file("Foo/Foo.toc", Data("x".utf8)), .file("Foo/foo.TOC", Data("x".utf8))],
])
func unsafeEntriesRefuseTheWholeZip(extra: [TestZip.Entry]) throws {
    let zip = try writeZip(TestZip.addOn("Foo") + extra)
    defer { try? FileManager.default.removeItem(at: zip) }
    #expect(throws: AddOnPackageError.self) { try AddOnPackage(zip: zip, flavor: .mainline) }
}

@Test func zipsThatArentAddOnFoldersAreRefused() throws {
    let cases: [[TestZip.Entry]] = [
        TestZip.addOn("Foo") + [.file("README.txt", Data("x".utf8))],
        TestZip.addOn("Foo") + [.file("Libs/LibStub.lua", Data("x".utf8))],
        TestZip.addOn("Blizzard_Foo"),
        [],
    ]
    for entries in cases {
        let zip = try writeZip(entries)
        defer { try? FileManager.default.removeItem(at: zip) }
        #expect(throws: AddOnPackageError.self) { try AddOnPackage(zip: zip, flavor: .mainline) }
    }
}

@Test func junkIsDroppedAndEveryFolderComesOut() throws {
    let zip = try writeZip(TestZip.addOn("Foo") + TestZip.addOn("Foo_Options") + [
        .file("__MACOSX/Foo/._Foo.toc", Data("x".utf8)), .file("Foo/.DS_Store", Data("x".utf8)),
        .file("Foo/._Core.lua", Data("x".utf8)), .file("Foo/Libs/Lib/Lib.lua", Data("lib".utf8)),
    ])
    defer { try? FileManager.default.removeItem(at: zip) }
    let package = try AddOnPackage(zip: zip, flavor: .mainline)
    #expect(package.folders == ["Foo", "Foo_Options"])
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-out-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    try package.extract(to: out)
    let tree = try TreeSnapshot(out)
    #expect(Set(tree.items.keys) == ["Foo", "Foo/Foo.toc", "Foo/Core.lua", "Foo/Libs", "Foo/Libs/Lib", "Foo/Libs/Lib/Lib.lua",
                                     "Foo_Options", "Foo_Options/Foo_Options.toc", "Foo_Options/Core.lua"])
}

@Test func aZipForAnotherGameIsntInstalled() throws {
    let zip = try writeZip(TestZip.addOn("Foo", toc: "## Interface: 11509\n", tocName: "Foo_Vanilla.toc"))
    defer { try? FileManager.default.removeItem(at: zip) }
    #expect(throws: AddOnSourceError.notForThisVersion) { try AddOnPackage(zip: zip, flavor: .mainline) }
    #expect(try AddOnPackage(zip: zip, flavor: .vanilla).folders == ["Foo"])
}

@Test func zipsPastTheLimitsAreRefused() throws {
    let zip = try writeZip(TestZip.addOn("Foo") + [.file("Foo/big.bin", Data(repeating: 0, count: 2 << 20))])
    defer { try? FileManager.default.removeItem(at: zip) }
    #expect(throws: AddOnPackageError.tooLarge) { try AddOnPackage(zip: zip, flavor: .mainline, maximumBytes: 1 << 20) }
    #expect(throws: AddOnPackageError.tooLarge) { try AddOnPackage(zip: zip, flavor: .mainline, maximumEntries: 2) }
}
