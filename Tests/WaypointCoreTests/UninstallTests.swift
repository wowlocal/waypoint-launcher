import Foundation
import Testing
@testable import WaypointCore

/// A temporary folder with a stand-in Trash; files are created on demand.
private struct Sandbox {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-uninstall-\(UUID().uuidString)")
    var trashDir: URL { dir.appendingPathComponent("Trash") }
    var store: InstallStateStore { InstallStateStore(file: dir.appendingPathComponent("installs.json")) }

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Trash"), withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    /// Creates the files (and their folders) under `root`; a path ending
    /// in `/` is an empty folder.
    @discardableResult
    func make(_ root: String, _ paths: [String]) throws -> URL {
        let base = dir.appendingPathComponent(root, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for path in paths {
            let url = base.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(path.utf8).write(to: url)
            }
        }
        return base
    }

    func uninstaller(_ install: ProductInstall, name: String, keeping: Bool = true, others: [ProductInstall] = []) -> GameUninstaller {
        var uninstaller = GameUninstaller(install: install, displayName: name, keepsUserFiles: keeping, otherInstalls: others, store: store)
        let trashDir = trashDir
        uninstaller.trash = { try FileManager.default.moveItem(at: $0, to: trashDir.appendingPathComponent($0.lastPathComponent)) }
        uninstaller.windowsSupport = dir.appendingPathComponent("Support")
        return uninstaller
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
}

private let buildInfoHeader = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0"
private let wowApp = "_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
private let eraApp = "_classic_era_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic"

private func wow(_ root: URL, _ code: String = "wow") -> ProductInstall {
    ProductInstall(uid: code, productCode: code, installPath: root.path, region: "eu")
}

@Test func aGameAloneInItsFolderGoesToTheTrashWithIt() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("Hearthstone", ["Hearthstone.app/Contents/Info.plist", "Data/x", "Logs/hs.log", ".product.db"])
    let install = InstallableProduct.hearthstone.install(at: root, region: .eu, language: "enUS", tagString: "OSX EU? enUS text?")
    try box.store.record(install: install, InstalledBuild(buildConfig: "abc", version: "36.6.3"))

    let uninstaller = box.uninstaller(install, name: "Hearthstone")
    let plan = try uninstaller.plan()
    #expect(plan.removesFolder)
    #expect(plan.trashed == [root.standardizedFileURL])
    #expect(!plan.sharesStorage)
    try uninstaller.carryOut(plan)

    #expect(!box.exists("Hearthstone"))
    #expect(box.exists("Trash/Hearthstone/Hearthstone.app/Contents/Info.plist"))
    #expect(box.store.load().isEmpty, "the record goes with the game")
}

@Test func aWoWVersionSharingItsFolderTakesOnlyItsOwnFilesAndLeavesItsAddOns() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("World of Warcraft", [
        wowApp, "_retail_/Cache/x", "_retail_/.flavor.info", "_retail_/Interface/AddOns/Details/Details.toc",
        "_retail_/WTF/Config.wtf", "_retail_/Screenshots/1.jpg", eraApp, "_classic_era_/Interface/AddOns/Questie/Questie.toc",
        "Data/data/data.000",
    ])
    let buildInfo = "\(buildInfoHeader)\neu|1|aaaa|12.1.5|wow\neu|1|bbbb|1.15.8|wow_classic_era\n"
    try Data(buildInfo.utf8).write(to: root.appendingPathComponent(".build.info"))

    let uninstaller = box.uninstaller(wow(root), name: "World of Warcraft")
    let plan = try uninstaller.plan()
    #expect(plan.sharesStorage)
    #expect(!plan.removesFolder)
    #expect(plan.userFiles == ["_retail_/Interface", "_retail_/Screenshots", "_retail_/WTF"])
    #expect(plan.items == ["_retail_/.flavor.info", "_retail_/Cache", "_retail_/World of Warcraft.app"])
    try uninstaller.carryOut(plan)

    #expect(!box.exists(wowApp))
    #expect(box.exists("World of Warcraft/_retail_/Interface/AddOns/Details/Details.toc"))
    #expect(box.exists("World of Warcraft/_retail_/WTF/Config.wtf"))
    #expect(box.exists("World of Warcraft/\(eraApp)"), "the other version stays")
    #expect(box.exists("World of Warcraft/Data/data/data.000"), "the shared storage stays")
    #expect(try String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8)
            == "\(buildInfoHeader)\neu|1|bbbb|1.15.8|wow_classic_era\n")
    #expect(box.exists("Trash/World of Warcraft/\(wowApp)"), "one folder, named after the game, goes to the Trash")
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.trashDir.path) == ["World of Warcraft"])
    #expect(!box.exists("World of Warcraft/World of Warcraft"))
}

