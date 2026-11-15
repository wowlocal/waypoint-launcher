import Foundation
import Testing
@testable import WaypointCore

private let retailTOC = "## Interface: 120105\n## Version: 1.0\n"
private let indexForTests = AddOnIndex(entries: [
    AddOnIndex.Entry(name: "Deadly Boss Mods", author: "MysticalOS", folders: ["DBM-Core", "DBM-GUI"], curse: "3358", wago: nil, wowi: nil,
                     source: AddOnRef(.github, "DeadlyBossMods/DeadlyBossMods")),
    AddOnIndex.Entry(name: "OmniCC", author: "Tuller", folders: ["OmniCC", "OmniCC_Config"], curse: nil, wago: nil, wowi: nil,
                     source: AddOnRef(.github, "tullamods/OmniCC")),
    AddOnIndex.Entry(name: "ElvUI", author: "Elv", folders: ["ElvUI", "ElvUI_Options", "ElvUI_Libraries"], curse: nil, wago: nil, wowi: nil,
                     source: AddOnRef(.tukui, "elvui")),
])

private func folder(_ name: String, _ toc: String = retailTOC, kind: InstalledFolder.Kind = .addOn) -> InstalledFolder {
    InstalledFolder(name: name, kind: kind, toc: AddOnTOC(Data(toc.utf8)))
}

// MARK: Matching

@Test func foldersAreRecognizedInOrderAndNeverGuessed() {
    let matcher = AddOnMatcher(index: indexForTests)
    let rows = matcher.match([
        folder("DBM-Core", "## Version: 12.1.22\n## X-Curse-Project-ID: 3358\n"),
        folder("DBM-GUI", "## Group: DBM-Core\n## LoadOnDemand: 1\n"),
        folder("DBM-Brawlers", "## RequiredDeps: DBM-Core\n## LoadOnDemand: 1\n"),
        folder("ElvUI", "## X-Tukui-ProjectID: -2\n## Version: 16.00\n"),
        folder("ElvUI_Options", "## Dependencies: ElvUI\n"),
        folder("ElvUI_WindTools", "## Dependencies: ElvUI\n## X-WoWI-ID: 9999\n"),
        folder("OmniCC", "## Version: 11.2.7\n"),
        folder("TomTom", "## X-WoWI-ID: 4111\n## Version: v4.4\n"),
        folder("Details", "## X-Curse-Project-ID: 61284\n## Title: Details! Damage Meter\n"),
        folder("MyTweaks", "## Title: My Tweaks\n"),
        folder("WeirdOmni", "## X-Curse-Project-ID: 1\n"),
        folder("Linked", kind: .link),
        folder("Blizzard_Debug", kind: .blizzard),
    ], records: [])
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    #expect(byID["github:DeadlyBossMods/DeadlyBossMods"]?.folders == ["DBM-Core", "DBM-Brawlers", "DBM-GUI"])
    #expect(byID["github:DeadlyBossMods/DeadlyBossMods"]?.version == "12.1.22")
    #expect(byID["github:DeadlyBossMods/DeadlyBossMods"]?.name == "Deadly Boss Mods")
    #expect(byID["tukui:elvui"]?.folders == ["ElvUI", "ElvUI_Options"])
    // A plugin with its own ID stays its own add-on.
    #expect(byID["wowInterface:9999"]?.folders == ["ElvUI_WindTools"])
    #expect(byID["github:tullamods/OmniCC"]?.folders == ["OmniCC"])
    #expect(byID["wowInterface:4111"]?.version == "v4.4")
    #expect(byID["folder:Details"]?.unmanaged == .curseForge("61284"))
    #expect(byID["folder:Details"]?.name == "Details! Damage Meter")
    #expect(byID["folder:MyTweaks"]?.unmanaged == .unknown)
    #expect(byID["folder:WeirdOmni"]?.unmanaged == .curseForge("1"))
    #expect(byID["folder:Linked"]?.unmanaged == .link)
    #expect(byID["folder:Blizzard_Debug"] == nil)
}

@Test func aFolderWhoseIDsContradictTheIndexIsntTakenOver() {
    let matcher = AddOnMatcher(index: indexForTests)
    let rows = matcher.match([folder("DBM-Core", "## X-Curse-Project-ID: 999\n")], records: [])
    #expect(rows.map(\.id) == ["folder:DBM-Core"])
}

