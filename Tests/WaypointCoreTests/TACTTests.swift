import CryptoKit
import Foundation
import Testing
import zlib
@testable import WaypointCore

// MARK: - Fixture builders

private func be(_ value: UInt64, _ size: Int) -> Data {
    Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
}

private func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }

private func zlibCompress(_ data: Data) -> Data {
    var length = compressBound(uLong(data.count))
    var out = [UInt8](repeating: 0, count: Int(length))
    _ = data.withUnsafeBytes { compress2(&out, &length, $0.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 9) }
    return Data(out.prefix(Int(length)))
}

private enum Chunk {
    case raw(Data), zlib(Data)
    var plain: Data { switch self { case .raw(let d), .zlib(let d): d } }
    var encoded: Data {
        switch self {
        case .raw(let d): Data("N".utf8) + d
        case .zlib(let d): Data("Z".utf8) + zlibCompress(d)
        }
    }
}

private func blte(_ chunks: [Chunk]) -> Data {
    var out = Data("BLTE".utf8) + be(UInt64(8 + 4 + 24 * chunks.count), 4)
    out += Data([0x0F]) + be(UInt64(chunks.count), 3)
    for chunk in chunks {
        out += be(UInt64(chunk.encoded.count), 4) + be(UInt64(chunk.plain.count), 4) + md5(chunk.encoded)
    }
    for chunk in chunks { out += chunk.encoded }
    return out
}

private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

// MARK: - BLTE

@Test func blteDecodesRawAndZlibChunks() throws {
    let a = Data("hello ".utf8), b = Data(String(repeating: "world ", count: 5000).utf8)
    let encoded = blte([.raw(a), .zlib(b)])
    #expect(try BLTE.decode(encoded) == a + b)

    // The streaming path gives the same bytes and the content MD5.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blte-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("in"), output = dir.appendingPathComponent("out")
    try encoded.write(to: input)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    let digest = try BLTE.decode(file: input, to: handle)
    try handle.close()
    #expect(try Data(contentsOf: output) == a + b)
    #expect(digest == md5(a + b))
}

@Test func blteWithoutChunkTable() throws {
    let encoded = Data("BLTE".utf8) + be(0, 4) + Data("Z".utf8) + zlibCompress(Data("single".utf8))
    #expect(try BLTE.decode(encoded) == Data("single".utf8))
}

@Test func blteRejectsCorruptChunks() {
    var encoded = blte([.raw(Data("payload".utf8))])
    encoded[encoded.count - 1] ^= 0xFF
    #expect(throws: TACTError.self) { try BLTE.decode(encoded) }
}

@Test func blteRefusesEncryptedChunks() {
    let encoded = Data("BLTE".utf8) + be(0, 4) + Data("E".utf8) + Data(count: 8)
    #expect(throws: TACTError.self) { try BLTE.decode(encoded) }
}

// MARK: - Install manifest

@Test func installManifestSelectsByTagGroups() throws {
    let paths = ["mac/base", "win/base", "mac/de", "mac/en", "mac/en-us-only"]
    // name, type, bits for entries 0...4
    let tags: [(String, UInt16, [Bool])] = [
        ("OSX", 1, [true, false, true, true, true]),
        ("Windows", 1, [false, true, false, false, false]),
        ("EU", 2, [true, true, true, true, false]),
        ("US", 2, [false, false, false, false, true]),
        ("deDE", 3, [true, true, true, false, false]),
        ("enUS", 3, [true, true, false, true, true]),
    ]
    var data = Data("IN".utf8) + Data([1, 16]) + be(UInt64(tags.count), 2) + be(UInt64(paths.count), 4)
    for (name, type, bits) in tags {
        var mask: UInt8 = 0
        for (i, bit) in bits.enumerated() where bit { mask |= 0x80 >> UInt8(i) }
        data += Data(name.utf8) + Data([0]) + be(UInt64(type), 2) + Data([mask])
    }
    for (i, path) in paths.enumerated() {
        data += Data(path.utf8) + Data([0]) + key(UInt8(i)) + be(UInt64(100 + i), 4)
    }

    let manifest = try InstallManifest(data)
    #expect(manifest.entries.count == 5)
    #expect(manifest.entries[3] == .init(path: "mac/en", contentKey: key(3), size: 103))
    // Unknown words are ignored; each mentioned type must match.
    let selected = manifest.select(tagString: "OSX EU? acct-CZE? enUS speech?:OSX EU? enUS text?").map(\.path)
    #expect(selected == ["mac/base", "mac/en"])
    // A type that isn't mentioned (region here) doesn't filter.
    #expect(manifest.select(tagString: "OSX deDE").map(\.path) == ["mac/base", "mac/de"])
}