@Test func aSharedWoWVersionCanTakeItsAddOnsAlong() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("World of Warcraft", [wowApp, "_retail_/Interface/AddOns/x.toc", eraApp, "Data/data/data.000"])
    try Data("\(buildInfoHeader)\neu|1|aaaa|12.1.5|wow\neu|1|bbbb|1.15.8|wow_classic_era\n".utf8)
        .write(to: root.appendingPathComponent(".build.info"))

    let plan = try box.uninstaller(wow(root), name: "World of Warcraft", keeping: false).plan()
    #expect(plan.items == ["_retail_"])
    #expect(!plan.keepsUserFiles)
    try box.uninstaller(wow(root), name: "World of Warcraft", keeping: false).carryOut(plan)
    #expect(!box.exists("World of Warcraft/_retail_"))
    #expect(box.exists("Trash/World of Warcraft/_retail_/Interface/AddOns/x.toc"))
}

@Test func theLastWoWVersionLeavesItsAddOnsAndOtherVersionsFolders() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // _classic_era_ is what an earlier uninstall left: its add-ons, no game.
    let root = try box.make("World of Warcraft", [
        wowApp, "_retail_/Interface/AddOns/x.toc", "_retail_/WTF/Config.wtf", "_retail_/Logs/x.log",
        "_classic_era_/Interface/AddOns/Questie/Questie.toc", "Data/data/data.000", ".waypoint-platform",
    ])
    try Data("\(buildInfoHeader)\neu|1|aaaa|12.1.5|wow\neu|1|bbbb|1.15.8|wow_classic_era\n".utf8)
        .write(to: root.appendingPathComponent(".build.info"))

    let uninstaller = box.uninstaller(wow(root), name: "World of Warcraft")
    let plan = try uninstaller.plan()
    #expect(!plan.sharesStorage, "a row whose game is gone doesn't share anything")
    #expect(plan.items == [".build.info", ".waypoint-platform", "Data", "_retail_/Logs", "_retail_/World of Warcraft.app"])
    try uninstaller.carryOut(plan)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["_classic_era_", "_retail_"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("_retail_").path).sorted() == ["Interface", "WTF"])
    #expect(box.exists("World of Warcraft/_classic_era_/Interface/AddOns/Questie/Questie.toc"))

    // Without leftovers and with nothing kept, the whole folder goes.
    let other = try box.make("Other/World of Warcraft", [wowApp, "_retail_/Interface/AddOns/x.toc", "Data/data/data.000"])
    let whole = try box.uninstaller(wow(other), name: "World of Warcraft", keeping: false).plan()
    #expect(whole.removesFolder)
}

@Test func aFailedMoveToTheTrashPutsEverythingBack() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("World of Warcraft", [wowApp, "_retail_/Cache/x", "_retail_/WTF/Config.wtf", eraApp])
    let buildInfo = "\(buildInfoHeader)\r\neu|1|aaaa|12.1.5|wow\r\neu|1|bbbb|1.15.8|wow_classic_era\r\n"
    try Data(buildInfo.utf8).write(to: root.appendingPathComponent(".build.info"))
    let install = wow(root)
    try box.store.record(install: install, InstalledBuild(buildConfig: "aaaa", version: "12.1.5"))

    var uninstaller = box.uninstaller(install, name: "World of Warcraft")
    uninstaller.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    #expect(throws: CocoaError.self) { try uninstaller.carryOut(try uninstaller.plan()) }

    #expect(box.exists("World of Warcraft/\(wowApp)"))
    #expect(box.exists("World of Warcraft/_retail_/Cache/x"))
    #expect(!box.exists("World of Warcraft/World of Warcraft"), "no folder is left behind")
    #expect(try String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8) == buildInfo)
    #expect(box.store.load()["wow"] != nil)
}

