import Foundation
import Testing
@testable import WaypointCore

private func sandbox(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-\(name)-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "waypoint-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

/// A drive by a name no Mac has mounted.
private func unmountedDrive() -> String { "/Volumes/Waypoint Test \(UUID().uuidString)" }

private func makeApp(at url: URL) throws {
    let executable = url.deletingPathExtension().lastPathComponent
    let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": "test.waypoint.location",
                                "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(executable))
}

// MARK: The volume rules

@Test func theInstallSheetSaysWhatIsFreeAndWhatKeepsAGameOff() {
    let gb: UInt64 = 1_000_000_000
    let startup = InstallVolume(name: "Macintosh HD", isStartupDisk: true, availableCapacity: 812 * gb)
    #expect(startup.summary == "812 GB available")
    #expect(startup.problem(download: 80 * gb, platform: .macOS) == nil)
    #expect(startup.problem(download: nil, platform: .macOS) == nil, "nothing to say about space before the size is known")
    #expect(startup.caution == nil)

    let t7 = InstallVolume(name: "T7", availableCapacity: 812 * gb, format: "exfat")
    #expect(t7.summary == "812 GB available on “T7”")
    #expect(t7.caution == "Formatted as ExFAT. Games run best from APFS.")
    #expect(t7.problem(download: 80 * gb, platform: .macOS) == nil, "ExFAT is allowed")
    #expect(InstallVolume(name: "USB", availableCapacity: gb, format: "msdos").caution
        == "Formatted as MS-DOS (FAT). Games run best from APFS.")
    #expect(InstallVolume(name: "X5", availableCapacity: gb, format: "apfs").caution == nil)
    #expect(InstallVolume(name: "Old", availableCapacity: gb, format: "hfs").caution == nil)

    // Space: the download, and the room the installers keep free.
    let small = InstallVolume(name: "T7", availableCapacity: 50 * gb)
    #expect(small.problem(download: 48 * gb, platform: .macOS) == nil)
    #expect(small.problem(download: 49 * gb, platform: .macOS) == "Not enough space on “T7”: needs 51 GB, 50 GB available.",
            "short of the download and a GiB to spare, rounded up")
    #expect(InstallVolume(name: "Macintosh HD", isStartupDisk: true, availableCapacity: 10 * gb).problem(download: 20 * gb, platform: .macOS)
        == "Not enough space: needs 22 GB, 10 GB available.")
    #expect(InstallVolume(name: "T7", availableCapacity: nil).problem(download: 900 * gb, platform: .macOS) == nil,
            "an unknown capacity doesn't block the sheet; the installer checks again")
    #expect(InstallVolume(name: "T7", availableCapacity: nil).summary == nil)

    #expect(InstallVolume(name: "Archive", availableCapacity: 812 * gb, isReadOnly: true).problem(download: nil, platform: .macOS)
        == "“Archive” is read-only.")
    #expect(InstallVolume(name: "NAS", availableCapacity: 812 * gb, isLocal: false, format: "smbfs").problem(download: nil, platform: .macOS)
        == "“NAS” isn’t a drive connected to this Mac.")
    #expect(InstallVolume(name: "Macintosh HD", isStartupDisk: true, availableCapacity: 812 * gb, unwritableFolder: "Applications")
        .problem(download: nil, platform: .macOS) == "You don’t have permission to save in “Applications”.")
    #expect(InstallVolume(name: "Dev", availableCapacity: 812 * gb, isCaseSensitive: true).problem(download: nil, platform: .windows) == nil,
            "Wine copes with case-sensitive names")
    #expect(InstallVolume(name: "Dev", availableCapacity: 812 * gb, isCaseSensitive: true).problem(download: nil, platform: .macOS)
        == "“Dev” is case-sensitive, which Blizzard games don’t support.")
    #expect(InstallVolume(name: "Macintosh HD", isStartupDisk: true, availableCapacity: 812 * gb, isCaseSensitive: true)
        .problem(download: nil, platform: .macOS) == "The startup disk is case-sensitive, which Blizzard games don’t support.")
}

