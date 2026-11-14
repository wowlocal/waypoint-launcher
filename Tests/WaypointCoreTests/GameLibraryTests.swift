import Foundation
import Testing
@testable import WaypointCore

private func folderRecord(_ install: ProductInstall) -> Data {
    var writer = ProtoWriter()
    writer.string(1, install.uid)
    writer.string(2, install.productCode)
    writer.message(3) {
        $0.string(1, install.installPath)
        $0.string(2, install.region ?? "eu")
    }
    return writer.data
}

private func folderDatabase(_ installs: [ProductInstall]) -> Data {
    var writer = ProtoWriter()
    for install in installs { writer.bytes(1, folderRecord(install)) }
    // Unknown envelope fields must not be mistaken for single-record data.
    writer.string(2, "unknown database field")
    writer.bytes(3, Data([0xff]))
    writer.varint(6, 1234)
    writer.string(100, "unknown database extension")
    return writer.data
}

/// Real bundle metadata and a Mach-O executable, without launching a game.
private func makeLibraryApp(at url: URL) throws {
    let executable = url.deletingPathExtension().lastPathComponent
    let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleExecutable": executable,
        "CFBundleIdentifier": "test.waypoint.\(executable.filter(\.isLetter))",
        "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(executable))
}

@Test func libraryFindsAllWoWEditionsInFolderDatabaseWithoutAgent() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-library-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    let folder = sandbox.appendingPathComponent("World of Warcraft")
    try makeLibraryApp(at: folder.appendingPathComponent("_retail_/World of Warcraft.app"))
    try makeLibraryApp(at: folder.appendingPathComponent("_classic_era_/World of Warcraft Classic.app"))
    let installs = ["wow", "wow_classic_era"].map {
        ProductInstall(uid: $0, productCode: $0, installPath: folder.path, region: "eu")
    }
    try folderDatabase(installs).write(to: folder.appendingPathComponent(".product.db"))
    let missingAgent = sandbox.appendingPathComponent("Agent/product.db")
    let library = GameLibrary(agentDatabase: missingAgent, searchRoots: [folder],
                              stateStore: InstallStateStore(file: sandbox.appendingPathComponent("installs.json")))

    let games = library.games()
    #expect(games.map(\.id) == ["wow", "wow_classic_era"])
    #expect(games.allSatisfy { $0.isInstalled })
    #expect(games.allSatisfy { $0.isSupported })
    #expect(games.map { $0.appURL?.lastPathComponent } == ["World of Warcraft.app", "World of Warcraft Classic.app"])
    #expect(!fm.fileExists(atPath: missingAgent.path))
}

@Test func libraryKeepsSingleFolderRecordsAndIgnoresUnknownOrCorruptMetadata() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-library-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    let folder = sandbox.appendingPathComponent("Hearthstone")
    try makeLibraryApp(at: folder.appendingPathComponent("Hearthstone.app"))
    let install = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: folder.path, region: "eu")
    try folderRecord(install).write(to: folder.appendingPathComponent(".product.db"))
    let unknown = sandbox.appendingPathComponent("Unknown")
    let corrupt = sandbox.appendingPathComponent("Corrupt")
    try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
    try fm.createDirectory(at: corrupt, withIntermediateDirectories: true)
    var unrelated = ProtoWriter()
    unrelated.string(100, "unrecognized metadata")
    try unrelated.data.write(to: unknown.appendingPathComponent(".product.db"))
    try Data([0x0a, 0x80]).write(to: corrupt.appendingPathComponent(".product.db"))
    let library = GameLibrary(agentDatabase: sandbox.appendingPathComponent("missing.db"),
                              searchRoots: [unknown, corrupt, folder],
                              stateStore: InstallStateStore(file: sandbox.appendingPathComponent("installs.json")))

    #expect(library.installs() == [install])
    #expect(library.games().allSatisfy { $0.isInstalled })
}