@Test func buildInfoLosesOnlyTheProductsRows() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("W", [])
    let url = root.appendingPathComponent(".build.info")
    try Data("## seqn = 1\r\n\(buildInfoHeader)\r\neu|1|aaaa|12.1.5|wow\r\neu|1|bbbb|1.15.8|wow_classic_era\r\n".utf8).write(to: url)
    _ = try GameUninstaller.dropBuildInfoRows(url, products: ["wow_classic_era"])
    #expect(try String(contentsOf: url, encoding: .utf8) == "## seqn = 1\r\n\(buildInfoHeader)\r\neu|1|aaaa|12.1.5|wow\r\n")
    #expect(GameUninstaller.buildInfoProducts(in: root) == ["wow"])
}

@Test func foldersThatAreNotAGamesOwnAreNeverRemovedWhole() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    for folder in [home, home.appendingPathComponent("Games"), home.appendingPathComponent("Desktop"),
                   URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Games")] {
        #expect(GameUninstaller.isProtected(folder), "\(folder.path)")
    }
    #expect(!GameUninstaller.isProtected(URL(fileURLWithPath: "/Applications/Hearthstone")))
    #expect(!GameUninstaller.isProtected(home.appendingPathComponent("Games/Overwatch (Windows)")))

    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("Games", ["Hearthstone.app/Contents/Info.plist"])
    let install = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: root.path)
    let inside = ProductInstall(uid: "s2", productCode: "s2", installPath: root.appendingPathComponent("StarCraft II").path)
    #expect(throws: UninstallError.holdsOtherGames(root.standardizedFileURL.path)) {
        try box.uninstaller(install, name: "Hearthstone", others: [inside]).plan()
    }
}

@Test func aWindowsGameKeepsItsSavesUnlessAskedThenTrashesThem() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let save = "Support/Windows/osi/prefix-v1/drive_c/users/x/Saved Games/Diablo II Resurrected/Hero.d2s"
    func installD2R() throws -> ProductInstall {
        let root = try box.make("Diablo II Resurrected (Windows)", ["D2R.exe", ".waypoint-platform"])
        try box.make("", [String(save.dropFirst(0)), "Support/Windows/osi/launch.lock"])
        return ProductInstall(uid: "osi", productCode: "osi", installPath: root.path, platform: .windows)
    }
    try box.make("Support/Windows/fenris", ["prefix-v1/system.reg"])

    var install = try installD2R()
    let keeping = box.uninstaller(install, name: "Diablo II: Resurrected")
    let kept = try keeping.plan()
    #expect(kept.removesFolder)
    #expect(kept.hasUserFiles && kept.keepsUserFiles)
    #expect(kept.trashed == [kept.root], "the saves stay out of the Trash")
    try keeping.carryOut(kept)
    #expect(box.exists(save), "saved games stay for a reinstall")

    try FileManager.default.removeItem(at: box.trashDir)
    try FileManager.default.createDirectory(at: box.trashDir, withIntermediateDirectories: true)
    install = try installD2R()
    let removing = box.uninstaller(install, name: "Diablo II: Resurrected", keeping: false)
    let plan = try removing.plan()
    #expect(!plan.keepsUserFiles)
    #expect(plan.trashed.map(\.lastPathComponent) == ["Diablo II Resurrected (Windows)", "osi"])
    try removing.carryOut(plan)
    #expect(!box.exists("Support/Windows/osi"))
    #expect(box.exists("Trash/Diablo II- Resurrected saved games and settings/prefix-v1/drive_c/users/x/Saved Games/Diablo II Resurrected/Hero.d2s"),
            "nothing is deleted: the saves go to the Trash, named for the game")
    #expect(box.exists("Support/Windows/fenris/prefix-v1/system.reg"), "other games' setups stay")
}