@Test func theFreeSpaceFallsBackToThePlainReadingAndIsMeasuredWhereTheFolderWillBe() throws {
    // ExFAT drives report no space for important usage, or zero.
    #expect(InstallVolume.capacity(importantUsage: 0, available: 293_679_792_128) == 293_679_792_128)
    #expect(InstallVolume.capacity(importantUsage: nil, available: 5) == 5)
    #expect(InstallVolume.capacity(importantUsage: 47_888_277_156, available: 40_055_263_232) == 47_888_277_156)
    #expect(InstallVolume.capacity(importantUsage: nil, available: nil) == nil)
    #expect(InstallVolume.capacity(importantUsage: 0, available: nil) == 0)

    let root = try sandbox("capacity")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Games/Diablo IV (Windows)", isDirectory: true)
    #expect(InstallVolume.nearestExisting(folder).path == root.path)
    #expect(InstallVolume.nearestExisting(root).path == root.path)
    #expect(InstallVolume.nearestExisting(URL(fileURLWithPath: "/nonexistent-\(UUID())/a")).path == "/")
    // A new install's folder isn't there yet: no longer “unlimited”.
    let capacity = try InstallVolume.availableCapacity(at: folder)
    #expect(capacity > 0 && capacity < .max)
    let volume = try #require(try InstallVolume.read(at: folder))
    #expect(volume.availableCapacity != nil)
    #expect(volume.isLocal && !volume.isReadOnly)
    #expect(!FileManager.default.fileExists(atPath: folder.path), "reading never creates the folder")
}

// MARK: A drive that isn't connected

@Test func nothingIsWrittenInPlaceOfADriveThatIsntConnected() async throws {
    let drive = unmountedDrive()
    let name = URL(fileURLWithPath: drive).lastPathComponent
    let folder = URL(fileURLWithPath: drive + "/Games/Hearthstone", isDirectory: true)
    #expect(InstallVolume.missingDrive(for: folder.path) == name)
    #expect(InstallVolume.missingDrive(for: folder.path, mounted: [drive]) == nil)
    #expect(InstallVolume.missingDrive(for: "/Applications/Hearthstone", mounted: []) == nil, "the startup disk is always there")
    #expect(InstallVolume.missingDrive(for: NSHomeDirectory() + "/Games/X", mounted: []) == nil)
    #expect(InstallVolume.missingDrive(for: "/Volumes", mounted: []) == nil)

    #expect(String(describing: UpdateError.driveNotConnected("T7")) == "Connect “T7” to continue.")
    #expect(throws: UpdateError.self) { try InstallVolume.ensureConnected(folder.path) }
    #expect(throws: UpdateError.self) { try InstallVolume.availableCapacity(at: folder) }
    #expect(throws: UpdateError.self) { try InstallVolume.read(at: folder) }

    let install = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU enUS")
    #expect(throws: UpdateError.self) { try InstallPlatform.macOS.claim(install: install) }
    // A download, an install and an update all stop before any network
    // request or folder.
    let request = DownloadRequest(kind: .install, install: install, product: .hearthstone)
    do {
        try await request.perform { _ in }
        Issue.record("performed without its drive")
    } catch {
        #expect(errorMessage(error) == "Connect “\(name)” to continue.")
    }
    await #expect(throws: UpdateError.self) {
        _ = try await GameInstaller(product: .hearthstone, folder: folder, region: .eu, languages: GameLanguages(text: "enUS")).plan()
    }
    await #expect(throws: UpdateError.self) { _ = try await GameUpdate(install: install).plan() }
    #expect(!FileManager.default.fileExists(atPath: drive))
}

// MARK: The remembered folder