@Test func libraryFolderRecoveryPreservesAgentAndStandalonePrecedence() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-library-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    let folders = ["Agent copy", "Folder copy", "Standalone copy"].map { sandbox.appendingPathComponent($0) }
    for folder in folders { try makeLibraryApp(at: folder.appendingPathComponent("Hearthstone.app")) }
    let installs = folders.map { ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: $0.path, region: "eu") }
    let agent = sandbox.appendingPathComponent("product.db")
    try folderDatabase([installs[0]]).write(to: agent)
    let folderFile = folders[1].appendingPathComponent(".product.db")
    try folderDatabase([installs[1]]).write(to: folderFile)
    let store = InstallStateStore(file: sandbox.appendingPathComponent("installs.json"))
    let build = InstalledBuild(buildConfig: "standalone", version: "1.0", install: installs[2])
    try JSONEncoder().encode(["hs_beta": build]).write(to: store.file)
    let library = GameLibrary(agentDatabase: agent, searchRoots: [folders[1]], stateStore: store)

    #expect(library.installs().map(\.installPath) == [folders[0].path], "An installed Agent copy remains authoritative")
    try fm.removeItem(at: folders[0])
    #expect(library.installs().map(\.installPath) == [folders[1].path], "Folder metadata replaces a missing Agent copy")
    try Data([0x0a, 0x80]).write(to: folderFile)
    #expect(library.installs().map(\.installPath) == [folders[2].path], "Standalone installs remain a fallback when folder metadata is corrupt")
}

@Test func aGameShowsItsAppInTheFinderAndAWoWVersionItsAddOnsOnceItHasThem() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-folders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appendingPathComponent("World of Warcraft", isDirectory: true)
    try makeLibraryApp(at: root.appendingPathComponent("_retail_/World of Warcraft.app"))
    let install = ProductInstall(uid: "wow", productCode: "wow", installPath: root.path, region: "eu")

    var game = GameCatalog.game(for: install)
    #expect(game.finderItem.standardizedFileURL == root.appendingPathComponent("_retail_/World of Warcraft.app").standardizedFileURL)
    #expect(game.addOnsFolder == nil, "the game makes the folder when it first runs")

    let addOns = root.appendingPathComponent("_retail_/Interface/AddOns", isDirectory: true)
    try FileManager.default.createDirectory(at: addOns, withIntermediateDirectories: true)
    #expect(game.addOnsFolder?.standardizedFileURL == addOns.standardizedFileURL)

    // A game whose app can't be found still has a folder to show; only WoW has add-ons.
    game.appURL = nil
    game.family = .other
    #expect(game.finderItem.standardizedFileURL == root.standardizedFileURL)
    #expect(game.addOnsFolder == nil)
}

private func resolved(_ path: String?) -> String? {
    path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}

/// A defaults domain of its own, for a store a test can throw away.
private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "waypoint-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

/// A Battle.net Agent database with one record, its languages included.
private func agentDatabase(_ install: ProductInstall) -> Data {
    var record = ProtoWriter()
    record.string(1, install.uid)
    record.string(2, install.productCode)
    record.message(3) {
        $0.string(1, install.installPath)
        $0.string(2, install.region ?? "eu")
        if let text = install.textLanguage { $0.string(6, text) }
    }
    var writer = ProtoWriter()
    writer.bytes(1, record.data)
    return writer.data
}