@Test func leftoverRowsOfOtherProductsDontShareTheFolder() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("Warcraft III", ["_retail_/x86_64/Warcraft III.app/Contents/Info.plist", "_retail_/.flavor.info", "Data/data/data.000"])
    try Data("Product Flavor!STRING:0\nw3\n".utf8).write(to: root.appendingPathComponent("_retail_/.flavor.info"))
    try Data("\(buildInfoHeader)\nus|1|aaaa|2.0.3|w3\nus|1|bbbb|2.0.4|w3t\n".utf8).write(to: root.appendingPathComponent(".build.info"))
    let install = ProductInstall(uid: "w3", productCode: "w3", installPath: root.path, region: "us")

    #expect(try box.uninstaller(install, name: "Warcraft III").plan().removesFolder, "the PTR's row is all that's left of it")

    try box.make("Warcraft III", ["_ptr_/x86_64/Warcraft III Public Test.app/Contents/Info.plist"])
    try Data("Product Flavor!STRING:0\nw3t\n".utf8).write(to: root.appendingPathComponent("_ptr_/.flavor.info"))
    let shared = try box.uninstaller(install, name: "Warcraft III").plan()
    #expect(shared.sharesStorage, "an installed PTR shares the storage")
    #expect(shared.items == ["_retail_"])
}

@Test func anotherListedGameInTheFolderSharesIt() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // No .build.info at all: only the library says WoW Classic Era is there.
    let root = try box.make("World of Warcraft", [wowApp, "_retail_/fonts/x.ttf", eraApp, "Data/data/data.000"])
    let plan = try box.uninstaller(wow(root), name: "World of Warcraft", others: [wow(root, "wow_classic_era")]).plan()
    #expect(plan.sharesStorage)
    #expect(plan.userFiles == ["_retail_/fonts"], "user folders match whatever their case")
    #expect(plan.items == ["_retail_/World of Warcraft.app"])
}

@Test func aGameInstalledRightInAStandardFolderIsRefused() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let install = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: home.path)
    let uninstaller = GameUninstaller(install: install, displayName: "Hearthstone", keepsUserFiles: true, otherInstalls: [])
    #expect(throws: UninstallError.protectedFolder(home.standardizedFileURL.path)) { try uninstaller.plan() }
}

@Test func aMoveFailingPartWayPutsBackWhatMoved() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("World of Warcraft", [wowApp, "_retail_/Logs/x.log", "_retail_/WTF/Config.wtf", "Data/data/data.000"])
    try Data("\(buildInfoHeader)\neu|1|aaaa|12.1.5|wow\n".utf8).write(to: root.appendingPathComponent(".build.info"))
    let uninstaller = box.uninstaller(wow(root), name: "World of Warcraft")
    let plan = try uninstaller.plan()
    #expect(plan.items == [".build.info", "Data", "_retail_/Logs", "_retail_/World of Warcraft.app"])

    // Root-level items move; nothing can leave _retail_.
    let retail = root.appendingPathComponent("_retail_").path
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: retail)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: retail) }
    #expect(throws: (any Error).self) { try uninstaller.carryOut(plan) }

    #expect(box.exists("World of Warcraft/.build.info"))
    #expect(box.exists("World of Warcraft/Data/data/data.000"))
    #expect(box.exists("World of Warcraft/\(wowApp)"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [".build.info", "Data", "_retail_"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.trashDir.path).isEmpty)
}

@Test func theLibraryListsACopyOnDiskOverOneBattleNetLostTrackOf() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // Battle.net installed Hearthstone at P; it was uninstalled in Waypoint
    // and installed again at Q. Battle.net's database still names P.
    let p = box.dir.appendingPathComponent("Old/Hearthstone"), q = try box.make("Hearthstone", ["Hearthstone.app/Contents/Info.plist"])
    var db = ProtoWriter()
    db.message(1) { i in
        i.string(1, "hs_beta"); i.string(2, "hsb")
        i.message(3) { s in s.string(1, p.path); s.string(2, "eu") }
    }
    let dbFile = box.dir.appendingPathComponent("product.db")
    try db.data.write(to: dbFile)
    let install = InstallableProduct.hearthstone.install(at: q, region: .eu, language: "enUS", tagString: "OSX EU? enUS text?")
    try box.store.record(install: install, InstalledBuild(buildConfig: "abc", version: "36.6.3"))

    let library = GameLibrary(agentDatabase: dbFile, searchRoots: [], stateStore: box.store)
    #expect(library.installs().map(\.installPath) == [q.standardizedFileURL.path])
    #expect(library.installs().first?.version == "36.6.3")

    try box.make("Old/Hearthstone", ["Hearthstone.app/Contents/Info.plist"])
    #expect(library.installs().map(\.installPath) == [p.path], "with both on disk, Battle.net's stays authoritative")
}