@Test func theInstallSheetOffersTheFolderChosenLastAndFallsBackSilently() throws {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = try sandbox("home")
    defer { try? FileManager.default.removeItem(at: home) }
    let locations = InstallLocations(defaults: defaults, home: home)

    // Nothing chosen yet: exactly as before.
    #expect(locations.offered(for: .macOS).path == "/Applications")
    #expect(locations.resolved(for: .macOS).path == "/Applications")
    #expect(locations.offered(for: .windows) == home.appendingPathComponent("Games", isDirectory: true))
    #expect(locations.resolved(for: .windows) == home.appendingPathComponent("Games", isDirectory: true))

    // Chosen for macOS games: offered for them, not for Windows ones.
    let chosen = home.appendingPathComponent("My Games", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    locations.remember(InstallLocations.Remembered(at: chosen), for: .macOS)
    #expect(locations.offered(for: .macOS).path == chosen.path)
    #expect(locations.resolved(for: .macOS).path == chosen.path)
    #expect(locations.resolved(for: .windows) == home.appendingPathComponent("Games", isDirectory: true))

    // On another drive than the one it was chosen on (same name): not it.
    locations.remember(InstallLocations.Remembered(path: chosen.path, volumeUUID: UUID().uuidString), for: .macOS)
    #expect(locations.resolved(for: .macOS).path == "/Applications")

    // Gone: the built-in folder again.
    locations.remember(InstallLocations.Remembered(at: chosen), for: .macOS)
    try FileManager.default.removeItem(at: chosen)
    #expect(locations.resolved(for: .macOS).path == "/Applications")

    // On a drive that isn't connected: not even shown first.
    let away = unmountedDrive() + "/Games"
    locations.remember(InstallLocations.Remembered(path: away, volumeUUID: UUID().uuidString), for: .windows)
    #expect(locations.remembered(for: .windows)?.path == away, "still remembered for when it's back")
    #expect(locations.offered(for: .windows) == home.appendingPathComponent("Games", isDirectory: true))
    #expect(locations.resolved(for: .windows) == home.appendingPathComponent("Games", isDirectory: true))

    // Choosing the built-in folder again forgets the choice.
    locations.remember(InstallLocations.Remembered(path: "/Applications"), for: .macOS)
    #expect(locations.remembered(for: .macOS) == nil)
    #expect(defaults.object(forKey: InstallLocations.key(for: .macOS)) == nil)

    #expect(!locations.isChosen(installPath: "/Applications/Hearthstone"))
    #expect(!locations.isChosen(installPath: home.appendingPathComponent("Games/Overwatch (Windows)").path))
    #expect(locations.isChosen(installPath: "/Volumes/T7/Hearthstone"))
    #expect(locations.isChosen(installPath: home.appendingPathComponent("Desktop/Hearthstone").path))
}

// MARK: Remembering games installed elsewhere

@Test func aGameInstalledOnAnotherDriveStaysListedWhileTheDriveIsAway() throws {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = try sandbox("installed-elsewhere")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocatedGames.Store(defaults: defaults)

    // Installed into a folder that exists: remembered with its bookmark.
    let folder = root.appendingPathComponent("Hearthstone", isDirectory: true)
    try makeApp(at: folder.appendingPathComponent("Hearthstone.app"))
    let hearthstone = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU enUS")
    let location = LocatedGames.Location(installedAt: folder, install: hearthstone)
    #expect(location.installs.map(\.key) == [hearthstone.key], "listed before its records are read back")
    #expect(location.bookmark != nil && location.volumeUUID != nil)
    store.record(location, installed: hearthstone.key)
    #expect(store.locations().map(\.path) == [folder.path])

    // Recorded again (reinstalled, after Remove from Library): one entry,
    // the same id, listed again.
    store.remove(key: hearthstone.key, from: location.id)
    store.record(location, installed: hearthstone.key)
    var removed = store.locations()[0]
    removed.removedKeys = [hearthstone.key]
    store.add([removed])
    var other = LocatedGames.Location(path: folder.path, installs: [hearthstone])
    other.id = "another"
    store.record(other, installed: hearthstone.key)
    #expect(store.locations().count == 1)
    #expect(store.locations()[0].id == location.id)
    #expect(store.locations()[0].removedKeys.isEmpty)

    // Another edition installed there doesn't list again what was removed.
    var shared = store.locations()[0]
    shared.installs.append(ProductInstall(uid: "hs_other", productCode: "hsb", installPath: folder.path))
    shared.removedKeys = ["hs_other"]
    store.add([shared])
    store.record(LocatedGames.Location(path: folder.path, installs: shared.installs), installed: hearthstone.key)
    #expect(store.locations()[0].removedKeys == ["hs_other"])
    store.add([location])

    // Uninstalled: forgotten, folder and all.
    #expect(store.forget(key: hearthstone.key, at: folder.path))
    #expect(store.locations().isEmpty)
    #expect(!store.forget(key: hearthstone.key, at: folder.path))

    // A shared WoW folder keeps the editions still installed there.
    let wowRoot = root.appendingPathComponent("World of Warcraft").path
    let wow = ProductInstall(uid: "wow", productCode: "wow", installPath: wowRoot)
    let classic = ProductInstall(uid: "wow_classic_era", productCode: "wow_classic_era", installPath: wowRoot)
    store.record(LocatedGames.Location(path: wowRoot, installs: [wow, classic]), installed: nil)
    #expect(store.forget(key: "wow", at: wowRoot))
    #expect(store.locations().first?.installs.map(\.key) == ["wow_classic_era"])
    #expect(store.forget(key: "wow_classic_era", at: wowRoot))
    #expect(store.locations().isEmpty)

    // Its drive ejected: the game is listed as disconnected, not offered again.
    let away = unmountedDrive() + "/Hearthstone"
    let onDrive = InstallableProduct.hearthstone.install(at: URL(fileURLWithPath: away), region: .eu, language: "enUS",
                                                         tagString: "OSX EU enUS")
    store.record(LocatedGames.Location(path: away, volumeUUID: UUID().uuidString, installs: [onDrive]), installed: onDrive.key)
    var library = GameLibrary(agentDatabase: root.appendingPathComponent("product.db"), searchRoots: [],
                              stateStore: InstallStateStore(file: root.appendingPathComponent("installs.json")))
    library.located = LocatedGames.scan(store.locations())
    let games = library.games()
    #expect(games.map(\.id) == [onDrive.key])
    #expect(games.allSatisfy { $0.isOffline && $0.isListed && !$0.isInstalled })

    // Deleted while its drive was connected (the scan found nothing there):
    // Waypoint's or Battle.net's record of it isn't kept as offline.
    var emptied = store.locations()[0]
    emptied.installs = []
    let agent = root.appendingPathComponent("product.db")
    var record = ProtoWriter()
    record.string(1, onDrive.uid)
    record.string(2, onDrive.productCode)
    record.message(3) { $0.string(1, onDrive.installPath); $0.string(2, "eu") }
    var database = ProtoWriter()
    database.bytes(1, record.data)
    try database.data.write(to: agent)
    library.located = LocatedGames.scan([emptied])
    #expect(library.located.disconnected == [emptied.id])
    #expect(library.games().filter(\.isListed).isEmpty)
    library.located = LocatedGames.scan(store.locations())
    #expect(library.games().filter(\.isListed).map(\.id) == [onDrive.key])
}

@Test func aScanKeepsAGameKnownThereWhoseFilesAreThereWithoutItsRecords() throws {
    let root = try sandbox("scan-keeps")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Hearthstone", isDirectory: true)
    try makeApp(at: folder.appendingPathComponent("Hearthstone.app"))
    let hearthstone = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU enUS")
    #expect(LocatedGames.installs(at: folder).isEmpty, "no .product.db yet (Battle.net was running)")
    let location = LocatedGames.Location(installedAt: folder, install: hearthstone)
    #expect(LocatedGames.scan([location]).locations.first?.installs.map(\.key) == [hearthstone.key])
    // Its files gone too: no longer known there.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Hearthstone.app"))
    #expect(LocatedGames.scan([location]).locations.first?.installs.isEmpty == true)
}

@Test func aDriveIsKnownByItsVolumeNotJustItsName() throws {
    let fm = FileManager.default
    // The startup disk's link in /Volumes is no drive that's away.
    if let link = (try? fm.contentsOfDirectory(atPath: "/Volumes"))?.first(where: {
        (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/" + $0)) == "/"
    }) {
        #expect(InstallVolume.missingDrive(for: "/Volumes/\(link)/Applications/Hearthstone") == nil)
    }
    // Another volume mounted under the drive's name isn't the drive.
    let mounted = (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
        .map(\.standardizedFileURL.path).filter { $0.hasPrefix("/Volumes/") }
    guard let drive = mounted.first(where: { InstallVolume.volumeUUID(at: URL(fileURLWithPath: $0)) != nil }) else { return }
    let target = drive + "/Waypoint Test \(UUID().uuidString)/Hearthstone"
    let uuid = try #require(InstallVolume.volumeUUID(at: URL(fileURLWithPath: target)))
    #expect(throws: Never.self) { try InstallVolume.ensureConnected(target, volumeUUID: uuid) }
    #expect(throws: Never.self) { try InstallVolume.ensureConnected(target) }
    #expect(throws: UpdateError.self) { try InstallVolume.ensureConnected(target, volumeUUID: UUID().uuidString) }
    #expect(String(describing: UpdateError.otherDrive("T7")) == "“T7” isn’t the drive this download started on.")
    #expect(InstallVolume.volumeUUID(at: URL(fileURLWithPath: "/Applications/Hearthstone")) == nil, "the startup disk is always there")
    #expect(!fm.fileExists(atPath: URL(fileURLWithPath: target).deletingLastPathComponent().path))
}

@Test func gamesAnEarlierVersionInstalledElsewhereAreRememberedOnlyWhenOnDisk() throws {
    let home = try sandbox("adopt-home")
    defer { try? FileManager.default.removeItem(at: home) }
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let chosen = InstallLocations(defaults: defaults, home: home)

    let folder = home.appendingPathComponent("Elsewhere/Hearthstone", isDirectory: true)
    try makeApp(at: folder.appendingPathComponent("Hearthstone.app"))
    let installed = InstallableProduct.hearthstone.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU enUS")
    let gone = ProductInstall(uid: "pro", productCode: "pro", installPath: home.appendingPathComponent("Elsewhere/Overwatch").path,
                              platform: .windows)
    let away = ProductInstall(uid: "wow", productCode: "wow", installPath: unmountedDrive() + "/World of Warcraft")
    let builtIn = ProductInstall(uid: "s2", productCode: "s2", installPath: "/Applications/StarCraft II")

    let found = LocatedGames.unremembered([installed, gone, away, builtIn], known: [], chosen: chosen)
    #expect(found.map(\.path) == [folder.path])
    #expect(found.first?.installs.map(\.key) == [installed.key])
    #expect(LocatedGames.unremembered([installed], known: found, chosen: chosen).isEmpty, "already remembered")
}