@Test func locatedGamesRebaseMovedMetadataAndFollowTheirFolder() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-locate-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    let root = sandbox.appendingPathComponent("External Games/World of Warcraft").resolvingSymlinksInPath()
    try makeLibraryApp(at: root.appendingPathComponent("_retail_/World of Warcraft.app"))
    let stale = ProductInstall(uid: "wow", productCode: "wow", installPath: "/Volumes/Old Mac/WoW", region: "eu")
    let metadata = folderDatabase([stale])
    try metadata.write(to: root.appendingPathComponent(".product.db"))
    let locations = LocatedGames.locate(at: root.deletingLastPathComponent())
    #expect(locations.map { resolved($0.path) } == [root.path])
    #expect(locations.first?.bookmark != nil)
    #expect(locations.first?.volumeUUID != nil)
    #expect(LocatedGames.locate(at: root.appendingPathComponent("_retail_")).map { resolved($0.path) } == [root.path])
    var library = GameLibrary(agentDatabase: sandbox.appendingPathComponent("missing"), searchRoots: [],
        stateStore: InstallStateStore(file: sandbox.appendingPathComponent("state.json")))
    library.located = LocatedGames.scan(locations)
    #expect(library.games().count == 1)
    #expect(resolved(library.games().first?.install.installPath) == root.path)
    #expect(library.games().first?.install.region == "eu")
    #expect(library.games().first?.locationID == locations.first?.id)
    #expect(try Data(contentsOf: root.appendingPathComponent(".product.db")) == metadata, "nothing is written")

    // Moved (a renamed drive): the bookmark finds it, and the path follows.
    let moved = sandbox.appendingPathComponent("Ext 1/World of Warcraft").resolvingSymlinksInPath()
    try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: root, to: moved)
    library.located = LocatedGames.scan(locations)
    #expect(library.located.disconnected.isEmpty)
    #expect(resolved(library.located.locations.first?.path) == moved.path)
    #expect(resolved(library.games().first?.install.installPath) == moved.path)

    // Moved to the Trash (uninstalled): the bookmark follows it there, but it's gone.
    var trashed: NSURL?
    try fm.trashItem(at: moved, resultingItemURL: &trashed)
    defer { if let trashed { try? fm.removeItem(at: trashed as URL) } }
    let rescanned = LocatedGames.scan(library.located.locations)
    #expect(rescanned.locations.first?.installs.isEmpty == true)
    #expect(rescanned.locations.first.map { !$0.path.contains(".Trash") } == true, "the Trash isn't remembered")
    library.located = rescanned
    #expect(library.games().filter(\.isListed).isEmpty)

    // Gone from a drive that is there: not kept as offline.
    if let trashed { try fm.removeItem(at: trashed as URL) }
    library.located = LocatedGames.scan(library.located.locations)
    #expect(library.games().filter(\.isListed).isEmpty)
    #expect(library.located.disconnected.isEmpty)
}

@Test func locatedGamesNeverReplaceTheRealInstallOrARicherRecord() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-locate-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: sandbox) }
    let real = sandbox.appendingPathComponent("Applications/Hearthstone")
    let backup = sandbox.appendingPathComponent("Backup/Hearthstone")
    for folder in [real, backup] {
        try makeLibraryApp(at: folder.appendingPathComponent("Hearthstone.app"))
        try folderRecord(ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/elsewhere", region: "eu"))
            .write(to: folder.appendingPathComponent(".product.db"))
    }
    let agent = sandbox.appendingPathComponent("product.db")
    try agentDatabase(ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: real.path, region: "eu", textLanguage: "deDE"))
        .write(to: agent)
    var library = GameLibrary(agentDatabase: agent, searchRoots: [],
                              stateStore: InstallStateStore(file: sandbox.appendingPathComponent("installs.json")))

    library.located = LocatedGames.scan(LocatedGames.locate(at: backup))
    #expect(library.installs().map(\.installPath) == [real.path], "a located backup never replaces the real install")
    #expect(library.games().first?.locationID == nil, "nor is it what Remove from Library would forget")

    library.located = LocatedGames.scan(LocatedGames.locate(at: real))
    #expect(library.installs().first?.textLanguage == "deDE", "locating Battle.net's own folder keeps its record")

    library.located = LocatedGames.scan(LocatedGames.locate(at: backup))
    try fm.removeItem(at: real)
    #expect(library.installs().map(\.installPath) == [backup.path], "it fills in for a copy whose files are gone")
    #expect(library.games().first?.locationID == library.located.locations.first?.id)

    // Removed from the library: not listed from there again.
    library.located.locations[0].removedKeys = ["hs_beta"]
    #expect(library.games().filter(\.isListed).isEmpty)
}