@Test func whatWaypointInstalledIsItsOwnWhateverTheFoldersSay() {
    let release = AddOnRelease(ref: AddOnRef(.github, "a/b"), id: "v1", version: "v1", date: nil, download: URL(string: "https://github.com/x")!)
    let record = AddOnRecord(ref: release.ref, name: "B", mainFolder: "B", folders: ["B", "B_Extra", "Masque_B"], release: release,
                             folderHashes: [:], tocVersion: "1.0")
    let rows = AddOnMatcher(index: indexForTests).match([folder("B"), folder("B_Extra"), folder("Masque_B")], records: [record])
    #expect(rows.count == 1)
    #expect(rows[0].folders == ["B", "B_Extra", "Masque_B"])
    #expect(rows[0].record == record)
}

// MARK: Deciding updates

@Test func updatesAreOfferedOnlyWhenTheReleaseIsReallyNewer() {
    let installedAt = Date(timeIntervalSince1970: 1_790_000_000)
    func release(_ version: String, _ date: Date?) -> AddOnRelease {
        AddOnRelease(ref: AddOnRef(.github, "a/b"), id: version, version: version, date: date, download: URL(string: "https://github.com/x")!)
    }
    let addOn = InstalledAddOn(id: "github:a/b", name: "B", folders: ["B"], version: "v1.0", ref: AddOnRef(.github, "a/b"), modified: installedAt)
    #expect(!AddOnLibrary.decide(addOn, latest: release("1.0", installedAt.addingTimeInterval(86400))), "same version, no re-download")
    #expect(AddOnLibrary.decide(addOn, latest: release("1.1", installedAt.addingTimeInterval(7200))))
    #expect(!AddOnLibrary.decide(addOn, latest: release("1.1", installedAt.addingTimeInterval(1800))), "within the hour")
    // A stale source (Details' 2020 WoWInterface copy) never downgrades.
    #expect(!AddOnLibrary.decide(addOn, latest: release("0.9", installedAt.addingTimeInterval(-86400 * 365))))
    #expect(!AddOnLibrary.decide(addOn, latest: release("1.1", nil)))

    var recorded = addOn
    recorded.record = AddOnRecord(ref: addOn.ref!, name: "B", mainFolder: "B", folders: ["B"], release: release("1.0", installedAt),
                                  folderHashes: [:], tocVersion: "v1.0")
    #expect(!AddOnLibrary.decide(recorded, latest: release("1.0", installedAt)))
    #expect(AddOnLibrary.decide(recorded, latest: release("1.1", installedAt.addingTimeInterval(60))))
    #expect(!AddOnLibrary.decide(recorded, latest: release("0.9", installedAt.addingTimeInterval(-60))))
    // Tukui dates by the day: a second release that day is still an update.
    #expect(AddOnLibrary.decide(recorded, latest: release("1.0.1", installedAt)))
}

// MARK: Sources