@Test func forgettingAnInstallLeavesOtherCopiesRecords() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let store = box.store
    let here = ProductInstall(uid: "wow", productCode: "wow", installPath: "/Applications/World of Warcraft")
    let elsewhere = ProductInstall(uid: "wow", productCode: "wow", installPath: "/Volumes/Test/World of Warcraft")
    let hots = ProductInstall(uid: "heroes", productCode: "hero", installPath: "/Users/x/Games/Heroes of the Storm (Windows)", platform: .windows)
    try store.record(install: here, InstalledBuild(buildConfig: "aaaa", version: "12.1.5"))
    try store.record(install: hots, InstalledBuild(buildConfig: "dddd", version: "2.57"))

    try store.remove(elsewhere)
    #expect(store.load()["wow"] != nil, "another copy's record stays")
    try store.remove(here)
    #expect(store.load()["wow"] == nil)
    #expect(store.load()["heroes@windows"] != nil)
    try store.remove(hots)
    #expect(store.load().isEmpty)
}

// MARK: An install that never finished

/// What `InstallPlatform.claim` leaves before an install's first download.
private let claim = ".waypoint-platform"

@Test func anInstallThatNeverFinishedGoesToTheTrashWithItsFolder() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let root = try box.make("Hearthstone", [claim, ".waypoint-staging/0a1b", "Data/data/data.000"])
    let install = InstallableProduct.hearthstone.install(at: root, region: .eu, language: "enUS", tagString: "OSX EU? enUS text?")

    let uninstaller = box.uninstaller(install, name: "Hearthstone", keeping: false)
    let plan = try #require(try uninstaller.unfinishedPlan())
    #expect(plan.removesFolder)
    try uninstaller.carryOut(plan)
    #expect(!box.exists("Hearthstone"))
    #expect(box.exists("Trash/Hearthstone/Data/data/data.000"), "to the Trash, not deleted")
}

@Test func whatWasInTheFolderBeforeTheInstallStays() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // The user picked a folder that already held things of their own.
    let root = try box.make("StarCraft", ["Maps/old.scm", "notes.txt"])
    try box.make("StarCraft", [claim, "Data/data/data.000", ".waypoint-staging/0a1b"])
    let install = ProductInstall(uid: "s1", productCode: "s1", installPath: root.path, region: "eu")

    let uninstaller = box.uninstaller(install, name: "StarCraft")
    let plan = try #require(try uninstaller.unfinishedPlan())
    #expect(!plan.removesFolder)
    #expect(plan.items == [claim, ".waypoint-staging", "Data"])
    try uninstaller.carryOut(plan)
    #expect(box.exists("StarCraft/Maps/old.scm"))
    #expect(box.exists("StarCraft/notes.txt"))
    #expect(!box.exists("StarCraft/Data"))
    #expect(box.exists("Trash/StarCraft/Data/data/data.000"))

    // The Finder's own file being older doesn't keep a folder from going whole.
    let viewed = try box.make("Viewed", [".DS_Store"])
    try box.make("Viewed", [claim, "Data/data/data.000"])
    let other = ProductInstall(uid: "s1", productCode: "s1", installPath: viewed.path, region: "eu")
    #expect(try box.uninstaller(other, name: "StarCraft").unfinishedPlan()?.removesFolder == true)
}

@Test func aFolderNoInstallClaimedIsLeftAlone() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // No claim file: an older Waypoint's download, or not a download at all.
    let unclaimed = try box.make("Unclaimed", ["Data/data/data.000"])
    #expect(try box.uninstaller(wow(unclaimed), name: "World of Warcraft").unfinishedPlan() == nil)
    // Claimed only now, on resuming: everything in it is older than the claim.
    try box.make("Unclaimed", [claim])
    let plan = try #require(try box.uninstaller(wow(unclaimed), name: "World of Warcraft").unfinishedPlan())
    #expect(plan.items == [claim], "only the claim itself is known to be the install's")
}