@Test func gamesOnADriveThatIsntConnectedStayListedAsOffline() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-offline-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: sandbox) }
    let away = "/Volumes/Waypoint Test \(UUID().uuidString)/Games/World of Warcraft"
    let wow = ProductInstall(uid: "wow", productCode: "wow", installPath: away, region: "eu", version: "12.0.0")
    let classic = ProductInstall(uid: "wow_classic_era", productCode: "wow_classic_era", installPath: away, region: "eu")
    let location = LocatedGames.Location(path: away, volumeUUID: UUID().uuidString, installs: [wow, classic])
    let agent = sandbox.appendingPathComponent("product.db")
    try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    // Battle.net's richer record of the same folder is the one kept.
    try agentDatabase(ProductInstall(uid: "wow", productCode: "wow", installPath: away, region: "eu", textLanguage: "frFR"))
        .write(to: agent)
    var library = GameLibrary(agentDatabase: agent, searchRoots: [],
                              stateStore: InstallStateStore(file: sandbox.appendingPathComponent("installs.json")))
    library.located = LocatedGames.scan([location])
    #expect(library.located.disconnected == [location.id])
    #expect(LocatedGames.Scan.unscanned([location]).disconnected == [location.id], "told from the mounted volumes alone")

    let games = library.games()
    #expect(games.map(\.id) == ["wow", "wow_classic_era"])
    #expect(games.allSatisfy { $0.isOffline && $0.isListed && !$0.isInstalled && !$0.isSupported })
    #expect(games.allSatisfy { $0.locationID == location.id })
    #expect(games.first?.install.textLanguage == "frFR")
    #expect(games.map(\.displayName) == [wow, classic].map { GameCatalog.game(for: $0).displayName }, "named as when connected")
    // Listed, so not offered for download again.
    let offered = InstallableProduct.all.filter { product in !games.filter(\.isListed).contains { $0.install.uid == product.uid } }
    #expect(!offered.contains { $0.uid == "wow" || $0.uid == "wow_classic_era" })

    // Removed from the library: Battle.net's record of it isn't kept as offline either.
    var removed = location
    removed.removedKeys = ["wow"]
    library.located = LocatedGames.scan([removed])
    #expect(library.games().filter(\.isListed).map(\.id) == ["wow_classic_era"])

    // A copy on disk elsewhere is the one listed.
    let local = sandbox.appendingPathComponent("World of Warcraft")
    try makeLibraryApp(at: local.appendingPathComponent("_retail_/World of Warcraft.app"))
    try agentDatabase(ProductInstall(uid: "wow", productCode: "wow", installPath: local.path, region: "eu")).write(to: agent)
    library.located = LocatedGames.scan([location])
    let listed = library.games().filter(\.isListed)
    #expect(listed.first { $0.id == "wow" }.map { !$0.isOffline && $0.install.installPath == local.path } == true)
    #expect(listed.first { $0.id == "wow_classic_era" }?.isOffline == true)
}