// MARK: - Tag selection

/// Tag mask bits, MSB first, for entries `0..<count`.
private func tagMask(_ entries: Set<Int>, count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    for i in entries { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
    return Data(bytes)
}

/// A small game tagged the way Blizzard's manifests are: shared files carry
/// every locale and content tag, language files one of each.
private let tagFixturePaths = ["base", "win/base", "us-only", "de/speech", "de/text", "en/speech", "en/text"]
private let tagFixture: [(name: String, type: UInt16, entries: Set<Int>)] = [
    ("OSX", 1, [0, 2, 3, 4, 5, 6]),
    ("Windows", 1, [1]),
    ("EU", 2, [0, 1, 3, 4, 5, 6]),
    ("US", 2, [0, 1, 2, 3, 4, 5, 6]),
    ("deDE", 3, [0, 1, 3, 4]),
    ("enUS", 3, [0, 1, 2, 5, 6]),
    ("speech", 4, [0, 1, 2, 3, 5]),
    ("text", 4, [0, 1, 2, 4, 6]),
]

private func selectFixture(_ tagString: String) -> [String] {
    let count = tagFixturePaths.count
    let tags = tagFixture.map { InstallManifest.Tag(name: $0.name, type: $0.type, mask: tagMask($0.entries, count: count)) }
    return InstallManifest.Tag.selectedIndices(tagString, in: tags, entryCount: count).map { tagFixturePaths[$0] }
}

@Test func tagSelectionSingleSet() {
    #expect(selectFixture("OSX EU enUS speech") == ["base", "en/speech"])
    #expect(selectFixture("Windows deDE") == ["win/base"])
}

@Test func tagSelectionIdenticalSetsMatchOneSet() {
    #expect(selectFixture("OSX EU enUS:OSX EU enUS") == selectFixture("OSX EU enUS"))
    // Same language for speech and text: what merging both sets gave before.
    #expect(selectFixture("OSX EU? enUS speech?:OSX EU? enUS text?") == ["base", "en/speech", "en/text"])
}

@Test func tagSelectionMixedSpeechAndTextLanguages() {
    // German speech, English text: no English speech, no German text.
    #expect(selectFixture("OSX EU? deDE speech?:OSX EU? enUS text?") == ["base", "de/speech", "en/text"])
    // Manifest order is kept whichever set comes first; shared files once.
    #expect(selectFixture("OSX EU? enUS text?:OSX EU? deDE speech?") == ["base", "de/speech", "en/text"])
}

@Test func tagSelectionIgnoresOptionalTagsTheManifestLacks() {
    // acct-CZE and geoip-NL aren't in the manifest; EU is, and filters.
    let tagString = "OSX EU? acct-CZE? geoip-NL? enUS speech?:OSX EU? acct-CZE? geoip-NL? deDE text?"
    #expect(selectFixture(tagString) == ["base", "de/text", "en/speech"])
    // KR isn't in the manifest either, so region doesn't filter.
    #expect(selectFixture("OSX KR? enUS speech") == ["base", "us-only", "en/speech"])
}

@Test func tagSelectionTypesWithoutNamedTagsDontFilter() {
    // No region named: the US-only file stays in.
    #expect(selectFixture("OSX enUS speech") == ["base", "us-only", "en/speech"])
    // No content type named: speech and text both.
    #expect(selectFixture("OSX EU deDE") == ["base", "de/speech", "de/text"])
    #expect(selectFixture("") == tagFixturePaths)
}

@Test func tagSelectionThroughBothManifests() throws {
    let count = tagFixturePaths.count
    let tagString = "OSX EU? deDE speech?:OSX EU? enUS text?"
    var tagData = Data()
    for tag in tagFixture {
        tagData += Data(tag.name.utf8) + Data([0]) + be(UInt64(tag.type), 2) + tagMask(tag.entries, count: count)
    }

    var install = Data("IN".utf8) + Data([1, 16]) + be(UInt64(tagFixture.count), 2) + be(UInt64(count), 4) + tagData
    for (i, path) in tagFixturePaths.enumerated() {
        install += Data(path.utf8) + Data([0]) + key(UInt8(i)) + be(UInt64(i), 4)
    }
    #expect(try InstallManifest(install).select(tagString: tagString).map(\.path) == ["base", "de/speech", "en/text"])

    var download = Data("DL".utf8) + Data([1, 16, 0]) + be(UInt64(count), 4) + be(UInt64(tagFixture.count), 2)
    for i in 0..<count { download += key(UInt8(i)) + be(UInt64(i), 5) + Data([0]) }
    download += tagData
    #expect(try DownloadManifest(download).select(tagString: tagString).map(\.size) == [0, 3, 6])
}

// MARK: - Encoding

@Test func encodingTableFindsWantedKeys() throws {
    let pageSize = 1024
    var page = Data()
    for i: UInt8 in 1...3 {
        page += Data([1]) + be(UInt64(i) * 1000, 5) + key(i) + key(0xA0 + i)
    }
    page += Data(count: pageSize - page.count)
    var data = Data("EN".utf8) + Data([1, 16, 16]) + be(1, 2) + be(1, 2) + be(1, 4) + be(0, 4) + Data([0]) + be(0, 4)
    data += key(1) + md5(page) + page

    let table = try EncodingTable(data, wanted: [key(2), key(3), key(9)])
    #expect(table.entries.count == 2)
    #expect(table.entries[key(2)]?.encodedKey == key(0xA2))
    #expect(table.entries[key(3)]?.size == 3000)
}

// MARK: - Archive index

@Test func archiveIndexLocatesEntries() throws {
    var block = Data()
    block += key(0x11) + be(500, 4) + be(0, 4)
    block += key(0x22) + be(700, 4) + be(500, 4)
    block += Data(count: 4096 - block.count)
    var data = block + key(0x22) + Data(count: 8) // table of contents
    data += Data(count: 8) + Data([1, 0, 0, 4, 4, 4, 16, 8]) + Data([2, 0, 0, 0]) + Data(count: 8)

    let found = try ArchiveIndex.locate([key(0x22), key(0x33)], in: data, archive: "abc")
    #expect(found == [key(0x22): ArchiveLocation(archive: "abc", offset: 500, size: 700)])
}

// MARK: - Tables and configs

@Test func parsesVersionTablesAndConfigs() {
    let table = BPSV("""
    Region!STRING:0|BuildConfig!HEX:16|BuildId!DEC:4
    ## seqn = 1
    us|aaaa|10
    eu|bbbb|11
    """)
    #expect(table.rows.count == 2)
    #expect(table.rows[1]["BuildConfig"] == "bbbb")

    let config = TACTConfig("""
    # Build Configuration

    install = 0011 2233
    build-name = 253932_36.6.3
    """)
    #expect(config.encodedKey("install") == "2233")
    #expect(config["build-name"] == ["253932_36.6.3"])
    #expect(config["missing"].isEmpty)
}

// MARK: - Update decisions

@Test func diffDownloadsOnlyWhatChanged() throws {
    let wanted: [InstallManifest.Entry] = [
        .init(path: "same", contentKey: key(1), size: 10),
        .init(path: "changed", contentKey: key(2), size: 10),
        .init(path: "missing", contentKey: key(3), size: 10),
        .init(path: "wrong-size", contentKey: key(4), size: 10),
    ]
    let previous: [String: Data] = ["same": key(1), "changed": key(0x99), "wrong-size": key(4), "removed": key(5), "already-gone": key(6)]
    let sizes: [String: UInt64] = ["same": 10, "changed": 10, "wrong-size": 9, "removed": 1]

    let result = try GameUpdater.diff(wanted: wanted, previous: previous, localSize: { sizes[$0] },
                                      localHash: { _, _ in Issue.record("should not hash"); return Data() })
    #expect(result.changed.map(\.path) == ["changed", "missing", "wrong-size"])
    #expect(result.deletions == ["removed"])
}

@Test func diffHashesWhenInstalledManifestIsUnknown() throws {
    let wanted: [InstallManifest.Entry] = [
        .init(path: "good", contentKey: key(1), size: 10),
        .init(path: "corrupt", contentKey: key(2), size: 10),
    ]
    let hashes = ["good": key(1), "corrupt": key(0x77)]
    let result = try GameUpdater.diff(wanted: wanted, previous: nil, localSize: { _ in 10 },
                                      localHash: { path, _ in hashes[path]! })
    #expect(result.changed.map(\.path) == ["corrupt"])
    #expect(result.deletions.isEmpty)
}

@Test func refusesPathsOutsideTheGameFolder() throws {
    let updater = GameUpdater(install: ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/Applications/Hearthstone"))
    #expect(throws: UpdateError.self) { try updater.safeURL("../etc/passwd") }
    #expect(throws: UpdateError.self) { try updater.safeURL("/etc/passwd") }
    #expect(throws: UpdateError.self) { try updater.safeURL("Data/./x") }
    #expect(try updater.safeURL("Data/OSX/a.unity3d").path == "/Applications/Hearthstone/Data/OSX/a.unity3d")
}

@Test func installStateKeepsNewerBattleNetVersion() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = InstallStateStore(file: file)
    try store.record(uid: "hs_beta", InstalledBuild(buildConfig: "new", version: "36.6.3.253932"))

    let older = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/x", version: "36.6.0.253216", buildConfig: "old")
    #expect(store.apply(to: older).buildConfig == "new")
    let newer = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: "/x", version: "36.8.0.260000", buildConfig: "bnet")
    #expect(store.apply(to: newer).buildConfig == "bnet")
    #expect(InstallStateStore.compare("36.10.0", "36.9.9") == .orderedDescending)
}