@Test func gitHubReleasesComeFromTheWebLinksAndTheRightZip() async throws {
    let http = FakeHTTP()
    let json = #"""
    {"releases":[
      {"name":"Q","filename":"Q-nolib.zip","nolib":true,"metadata":[{"flavor":"mainline","interface":120105}]},
      {"name":"Q","filename":"Q-classic.zip","nolib":false,"metadata":[{"flavor":"classic","interface":11509},{"flavor":"wrath","interface":38002}]},
      {"name":"Q","version":"2.0","filename":"Q-main.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120100}]},
      {"name":"Q","version":"2.0","filename":"Q-exact.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":"120105"}]}
    ]}
    """#
    let modified = Date(timeIntervalSince1970: 1_790_000_000)
    http.route("https://github.com/Questie/Questie/releases/latest/download/release.json", Data(json.utf8),
               redirect: "https://github.com/Questie/Questie/releases/download/bundle%2Fv12.9.0%2Bv1.1.1/release.json", modified: modified)
    let source = GitHubAddOnSource(http: http.http)
    let ref = AddOnRef(.github, "Questie/Questie")

    let retail = try await source.latest([ref], flavor: .mainline, interface: 120105)[ref]!.get()
    #expect(retail.download.absoluteString == "https://github.com/Questie/Questie/releases/download/bundle%2Fv12.9.0%2Bv1.1.1/Q-exact.zip")
    #expect(retail.id == "bundle/v12.9.0+v1.1.1")
    #expect(retail.version == "2.0")
    #expect(retail.date == modified)
    // The interface number beats the "wrath" label: 38002 is Titan.
    let titan = try await source.latest([ref], flavor: .titan, interface: nil)[ref]!.get()
    #expect(titan.download.lastPathComponent == "Q-classic.zip")
    #expect(titan.version == "bundle/v12.9.0+v1.1.1")
    #expect(await source.latest([ref], flavor: .wrath, interface: nil)[ref] == .failure(.notForThisVersion))
    let missing = AddOnRef(.github, "Nobody/Nothing")
    #expect(await source.latest([missing], flavor: .mainline, interface: nil)[missing] == .failure(.noRelease))
    let bad = AddOnRef(.github, "../etc")
    #expect(await source.latest([bad], flavor: .mainline, interface: nil)[bad] == .failure(.noRelease))
    #expect(!http.requests.contains { $0.contains("api.github.com") })
}

@Test func tukuiAndWoWInterfaceReleasesAreRead() async throws {
    let http = FakeHTTP()
    http.route("https://api.tukui.org/v1/addons", Data(#"""
    [{"id":-2,"slug":"elvui","name":"ElvUI","author":"Elv","version":"16.01","url":"https://api.tukui.org/v1/download/elvui/abc",
      "patch":["12.1.5","1.15.9"],"directories":["ElvUI","ElvUI_Options"],"last_update":"2026-11-03"}]
    """#.utf8))
    let tukui = TukUIAddOnSource(http: http.http)
    let elvui = AddOnRef(.tukui, "elvui")
    let release = try await tukui.latest([elvui], flavor: .mainline, interface: nil)[elvui]!.get()
    #expect(release.version == "16.01")
    #expect(await tukui.latest([elvui], flavor: .mists, interface: nil)[elvui] == .failure(.notForThisVersion))

    http.route("https://api.mmoui.com/v4/game/WOW/filedetails/4836,5086.json", Data(#"""
    [{"id":"4836","version":"11.2.8","lastUpdate":"1765746422000","checksum":"3FE5","downloadUri":"https://cdn.wowinterface.com/downloads/getfile.php?id=4836"},
     {"id":"5086","version":"v427.9","lastUpdate":"1794170326000","checksum":"ab","downloadUri":"https://evil.example.com/x.zip"}]
    """#.utf8))
    let wowi = WoWInterfaceAddOnSource(http: http.http)
    let omni = AddOnRef(.wowInterface, "4836"), bigwigs = AddOnRef(.wowInterface, "5086")
    let results = await wowi.latest([omni, bigwigs], flavor: .mainline, interface: nil)
    let omniRelease = try results[omni]!.get()
    #expect(omniRelease.md5 == "3fe5")
    #expect(omniRelease.date == Date(timeIntervalSince1970: 1_765_746_422))
    #expect(results[bigwigs] == .failure(.unavailable), "downloads only from WoWInterface")
    #expect(http.requests.filter { $0.contains("mmoui") }.count == 1, "one request for the batch")

    // One ID comes back with numbers where a batch has strings.
    http.route("https://api.mmoui.com/v4/game/WOW/filedetails/4836.json", Data(#"""
    [{"id":4836,"version":"11.2.8","lastUpdate":1765746422000,"checksum":"3fe5","downloadUri":"https://cdn.wowinterface.com/x","pendingUpdate":0}]
    """#.utf8))
    #expect(try await wowi.latest([omni], flavor: .mainline, interface: nil)[omni]!.get().id == "11.2.8|1765746422000")
}

// MARK: Installing

private func library(_ wow: FakeWoW, _ http: FakeHTTP, flavor: WoWFlavor = .mainline) -> AddOnLibrary {
    AddOnLibrary(addOns: wow.addOns, flavor: flavor, interface: 120105, store: wow.store, http: http.http,
                 sources: AddOnSources.live(http: http.http), index: indexForTests,
                 cache: wow.root.appendingPathComponent("Cache"), staging: wow.stagingFunction, trash: wow.trashFunction)
}

private func omniZip(version: String, extra: [TestZip.Entry] = []) -> Data {
    TestZip.make(TestZip.addOn("OmniCC", toc: "## Interface: 120105\n## Version: \(version)\n", lua: "-- \(version)") +
                 TestZip.addOn("OmniCC_Config", toc: "## Interface: 120105\n## Dependencies: OmniCC\n") + extra)
}

@Test func anAddOnInstalledByAnotherAppIsUpdatedAndItsOldCopyGoesToTheTrash() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("OmniCC", ["OmniCC.toc": "## Interface: 120105\n## Version: 11.2.7\n", "Core.lua": "old"])
    try wow.addOn("OmniCC_Config", ["OmniCC_Config.toc": "## Dependencies: OmniCC\n"])
    try wow.addOn("Other", ["Other.toc": retailTOC])
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: wow.addOns.appendingPathComponent("OmniCC/OmniCC.toc").path)
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "11.2.8", zip: omniZip(version: "11.2.8"), filename: "OmniCC-11.2.8.zip",
                metadata: [("mainline", 120105)], version: "11.2.8")
    let wtf = try TreeSnapshot(wow.wtf), before = try TreeSnapshot(wow.addOns)
    let lib = library(wow, http)

    let rows = try await lib.scan()
    let omni = try #require(rows.first { $0.name == "OmniCC" })
    let updates = await lib.check(rows)
    guard case .available(let release) = updates[omni.id] else { Issue.record("no update: \(String(describing: updates[omni.id]))"); return }
    try await lib.install(release, name: omni.name, replacing: omni)

    #expect(try TreeSnapshot(wow.wtf) == wtf)
    #expect(before.changedFolders(to: try TreeSnapshot(wow.addOns)) == ["OmniCC", "OmniCC_Config"])
    #expect(try String(contentsOf: wow.addOns.appendingPathComponent("OmniCC/Core.lua"), encoding: .utf8) == "-- 11.2.8")
    #expect(wow.trashed() == ["OmniCC", "OmniCC_Config"])
    #expect(wow.leftovers().isEmpty)
    let after = try await lib.scan()
    let updated = try #require(after.first { $0.name == "OmniCC" })
    #expect(updated.record?.release.id == "11.2.8")
    #expect(updated.version == "11.2.8")
    guard case .current = await lib.check(after)[updated.id] else { Issue.record("should be current"); return }
}

@Test func anUntouchedCopyWaypointInstalledIsReplacedWithoutTheTrashAndDroppedFoldersGo() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1", extra: TestZip.addOn("OmniCC_Old")), filename: "OmniCC-1.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_000_000))
    let lib = library(wow, http)
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    #expect(try FileManager.default.contentsOfDirectory(atPath: wow.addOns.path).sorted() == ["OmniCC", "OmniCC_Config", "OmniCC_Old"])

    http.github("tullamods/OmniCC", tag: "2", zip: omniZip(version: "2"), filename: "OmniCC-2.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let rows = try await lib.scan()
    let omni = try #require(rows.first { $0.name == "OmniCC" })
    #expect(omni.folders == ["OmniCC", "OmniCC_Config", "OmniCC_Old"])
    guard case .available(let release) = await lib.check(rows)[omni.id] else { Issue.record("no update"); return }
    try await lib.install(release, name: omni.name, replacing: omni)
    #expect(try FileManager.default.contentsOfDirectory(atPath: wow.addOns.path).sorted() == ["OmniCC", "OmniCC_Config"])
    #expect(wow.trashed().isEmpty, "a published release isn't worth keeping")
    #expect(wow.leftovers().isEmpty)
}

@Test func changedFilesAreKeptUnlessThePersonAsks() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    let lib = library(wow, http)
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    try Data("-- my edit".utf8).write(to: wow.addOns.appendingPathComponent("OmniCC/Core.lua"))
    http.github("tullamods/OmniCC", tag: "2", zip: omniZip(version: "1"), filename: "OmniCC-2.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let rows = try await lib.scan()
    let omni = try #require(rows.first { $0.name == "OmniCC" })
    guard case .available(let release) = await lib.check(rows)[omni.id] else { Issue.record("no update"); return }
    await #expect(throws: AddOnError.changedLocally) { try await lib.install(release, name: omni.name, replacing: omni) }
    #expect(try String(contentsOf: wow.addOns.appendingPathComponent("OmniCC/Core.lua"), encoding: .utf8) == "-- my edit")
    try await lib.install(release, name: omni.name, replacing: omni, evenIfChanged: true)
    #expect(wow.trashed() == ["OmniCC", "OmniCC_Config"], "the edited copy is kept in the Trash")
}

@Test func anotherAddOnsFolderIsNeverTakenOver() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("ElvUI", ["ElvUI.toc": "## X-Tukui-ProjectID: -2\n## Version: 16.00\n"])
    try wow.addOn("ElvUI_Options", ["ElvUI_Options.toc": "## Dependencies: ElvUI\n"])
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1", extra: TestZip.addOn("ElvUI")), filename: "OmniCC-1.zip",
                metadata: [("mainline", 120105)])
    let before = try TreeSnapshot(wow.addOns)
    await #expect(throws: AddOnError.conflict(folder: "ElvUI", owner: "ElvUI")) {
        try await library(wow, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    }
    #expect(try TreeSnapshot(wow.addOns) == before)
    #expect(wow.leftovers().isEmpty)
}

@Test func linksAndCheckoutsAreNeverReplaced() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let elsewhere = wow.root.appendingPathComponent("MyOmniCC", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: wow.addOns.appendingPathComponent("OmniCC"), withDestinationURL: elsewhere)
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    await #expect(throws: AddOnError.notSafe("OmniCC")) {
        try await library(wow, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: wow.addOns.appendingPathComponent("OmniCC").path) == elsewhere.path)
}

@Test(arguments: AddOnInstaller.Step.allCases)
func aFailureAtAnyStepPutsEverythingBack(step: AddOnInstaller.Step) throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("A", ["A.toc": retailTOC, "Core.lua": "old"])
    try wow.addOn("A_Options", ["A_Options.toc": retailTOC])
    let staged = wow.root.appendingPathComponent("staged", isDirectory: true)
    for name in ["A", "A_Options", "A_New"] {
        try FileManager.default.createDirectory(at: staged.appendingPathComponent(name), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("\(name)/\(name).toc"))
    }
    let before = try TreeSnapshot(wow.addOns), wtf = try TreeSnapshot(wow.wtf)
    for deletesOld in [true, false] {
        var installer = AddOnInstaller(addOns: wow.addOns, trash: wow.trashFunction)
        let count = Counter()
        // Fail on the second time the step comes round, after one move.
        installer.fault = { if $0 == step, count.next() == 2 { throw CocoaError(.fileWriteOutOfSpace) } }
        let plan = AddOnInstaller.Plan(remove: ["A", "A_Options"], install: ["A", "A_Options", "A_New"],
                                       deletes: deletesOld ? ["A", "A_Options"] : [])
        #expect(throws: CocoaError.self) { try installer.swap(plan, staged: staged, old: wow.root.appendingPathComponent("old-\(deletesOld)")) }
        #expect(try TreeSnapshot(wow.addOns) == before)
        #expect(try TreeSnapshot(wow.wtf) == wtf)
    }
}

/// Dominos' zip carries Masque_Dominos, which WoWInterface also lists as
/// its own add-on: the reviewed zip takes it over, to the Trash. A zip from
/// WoWInterface, which anyone can upload to, may not.
@Test func aReviewedZipTakesOverAnAddOnItShipsWhole() async throws {
    for source in [AddOnSourceID.github, .wowInterface] {
        let wow = try FakeWoW()
        defer { wow.remove() }
        try wow.addOn("OmniCC", ["OmniCC.toc": "## Version: 1\n"])
        try wow.addOn("Masque_OmniCC", ["Masque_OmniCC.toc": "## X-WoWI-ID: 26455\n"])
        let rows = AddOnMatcher(index: indexForTests).match(try AddOnScanner().scan(wow.addOns, flavor: .mainline), records: [])
        let target = try #require(rows.first { $0.name == "OmniCC" })
        let others = rows.filter { $0.id != target.id }
        let folders = try AddOnScanner().scan(wow.addOns, flavor: .mainline)
        if source == .github {
            let plan = try AddOnInstaller.plan(package: ["OmniCC", "Masque_OmniCC"], target: target, others: others,
                                               onDisk: folders, targetUntouched: true, mayAbsorb: true)
            #expect(plan.remove == ["OmniCC", "Masque_OmniCC"])
            #expect(plan.deletes.isEmpty, "nothing here was installed by Waypoint: all to the Trash")
        } else {
            #expect(throws: AddOnError.conflict(folder: "Masque_OmniCC", owner: "Masque_OmniCC")) {
                try AddOnInstaller.plan(package: ["OmniCC", "Masque_OmniCC"], target: target, others: others,
                                        onDisk: folders, targetUntouched: true, mayAbsorb: false)
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@Test func removingAnAddOnTrashesItsFoldersAndKeepsItsSettings() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("OmniCC", ["OmniCC.toc": retailTOC])
    try wow.addOn("OmniCC_Config", ["OmniCC_Config.toc": "## Dependencies: OmniCC\n"])
    try wow.addOn("MyTweaks", ["MyTweaks.toc": retailTOC])
    let wtf = try TreeSnapshot(wow.wtf)
    let lib = library(wow, FakeHTTP())
    let rows = try await lib.scan()
    try await lib.remove(try #require(rows.first { $0.name == "OmniCC" }))
    #expect(try FileManager.default.contentsOfDirectory(atPath: wow.addOns.path) == ["MyTweaks"])
    #expect(wow.trashed() == ["OmniCC", "OmniCC_Config"])
    #expect(try TreeSnapshot(wow.wtf) == wtf)
    // Waypoint doesn't remove what it doesn't update.
    await #expect(throws: AddOnError.self) { try await lib.remove(try #require(rows.first { $0.name == "MyTweaks" })) }
}

@Test func wowInterfaceDownloadsMustMatchTheirChecksum() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    let zip = TestZip.make(TestZip.addOn("TomTom"))
    http.file("https://cdn.wowinterface.com/downloads/getfile.php?id=4111", zip)
    let release = AddOnRelease(ref: AddOnRef(.wowInterface, "4111"), id: "1|1", version: "1", date: nil,
                               download: URL(string: "https://cdn.wowinterface.com/downloads/getfile.php?id=4111")!, md5: "00")
    await #expect(throws: AddOnError.checksum) { try await library(wow, http).install(release, name: "TomTom", replacing: nil) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: wow.addOns.path).isEmpty)
}

@Test func theStoreKeepsRecordsPerFolderAndForgetsBadFiles() throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let release = AddOnRelease(ref: AddOnRef(.github, "a/b"), id: "1", version: "1", date: nil, download: URL(string: "https://github.com/x")!)
    let record = AddOnRecord(ref: release.ref, name: "B", mainFolder: "B", folders: ["B"], release: release, folderHashes: [:], tocVersion: nil)
    try wow.store.save([record], for: wow.addOns)
    #expect(wow.store.load(for: wow.addOns) == [record])
    #expect(wow.store.load(for: wow.root.appendingPathComponent("_classic_/Interface/AddOns")).isEmpty)
    try Data("{".utf8).write(to: wow.store.file(for: wow.addOns))
    #expect(wow.store.load(for: wow.addOns).isEmpty)
}

@Test func searchFindsTheIndexThenWoWInterfaceAndCachesTheList() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    http.route(WoWInterfaceAddOnSource.listURL.absoluteString, Data(#"""
    [{"UID":"1","UIName":"OmniBar","UIAuthorName":"x","UIDate":1794000000000,"UIDownloadTotal":"5"},
     {"UID":"2","UIName":"Old Omni Thing","UIDate":1000000000000,"UICompatibility":[{"version":"8.3.0"}]},
     {"UID":"3","UIName":"Omni Classic","UIDate":1000000000000,"UICompatibility":[{"version":"1.15.7"}]}]
    """#.utf8))
    let lib = AddOnLibrary(addOns: wow.addOns, flavor: .mainline, interface: 120105, store: wow.store, http: http.http,
                           index: indexForTests, cache: wow.root.appendingPathComponent("Cache"),
                           staging: wow.stagingFunction, trash: wow.trashFunction, now: { now })
    let results = try await lib.search("omni")
    #expect(results.map(\.name) == ["OmniCC", "OmniBar", "Old Omni Thing"])
    _ = try await lib.search("bar")
    #expect(http.requests.filter { $0.contains("filelist") }.count == 1)
}

@Test func recordsOutliveAnAddOnsFolderThatIsAwayForAWhile() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    let lib = library(wow, http)
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    // "Rename Interface to test without add-ons", then put it back.
    let aside = wow.game.appendingPathComponent("Interface-off")
    try FileManager.default.moveItem(at: wow.game.appendingPathComponent("Interface"), to: aside)
    #expect(try await lib.scan().isEmpty)
    try FileManager.default.moveItem(at: aside, to: wow.game.appendingPathComponent("Interface"))
    #expect(try await lib.scan().first { $0.name == "OmniCC" }?.record != nil)
}

@Test func aModuleSomeoneDeletedDoesntStopUpdatesAndComesBack() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    let lib = library(wow, http)
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    try FileManager.default.removeItem(at: wow.addOns.appendingPathComponent("OmniCC_Config"))
    http.github("tullamods/OmniCC", tag: "2", zip: omniZip(version: "1"), filename: "OmniCC-2.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let rows = try await lib.scan()
    let omni = try #require(rows.first { $0.name == "OmniCC" })
    guard case .available(let release) = await lib.check(rows)[omni.id] else { Issue.record("no update"); return }
    try await lib.install(release, name: omni.name, replacing: omni)
    #expect(try FileManager.default.contentsOfDirectory(atPath: wow.addOns.path).sorted() == ["OmniCC", "OmniCC_Config"])
    #expect(wow.trashed().isEmpty)
}

@Test func anInstallNeverMakesUpAGameFolder() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try FileManager.default.removeItem(at: wow.game)
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    await #expect(throws: (any Error).self) { try await library(wow, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC") }
    #expect(!FileManager.default.fileExists(atPath: wow.game.path))

    // A game that hasn't run yet gets its AddOns folder.
    let fresh = try FakeWoW(makeAddOns: false)
    defer { fresh.remove() }
    try await library(fresh, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    #expect(FileManager.default.fileExists(atPath: fresh.addOns.appendingPathComponent("OmniCC").path))
}

@Test func anAutomaticUpdateHoldsOffWhileTheGameRuns() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    let lib = library(wow, http)
    let release = try await GitHubAddOnSource(http: http.http).latest([AddOnRef(.github, "tullamods/OmniCC")], flavor: .mainline, interface: nil)
        .values.first!.get()
    let before = try TreeSnapshot(wow.addOns)
    // Started while the download ran: the second look stops the swap.
    let calls = Counter()
    await #expect(throws: AddOnError.gameRunning) {
        try await lib.install(release, name: "OmniCC", replacing: nil, holds: { calls.next() > 1 })
    }
    #expect(try TreeSnapshot(wow.addOns) == before)
    #expect(wow.leftovers().isEmpty)
}

@Test func takingOverARecordedAddOnDropsItsRecordAndUnmanagedExtrasGoToTheTrash() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    // Waypoint installed the skin on its own, from WoWInterface.
    let skin = TestZip.make(TestZip.addOn("Masque_OmniCC", toc: "## Interface: 120105\n## X-WoWI-ID: 26455\n"))
    http.file("https://cdn.wowinterface.com/26455.zip", skin)
    let skinRelease = AddOnRelease(ref: AddOnRef(.wowInterface, "26455"), id: "1|1", version: "1", date: nil,
                                   download: URL(string: "https://cdn.wowinterface.com/26455.zip")!)
    let lib = library(wow, http)
    try await lib.install(skinRelease, name: "Masque_OmniCC", replacing: nil)
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    // Something else left a copy of a folder OmniCC's next zip adds.
    try wow.addOn("OmniCC_Extra", ["OmniCC_Extra.toc": retailTOC])
    let bundle = omniZip(version: "2", extra: TestZip.addOn("Masque_OmniCC", toc: "## Interface: 120105\n## X-WoWI-ID: 26455\n") +
                         TestZip.addOn("OmniCC_Extra"))
    http.github("tullamods/OmniCC", tag: "2", zip: bundle, filename: "OmniCC-2.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let rows = try await lib.scan()
    let omni = try #require(rows.first { $0.name == "OmniCC" })
    guard case .available(let release) = await lib.check(rows)[omni.id] else { Issue.record("no update"); return }
    try await lib.install(release, name: omni.name, replacing: omni)
    #expect(wow.trashed() == ["Masque_OmniCC", "OmniCC_Extra"], "only OmniCC's own untouched copy is deleted")
    let records = wow.store.load(for: wow.addOns)
    #expect(records.map(\.ref) == [AddOnRef(.github, "tullamods/OmniCC")])
    #expect(records[0].folders == ["Masque_OmniCC", "OmniCC", "OmniCC_Config", "OmniCC_Extra"])
}

// MARK: Live

/// Real sources, no key: `WAYPOINT_NETWORK_TESTS=1 xcrun swift test --filter liveAddOnSources`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAYPOINT_NETWORK_TESTS"] == "1"))
func liveAddOnSources() async throws {
    let http = AddOnHTTP.live
    let dbm = AddOnRef(.github, "DeadlyBossMods/DeadlyBossMods")
    let release = try await GitHubAddOnSource(http: http).latest([dbm], flavor: .mainline, interface: nil)[dbm]!.get()
    #expect(release.download.host == "github.com")
    #expect(release.date != nil)
    let weakAuras = AddOnRef(.github, "WeakAuras/WeakAuras2")
    let wa = await GitHubAddOnSource(http: http).latest([weakAuras], flavor: .vanilla, interface: nil)[weakAuras]
    #expect((try? wa?.get()) != nil)
    let elvui = AddOnRef(.tukui, "elvui")
    #expect((try? await TukUIAddOnSource(http: http).latest([elvui], flavor: .mainline, interface: nil)[elvui]?.get()) != nil)
    let omni = AddOnRef(.wowInterface, "4836")
    let wowi = try await WoWInterfaceAddOnSource(http: http).latest([omni], flavor: .mainline, interface: nil)[omni]!.get()
    #expect(wowi.md5?.count == 32)

    // End to end into a temp folder.
    let wow = try FakeWoW()
    defer { wow.remove() }
    let lib = AddOnLibrary(addOns: wow.addOns, flavor: .mainline, interface: nil, store: wow.store, http: http,
                           cache: wow.root.appendingPathComponent("Cache"), staging: wow.stagingFunction, trash: wow.trashFunction)
    let wtf = try TreeSnapshot(wow.wtf)
    try await lib.install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    let rows = try await lib.scan()
    #expect(rows.first { $0.name == "OmniCC" }?.record != nil)
    #expect(try TreeSnapshot(wow.wtf) == wtf)
}

// MARK: Automatic updates (the model)

@MainActor
private func waitUntilIdle(_ model: AddOnsModel) async throws {
    for _ in 0..<500 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isBusy)
}

private func wowGame(_ wow: FakeWoW, version: String = "12.1.5.1") -> Game {
    Game(install: ProductInstall(uid: "wow", productCode: "wow", installPath: wow.root.path, version: version),
         family: .worldOfWarcraft, displayName: "World of Warcraft", appURL: wow.game.appendingPathComponent("World of Warcraft.app"),
         architectures: [.arm64])
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isSet: Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}

@MainActor
@Test func automaticUpdatesTouchOnlyWhatWaypointInstalledAndWaitForTheGame() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    try await library(wow, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    // DBM came from somewhere else; Waypoint recognizes it but never asked.
    try wow.addOn("DBM-Core", ["DBM-Core.toc": "## Interface: 120105\n## Version: 1\n## X-Curse-Project-ID: 3358\n"])
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                          ofItemAtPath: wow.addOns.appendingPathComponent("DBM-Core/DBM-Core.toc").path)
    http.github("DeadlyBossMods/DeadlyBossMods", tag: "2", zip: TestZip.make(TestZip.addOn("DBM-Core")), filename: "DBM-2.zip",
                metadata: [("mainline", 120105)], version: "2")
    http.github("tullamods/OmniCC", tag: "2", zip: omniZip(version: "2"), filename: "OmniCC-2.zip",
                metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let running = Flag(true)
    let model = AddOnsModel(makeLibrary: { _ in library(wow, http) }, holdCheck: { _ in { running.isSet } })
    let game = wowGame(wow)
    let before = try TreeSnapshot(wow.addOns)

    model.updateAutomatically(game)
    try await waitUntilIdle(model)
    #expect(try TreeSnapshot(wow.addOns) == before, "the game is open: nothing moves")

    running.set(false)
    model.gameQuit(game)
    try await waitUntilIdle(model)
    #expect(try String(contentsOf: wow.addOns.appendingPathComponent("OmniCC/Core.lua"), encoding: .utf8) == "-- 2")
    #expect(try String(contentsOf: wow.addOns.appendingPathComponent("DBM-Core/DBM-Core.toc"), encoding: .utf8).contains("## Version: 1"))
    #expect(!http.requests.contains { $0.contains("DBM-2.zip") })
}

@MainActor
@Test func someoneWhoNeverUsedTheSheetCausesNoRequests() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    try wow.addOn("OmniCC", ["OmniCC.toc": "## Interface: 120105\n## Version: 1\n"])
    let http = FakeHTTP()
    let model = AddOnsModel(makeLibrary: { _ in library(wow, http) }, holdCheck: { _ in { false } })
    model.updateAutomatically(wowGame(wow))
    try await waitUntilIdle(model)
    #expect(http.requests.isEmpty)
}

@MainActor
@Test func aZipThatCantInstallIsntDownloadedAgainButADroppedConnectionIs() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    http.github("tullamods/OmniCC", tag: "1", zip: omniZip(version: "1"), filename: "OmniCC-1.zip", metadata: [("mainline", 120105)])
    try await library(wow, http).install(AddOnRef(.github, "tullamods/OmniCC"), name: "OmniCC")
    // Release 2's zip has a loose file: refused, every time.
    http.github("tullamods/OmniCC", tag: "2", zip: omniZip(version: "2", extra: [.file("README.txt", Data("x".utf8))]),
                filename: "OmniCC-2.zip", metadata: [("mainline", 120105)], released: Date(timeIntervalSince1970: 1_790_100_000))
    let model = AddOnsModel(makeLibrary: { _ in library(wow, http) }, holdCheck: { _ in { false } })
    let game = wowGame(wow)
    for _ in 0..<3 {
        model.updateAutomatically(game)
        try await waitUntilIdle(model)
    }
    #expect(http.requests.filter { $0.hasSuffix("OmniCC-2.zip") }.count == 1)

    // Release 3 comes down damaged (as when a connection drops): tried each time.
    http.github("tullamods/OmniCC", tag: "3", zip: Data(), filename: "OmniCC-3.zip", metadata: [("mainline", 120105)],
                released: Date(timeIntervalSince1970: 1_790_200_000))
    http.file("https://github.com/tullamods/OmniCC/releases/download/3/OmniCC-3.zip", Data("<html>".utf8))
    for _ in 0..<2 {
        model.updateAutomatically(game)
        try await waitUntilIdle(model)
    }
    #expect(http.requests.filter { $0.hasSuffix("OmniCC-3.zip") }.count == 2)
}

@MainActor
@Test func aPassAskedForDuringAnotherRunsAgainWithTheNewBuild() async throws {
    let wow = try FakeWoW()
    defer { wow.remove() }
    let http = FakeHTTP()
    let versions = Versions()
    let model = AddOnsModel(makeLibrary: { game in versions.add(game.install.version); return library(wow, http) },
                            holdCheck: { _ in { false } })
    model.updateAutomatically(wowGame(wow, version: "12.1.5.1"))
    model.updateAutomatically(wowGame(wow, version: "12.1.7.2"))
    try await waitUntilIdle(model)
    #expect(versions.all.last == "12.1.7.2")
}

private final class Versions: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String?] = []
    func add(_ version: String?) { lock.withLock { list.append(version) } }
    var all: [String?] { lock.withLock { list } }
}