@Test func locatedStoreRemembersForgetsAndMigratesPlainPaths() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-store-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: sandbox) }
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LocatedGames.Store(defaults: defaults)
    #expect(store.locations().isEmpty)

    let folder = sandbox.appendingPathComponent("Hearthstone")
    try makeLibraryApp(at: folder.appendingPathComponent("Hearthstone.app"))
    try folderRecord(ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/elsewhere", region: "eu"))
        .write(to: folder.appendingPathComponent(".product.db"))
    let first = LocatedGames.locate(at: folder)
    store.add(first)
    #expect(store.locations() == first)
    // Located again: one entry, listing again what was removed.
    var again = LocatedGames.locate(at: folder)
    store.add(again)
    #expect(store.locations().map(\.id) == again.map(\.id))
    store.remove(key: "hs_beta", from: again[0].id)
    #expect(store.locations().map(\.listedInstalls) == [[]], "kept, so what it removed stays removed")
    store.add(again)
    store.remove(id: again[0].id)
    #expect(store.locations().isEmpty)

    // A bookmark that no longer resolves: the path is used.
    again[0].bookmark = Data("not a bookmark".utf8)
    store.add(again)
    let scanned = LocatedGames.scan(store.locations())
    #expect(scanned.locations.first?.installs.map(\.uid) == ["hs_beta"])
    store.update(with: scanned.locations)
    #expect(store.locations().first?.bookmark != Data("not a bookmark".utf8), "and a new bookmark saved")
    // What was removed while a scan ran stays removed.
    let inFlight = LocatedGames.scan(store.locations())
    var two = again[0]
    two.installs.append(ProductInstall(uid: "wow", productCode: "wow", installPath: folder.path))
    store.add([two])
    store.remove(key: "wow", from: two.id)
    store.update(with: inFlight.locations)
    #expect(store.locations().first?.removedKeys == ["wow"])
    store.remove(id: two.id)

    // The first version's bare paths: read, then saved with a bookmark once scanned.
    defaults.set([folder.path], forKey: LocatedGames.Store.key)
    let legacy = store.locations()
    #expect(legacy.map(\.path) == [folder.path])
    #expect(legacy.first?.bookmark == nil)
    store.update(with: LocatedGames.scan(legacy).locations)
    #expect(defaults.object(forKey: LocatedGames.Store.key) is Data)
    #expect(store.locations().first?.bookmark != nil)
    #expect(store.locations().first?.volumeUUID != nil)
    #expect(store.locations().first?.installs.map(\.uid) == ["hs_beta"])
}