// MARK: - Live CDN (opt-in)

/// Installs a slice of Hearthstone 36.6.0 into a temp folder, updates it to
/// 36.6.3, and checks only the changed files were downloaded.
/// Run with `WAYPOINT_NETWORK_TESTS=1 xcrun swift test --filter liveUpdate`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAYPOINT_NETWORK_TESTS"] == "1"))
func liveUpdateFromPreviousBuild() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-live-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let store = InstallStateStore(file: root.appendingPathComponent(".state.json"))
    let only: @Sendable (String) -> Bool = { path in
        ["Strings/enUS/GLOBAL.txt", "Strings/enUS/GLUE.txt", "Strings/enUS/CREDITS_2014.txt", "Data/OSX/dbf.unity3d"].contains(path)
    }
    var install = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: root.path, region: "eu",
                                 textLanguage: "enUS", tagString: "OSX base dbf strings essential EU? enUS speech?:OSX enUS text?")

    let versions = VersionService()
    let latest = try await versions.latest(product: "hsb", region: .eu)
    let old = ProductVersion(region: "eu", buildConfig: "02d014a785aae84fe6d4bfd64c5ca6ee", cdnConfig: latest.cdnConfig,
                             buildID: 253216, name: "36.6.0.253216")

    let first = GameUpdater(install: install, store: store)
    let initial = try await first.plan(target: old, only: only)
    try await first.apply(initial)
    #expect(initial.files.count == 4)

    install.buildConfig = old.buildConfig
    install.version = old.name
    let second = GameUpdater(install: install, store: store)
    let update = try await second.plan(target: latest, only: only)
    #expect(update.target.buildConfig != old.buildConfig, "live build moved past 36.6.0, as this test assumes")
    #expect(Set(update.files.map(\.path)).isSubset(of: ["Strings/enUS/GLOBAL.txt", "Strings/enUS/GLUE.txt", "Data/OSX/dbf.unity3d"]))
    #expect(!update.files.isEmpty)
    try await second.apply(update)
    #expect(store.load()["hs_beta"]?.buildConfig == latest.buildConfig)

    // Nothing left to do, and the files match the live build exactly.
    var updated = install
    updated.buildConfig = latest.buildConfig
    let verify = try await GameUpdater(install: updated, store: store).plan(target: latest, verify: true, only: only)
    #expect(verify.files.isEmpty)
    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".waypoint-staging").path))
}