@Test func anInstalledGameIsNeverTakenForAnUnfinishedInstall() async throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // The app is in place: the install failed after its files were in, or
    // the job is really an update.
    let root = try box.make("World of Warcraft", [claim, wowApp, "Data/data/data.000"])
    let uninstaller = box.uninstaller(wow(root), name: "World of Warcraft")
    #expect(try uninstaller.unfinishedPlan() == nil)
    await #expect(throws: UninstallError.notUnfinished("World of Warcraft")) { try await uninstaller.removeUnfinished() }
    #expect(box.exists("World of Warcraft/\(wowApp)"), "nothing moved")

    // No app, but .build.info lists it: its records were being written.
    let listed = try box.make("Listed", [claim, "Data/data/data.000"])
    #expect(try box.uninstaller(wow(listed), name: "World of Warcraft").unfinishedPlan() != nil)
    try Data("\(buildInfoHeader)\neu|1|aaaa|12.1.5|wow\n".utf8).write(to: listed.appendingPathComponent(".build.info"))
    #expect(try box.uninstaller(wow(listed), name: "World of Warcraft").unfinishedPlan() == nil)
    // Or it can't be read, so there is no telling what it lists.
    try Data([0xff, 0xfe, 0xfd]).write(to: listed.appendingPathComponent(".build.info"))
    #expect(try box.uninstaller(wow(listed), name: "World of Warcraft").unfinishedPlan() == nil)
}

@Test func anUnfinishedInstallIntoASharedFolderStays() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // Classic Era is installed; retail was being added to its folder, so
    // what retail downloaded is inside the storage Classic Era uses.
    let root = try box.make("World of Warcraft", [claim, eraApp, "Data/data/data.000", "_retail_/.waypoint-staging/0a1b"])
    try Data("\(buildInfoHeader)\neu|1|bbbb|1.15.8|wow_classic_era\n".utf8).write(to: root.appendingPathComponent(".build.info"))
    #expect(try box.uninstaller(wow(root), name: "World of Warcraft").unfinishedPlan() == nil)

    // The same when only another download says the folder is in use.
    let fresh = try box.make("Fresh", [claim, "Data/data/data.000"])
    #expect(try box.uninstaller(wow(fresh), name: "World of Warcraft", others: [wow(fresh, "wow_classic_era")]).unfinishedPlan() == nil)
    #expect(try box.uninstaller(wow(fresh), name: "World of Warcraft").unfinishedPlan()?.removesFolder == true)
}

@Test func anUnfinishedReinstallLeavesTheAddOnsOfTheInstallBeforeIt() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    // Uninstalled earlier keeping its add-ons, then installed again and stopped.
    try box.make("World of Warcraft", [
        "_retail_/Interface/AddOns/Details/Details.toc", "_retail_/WTF/Config.wtf", "_classic_era_/Interface/AddOns/Questie/Questie.toc",
    ])
    let root = try box.make("World of Warcraft", [claim, "_retail_/.waypoint-staging/0a1b", "Data/data/data.000"])
    // Even asked not to keep them: clearing a download never takes the user's files.
    let uninstaller = box.uninstaller(wow(root), name: "World of Warcraft", keeping: false)
    let plan = try #require(try uninstaller.unfinishedPlan())
    #expect(!plan.removesFolder)
    #expect(plan.keepsUserFiles)
    #expect(plan.items == [claim, "Data", "_retail_/.waypoint-staging"])
    var keeping = uninstaller
    keeping.keepsUserFiles = true
    try keeping.carryOut(plan)
    #expect(box.exists("World of Warcraft/_retail_/Interface/AddOns/Details/Details.toc"))
    #expect(box.exists("World of Warcraft/_retail_/WTF/Config.wtf"))
    #expect(box.exists("World of Warcraft/_classic_era_/Interface/AddOns/Questie/Questie.toc"), "another version's add-ons stay too")
    #expect(!box.exists("World of Warcraft/Data"))
    #expect(box.exists("Trash/World of Warcraft/Data/data/data.000"))
}

@Test func anUnfinishedInstallWithNoFolderYetHasNothingToClear() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let missing = box.dir.appendingPathComponent("Nowhere")
    #expect(throws: UninstallError.folderMissing(missing.path)) { try box.uninstaller(wow(missing), name: "World of Warcraft").unfinishedPlan() }
}