@Test func locatedGamesRecoverActiveEditionsAndKeepPlatformsSeparate() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-locate-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    try makeLibraryApp(at: sandbox.appendingPathComponent("_retail_/World of Warcraft.app"))
    try makeLibraryApp(at: sandbox.appendingPathComponent("_classic_era_/World of Warcraft Classic.app"))
    let stale = ProductInstall(uid: "wow", productCode: "wow", installPath: "/old", region: "eu", version: "0.0.1", buildConfig: String(repeating: "d", count: 32))
    try folderDatabase([stale]).write(to: sandbox.appendingPathComponent(".product.db"))
    let text = "Branch!STRING:0|Active!DEC:1|Product!STRING:0|Tags!STRING:0|Version!STRING:0|Build Key!HEX:16\neu|1|wow|OSX enUS text?|12.0.0|\(String(repeating: "a", count: 32))\neu|1|wow_classic_era|OSX enUS text?|1.0.0|\(String(repeating: "b", count: 32))\neu|0|wow_classic|OSX enUS text?|2.0.0|\(String(repeating: "c", count: 32))\n"
    try text.write(to: sandbox.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    #expect(Set(LocatedGames.installs(at: sandbox).map(\.uid)) == ["wow", "wow_classic_era"])
    let retail = LocatedGames.installs(at: sandbox).first { $0.uid == "wow" }
    #expect(retail?.version == "12.0.0")
    #expect(retail?.buildConfig == String(repeating: "a", count: 32))
    #expect(retail?.region == "eu")
    #expect(LocatedGames.installs(at: sandbox).first { $0.uid == "wow_classic_era" }?.region == "eu")
    try fm.removeItem(at: sandbox.appendingPathComponent(".product.db"))
    let conflicting = text + "us|1|wow|OSX enUS text?|13.0.0|\(String(repeating: "e", count: 32))\n"
    try conflicting.write(to: sandbox.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    #expect(!LocatedGames.installs(at: sandbox).contains { $0.uid == "wow" })
    try text.replacingOccurrences(of: "OSX", with: "Windows").write(to: sandbox.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    #expect(LocatedGames.installs(at: sandbox).isEmpty)
    try Data([0xff]).write(to: sandbox.appendingPathComponent(".product.db"))
    #expect(LocatedGames.installs(at: sandbox).isEmpty)
}

@Test func theMainThreadTakesGamesOnOtherDrivesAsTheyWereLastRead() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-other-drive-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    // A drive stands in: what is under `drive` counts as on another one.
    let drive = sandbox.appendingPathComponent("T7", isDirectory: true)
    let folder = drive.appendingPathComponent("Hearthstone", isDirectory: true)
    try makeLibraryApp(at: folder.appendingPathComponent("Hearthstone.app"))
    let hearthstone = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: folder.path, region: "eu")
    let local = sandbox.appendingPathComponent("World of Warcraft", isDirectory: true)
    try makeLibraryApp(at: local.appendingPathComponent("_retail_/World of Warcraft.app"))
    let wow = ProductInstall(uid: "wow", productCode: "wow", installPath: local.path, region: "eu")
    try folderDatabase([hearthstone, wow]).write(to: sandbox.appendingPathComponent("product.db"))
    // Waypoint's record of a game whose folder there was deleted.
    let gone = ProductInstall(uid: "s1", productCode: "s1", installPath: drive.appendingPathComponent("StarCraft").path, region: "eu")
    let records = InstallStateStore(file: sandbox.appendingPathComponent("installs.json"))
    try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try JSONEncoder().encode(["s1": InstalledBuild(buildConfig: "standalone", version: "1.0", install: gone)]).write(to: records.file)
    var library = GameLibrary(agentDatabase: sandbox.appendingPathComponent("product.db"), searchRoots: [], stateStore: records)
    let drivePath = drive.path
    library.otherDrives = { _ in { $0.hasPrefix(drivePath) } }

    // Off the main thread: read there, like any other.
    var skipped = GameLibrary.OtherDrives()
    let scanned = library.games(otherDrives: &skipped)
    let read = skipped.read
    #expect(!skipped.skipped)
    #expect(scanned.filter(\.isInstalled).map(\.id) == ["hs_beta", "wow"])

    // On the main thread, before any such read: not listed yet, and said so.
    library.readsOtherDrives = false
    #expect(library.games(otherDrives: &skipped).filter(\.isInstalled).map(\.id) == ["wow"])
    #expect(skipped.skipped)
    #expect(skipped.unread == ["hs_beta", "s1"], "neither listed nor offered until read")

    // After it: as read then, without reading the drive again.
    #expect(Set(read.keys) == [GameLibrary.factsKey(hearthstone), GameLibrary.factsKey(gone)], "what was read there, for the main thread")
    #expect(read[GameLibrary.factsKey(gone)] == .some(nil), "found not there")
    library.otherDriveGames = read
    try fm.removeItem(at: folder.appendingPathComponent("Hearthstone.app"))
    let shown = library.games(otherDrives: &skipped)
    #expect(shown.filter(\.isInstalled).map(\.id) == ["hs_beta", "wow"])
    #expect(skipped.skipped, "the next read off the main thread finds it gone")
    #expect(skipped.unread.isEmpty, "known not there is read, not unread")
    #expect(library.game(for: hearthstone).isInstalled)
    library.readsOtherDrives = true
    #expect(library.games().filter(\.isInstalled).map(\.id) == ["wow"])
    #expect(!library.game(for: hearthstone).isInstalled)
}

