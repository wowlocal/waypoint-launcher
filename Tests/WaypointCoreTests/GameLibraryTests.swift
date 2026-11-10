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