@Test func aWindowsGameIsInstalledAsItWasRead() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-windows-read-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sandbox) }
    guard let title = WindowsTitle.allCases.first else { return }
    let install = title.product.install(at: sandbox, region: .eu, languages: GameLanguages(text: "enUS"), tagString: "Win EU enUS", platform: .windows)
    let program = sandbox.appendingPathComponent(title.executablePath)
    #expect(!GameCatalog.game(for: install).isInstalled)
    try fm.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: program)
    let game = GameCatalog.game(for: install)
    #expect(game.isInstalled)
    // Asking again (as each render does) doesn't look at the disk.
    try fm.removeItem(at: program)
    #expect(game.isInstalled)
    #expect(!GameCatalog.game(for: install).isInstalled)
}

@Test func aGameRemovedFromTheLibraryStaysRemovedWhateverElseKnowsIt() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("waypoint-removed-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: sandbox) }
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    // StarCraft installed by Waypoint into another folder: Waypoint's record
    // of it, the Agent's and the folder's (the repair wrote them), and the
    // folder remembered.
    let folder = sandbox.appendingPathComponent("StarCraft", isDirectory: true)
    try makeLibraryApp(at: folder.appendingPathComponent("StarCraft.app"))
    let starcraft = ProductInstall(uid: "s1", productCode: "s1", installPath: folder.path, region: "eu")
    let agent = sandbox.appendingPathComponent("product.db")
    try folderDatabase([starcraft]).write(to: agent)
    try folderDatabase([starcraft]).write(to: folder.appendingPathComponent(".product.db"))
    let records = InstallStateStore(file: sandbox.appendingPathComponent("installs.json"))
    try JSONEncoder().encode(["s1": InstalledBuild(buildConfig: "standalone", version: "1.0", install: starcraft)])
        .write(to: records.file)
    let store = LocatedGames.Store(defaults: defaults)
    store.record(LocatedGames.Location(installedAt: folder, install: starcraft), installed: starcraft.key)
    let id = try #require(store.locations().first?.id)
    var library = GameLibrary(agentDatabase: agent, searchRoots: [folder], stateStore: records)
    func listed(connected: Bool = true) -> [Game] {
        library.located = LocatedGames.scan(store.locations()) {
            connected ? LocatedGames.Volumes.mounted() : LocatedGames.Volumes(paths: [], uuids: [])
        }
        return library.games().filter(\.isListed)
    }

    // Its drive connected, it can be removed from the library: it is
    // listed from the remembered folder, though the Agent's record is the one used.
    #expect(listed().map(\.id) == ["s1"])
    #expect(listed().first?.locationID == id)
    #expect(listed(connected: false).first?.locationID == id)

    // Removed: not listed again from any record of it, connected or not.
    store.remove(key: starcraft.key, from: id)
    #expect(listed().isEmpty)
    #expect(listed(connected: false).isEmpty)
    try fm.removeItem(at: agent)
    #expect(listed().isEmpty, "nor from the folder's record")
    try fm.removeItem(at: folder.appendingPathComponent(".product.db"))
    #expect(listed().isEmpty, "nor from Waypoint's own")
    #expect(fm.fileExists(atPath: folder.appendingPathComponent("StarCraft.app").path), "its files stay")

    // The folder located again: listed again.
    try folderDatabase([starcraft]).write(to: folder.appendingPathComponent(".product.db"))
    store.add(LocatedGames.locate(at: folder))
    #expect(listed().map(\.id) == ["s1"])

    // Or the game installed there again, by Waypoint: in a folder it
    // remembers, or in a built-in one (which it doesn't remember as such).
    store.remove(key: starcraft.key, from: try #require(store.locations().first?.id))
    #expect(listed().isEmpty)
    store.record(LocatedGames.Location(installedAt: folder, install: starcraft), installed: starcraft.key)
    #expect(listed().map(\.id) == ["s1"])
    store.remove(key: starcraft.key, from: try #require(store.locations().first?.id))
    #expect(listed().isEmpty)
    #expect(store.restore(key: starcraft.key, at: folder.path))
    #expect(!store.restore(key: starcraft.key, at: folder.path))
    #expect(listed().map(\.id) == ["s1"])
}
