import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

private final class VerificationVersionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let path = request.value(forHTTPHeaderField: "X-Verification-CDN") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let body = "Name!STRING:0|Path!STRING:0|Hosts!STRING:0\nus|\(path)|example.invalid\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct VerificationFixture {
    enum Damage: CaseIterable, Sendable { case missing, truncated, corrupt }
    let root: URL
    let cache: URL
    let installer: CASCInstaller
    let target: ProductVersion
    let items: [StorageItem]
    let blobs: [Data]
    var storage: URL { root.appendingPathComponent("Data/data") }
    var archive: URL { storage.appendingPathComponent("data.000") }
    var damagedItem: StorageItem { items.last! }

    init() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waypoint-verify-\(UUID())")
        self.root = root
        let path = "tpr/verify-\(UUID().uuidString.lowercased())"
        let cache = CDNClient.defaultCacheDirectory.appendingPathComponent(path)
        self.cache = cache
        func be(_ n: UInt64, _ bytes: Int) -> Data {
            Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) })
        }
        func wrap(_ data: Data) -> Data { Data("BLTE".utf8) + be(0, 4) + Data("N".utf8) + data }
        let installManifest = Data("IN".utf8) + Data([1,16]) + be(0,2) + be(0,4)
        let bulk = [wrap(Data("intact game content".utf8)), wrap(Data("repair this game content".utf8))]
        let bulkKeys = bulk.map { Data(Insecure.MD5.hash(data: $0)) }
        // The cleaner discovers live bulk keys through the encoding table,
        // just as it does for a real build, rather than the download manifest.
        var page = Data()
        for i in bulk.indices { page += Data([1]) + be(UInt64(bulk[i].count), 5) + bulkKeys[i] + bulkKeys[i] }
        page += Data(repeating: 0, count: 1024 - page.count)
        var encoding = Data("EN".utf8)
        encoding += Data([1,16,16])
        encoding += be(1,2)
        encoding += be(0,2)
        encoding += be(1,4)
        encoding += be(0,4)
        encoding += Data([0])
        encoding += be(0,4)
        encoding += Data(repeating: 0, count: 32)
        encoding += page
        var download = Data("DL".utf8) + Data([1,16,0]) + be(2,4) + be(0,2)
        for i in bulk.indices { download += bulkKeys[i] + be(UInt64(bulk[i].count),5) + Data([0]) }
        let decoded = [installManifest, encoding, download]
        let blobs = decoded.map(wrap) + bulk
        self.blobs = blobs
        let keys = blobs.map { Data(Insecure.MD5.hash(data: $0)) }
        let items = blobs.indices.map { StorageItem(key: Key16(keys[$0])!, size: UInt64(blobs[$0].count), fullKey: $0 < 3) }
        self.items = items
        let build = "install = \(keys[0].hex) \(keys[0].hex)\nencoding = \(keys[1].hex) \(keys[1].hex)\ndownload = \(keys[2].hex) \(keys[2].hex)\n"
        let buildKey = Data(Insecure.MD5.hash(data: Data(build.utf8))).hex
        let cdnKey = Data(Insecure.MD5.hash(data: Data())).hex
        target = ProductVersion(region: "us", buildConfig: buildKey, cdnConfig: cdnKey, buildID: 1, name: "1.0")
        func save(_ kind: String, _ key: String, _ body: Data, suffix: String = "") throws {
            let url = cache.appendingPathComponent("\(kind)/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)\(suffix)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url)
        }
        try save("config", buildKey, Data(build.utf8))
        try save("config", cdnKey, Data())
        for i in decoded.indices { try save("data", keys[i].hex, decoded[i], suffix: ".decoded") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerificationVersionProtocol.self]
        config.httpAdditionalHeaders = ["X-Verification-CDN": path]
        let session = URLSession(configuration: config)
        let install = ProductInstall(uid: "wow", productCode: "wow", installPath: root.path, region: "us",
                                     version: "1.0", buildConfig: buildKey, tagString: "OSX enUS")
        installer = CASCInstaller(product: InstallableProduct.forProduct("wow")!, install: install,
                                  config: try ProductConfig(json: Data("{}".utf8)), versions: VersionService(session: session),
                                  store: InstallStateStore(file: root.appendingPathComponent("installs.json")))
        let writer = try CASCStorageWriter(directory: storage)
        for i in items.indices { try writer.append(key: items[i].key, blob: blobs[i], fullKey: items[i].fullKey) }
        try writer.finish()
    }

    func cleanUp() {
        installer.versions.session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cache)
    }

    func damage(_ damage: Damage) throws {
        let fm = FileManager.default
        if damage == .missing { try fm.removeItem(at: archive); return }
        var bytes = try Data(contentsOf: archive)
        if damage == .truncated { bytes.removeLast() }
        else { bytes[bytes.count - 1] ^= 1 }
        try bytes.write(to: archive)
    }

    func serve(_ server: DownloadServer) throws -> CDNClient {
        let fm = FileManager.default
        let directory = server.directory.appendingPathComponent("fixtures")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in items.indices { try blobs[i].write(to: directory.appendingPathComponent(items[i].key.hex)) }
        // The shared download fixture can pause its second request; this test
        // wants every requested repair blob to complete immediately.
        try Data().write(to: server.directory.appendingPathComponent("release"))
        return server.client(["fixtures"])
    }
}

@Test func intactCASCVerificationReusesArchivesWithoutWriting() async throws {
    let fixture = try VerificationFixture()
    defer { fixture.cleanUp() }
    let before = try Data(contentsOf: fixture.archive)
    let plan = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(plan.isEmpty)
    #expect(plan.storage.isEmpty)
    #expect(try Data(contentsOf: fixture.archive) == before)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: VerificationFixture.Damage.allCases)
private func verifyCASCRepairsMissingTruncatedAndCorruptArchives(damage: VerificationFixture.Damage) async throws {
    let fixture = try VerificationFixture()
    defer { fixture.cleanUp() }
    try fixture.damage(damage)
    let fast = try await fixture.installer.plan(target: fixture.target)
    #expect(fast.storage.isEmpty, "Normal checks retain their fast indexed-key path")
    var repair = try await fixture.installer.plan(target: fixture.target, verify: true)
    let expected = damage == .missing ? Set(fixture.items.map(\.key)) : [fixture.damagedItem.key]
    #expect(Set(repair.storage.map(\.key)) == expected)
    let server = try DownloadServer()
    defer { server.stop() }
    repair.cdn = try fixture.serve(server)
    try await fixture.installer.apply(repair)
    let checked = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(checked.isEmpty)
    let state = try #require(try CASC.scanStorage(fixture.storage))
    for item in fixture.items {
        let entries = try CASC.loadBucket(fixture.storage, bucket: item.key.prefix9.bucket,
                                          version: state.versions[item.key.prefix9.bucket])
            .filter { $0.key == item.key.prefix9.data }
        #expect(entries.count == 1, "A replacement supersedes its damaged indexed location")
    }
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: [false, true])
func interruptedCASCRepairsValidateAndReuseTheirJournal(corruptJournal: Bool) async throws {
    let fixture = try VerificationFixture()
    defer { fixture.cleanUp() }
    try fixture.damage(.corrupt)
    let repair = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(repair.storage.count == 1)
    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: fixture.storage, allowExisting: true,
                                                        verifying: repair.storage)
    try writer!.append(key: fixture.damagedItem.key, blob: fixture.blobs.last!, fullKey: false)
    writer = nil // Leave a replacement journal while old indexes remain published.
    if corruptJournal { try fixture.damage(.corrupt) }
    var resumed = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(resumed.storedBytes == (corruptJournal ? 0 : fixture.damagedItem.size))
    let server = try DownloadServer()
    defer { server.stop() }
    resumed.cdn = try fixture.serve(server)
    try await fixture.installer.apply(resumed)
    #expect(try await fixture.installer.plan(target: fixture.target, verify: true).isEmpty)
    if corruptJournal { #expect(try server.requests().count == 1) }
    else { #expect(!FileManager.default.fileExists(atPath: server.directory.appendingPathComponent("requests.jsonl").path)) }
}

@Test func rebuiltCASCArchiveHeadersSupportLaterArchivesAndRecovery() throws {
    let fixture = try VerificationFixture()
    defer { fixture.cleanUp() }
    try fixture.damage(.missing)
    let repair = try CASCStorageWriter(directory: fixture.storage, allowExisting: true, verifying: fixture.items)
    for i in fixture.items.indices {
        try repair.append(key: fixture.items[i].key, blob: fixture.blobs[i], fullKey: fixture.items[i].fullKey)
    }
    try repair.finish()
    let handle = try FileHandle(forReadingFrom: fixture.archive)
    let rebuiltHeader = try #require(try handle.read(upToCount: CASC.segmentHeadersSize))
    try handle.close()
    // Extend sparsely to force the next small blob into data.001, without
    // allocating or writing a gigabyte of test data.
    let output = try FileHandle(forWritingTo: fixture.archive)
    try output.truncate(atOffset: CASC.archiveSize - 5)
    try output.close()
    let blob = Data("BLTE".utf8) + Data([0,0,0,0]) + Data("Nnew archive content".utf8)
    let key = Key16(Data(Insecure.MD5.hash(data: blob)))!
    let item = StorageItem(key: key, size: UInt64(blob.count), fullKey: false)
    var next: CASCStorageWriter? = try CASCStorageWriter(directory: fixture.storage, allowExisting: true)
    try next!.append(key: key, blob: blob, fullKey: false)
    next = nil
    let resumed = try CASCStorageWriter(directory: fixture.storage, allowExisting: true, verifying: [item])
    #expect(resumed.contains(key))
    try resumed.finish()
    let archive1 = try Data(contentsOf: fixture.storage.appendingPathComponent("data.001"))
    let base = Data(rebuiltHeader.prefix(16).reversed())
    #expect(archive1.prefix(CASC.segmentHeadersSize) == CASC.segmentHeaders(baseKey: base, archive: 1).data)
    let selected = (fixture.items + [item]).sorted { $0.key < $1.key }
    #expect(try CASC.verifiedStorage(fixture.storage, items: selected).allSatisfy { $0 })
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: [false, true])
func corruptRepairJournalsPreserveLaterPublishedBuckets(laterArchive: Bool) async throws {
    let fixture = try VerificationFixture()
    defer { fixture.cleanUp() }
    let first = fixture.damagedItem
    let second = fixture.items[3]
    #expect(first.key.prefix9.bucket != second.key.prefix9.bucket)
    let state = try #require(try CASC.scanStorage(fixture.storage))
    let output = try FileHandle(forWritingTo: fixture.archive)
    // Both indexed copies initially need repair.
    for item in [first, second] {
        let entry = try #require(try CASC.loadBucket(fixture.storage, bucket: item.key.prefix9.bucket,
                                                   version: state.versions[item.key.prefix9.bucket])
            .first { $0.key == item.key.prefix9.data })
        try output.seek(toOffset: entry.offset + UInt64(entry.size) - 1)
        try output.write(contentsOf: Data([0]))
    }
    if laterArchive {
        try output.truncate(atOffset: CASC.archiveSize - first.size - UInt64(CASC.headerSize) - 5)
    }
    try output.close()
    let marker = UInt64(try #require(try fixture.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: fixture.storage, allowExisting: true,
                                                        verifying: [first, second])
    try writer!.append(key: first.key, blob: fixture.blobs.last!, fullKey: false)
    try writer!.append(key: second.key, blob: fixture.blobs[3], fullKey: false)
    writer = nil
    // Reproduce finish() publishing B's bucket and crashing before A's.
    let bucket = second.key.prefix9.bucket
    var published = try CASC.loadBucket(fixture.storage, bucket: bucket, version: state.versions[bucket])
        .filter { $0.key != second.key.prefix9.data }
    let secondOffset = laterArchive ? UInt64(CASC.segmentHeadersSize) : marker + first.size + UInt64(CASC.headerSize)
    published.append(CASC.IndexEntry(key: second.key.prefix9.data, archive: laterArchive ? 1 : 0,
                                    offset: secondOffset, size: UInt32(second.size) + UInt32(CASC.headerSize)))
    if laterArchive {
        let input = try FileHandle(forReadingFrom: fixture.archive)
        let base = Data(try #require(try input.read(upToCount: 16)).reversed())
        try input.close()
        published += CASC.segmentHeaders(baseKey: base, archive: 1).entries.filter { $0.bucket == bucket }.map(\.entry)
    }
    try CASC.indexFile(bucket: bucket, entries: published).write(to: fixture.storage.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 2)))
    // Corrupt the earlier journal record's payload after B was published.
    let corrupt = try FileHandle(forWritingTo: fixture.archive)
    try corrupt.seek(toOffset: marker + first.size + UInt64(CASC.headerSize) - 1)
    try corrupt.write(contentsOf: Data([0]))
    try corrupt.close()
    var repair = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(repair.storage.map(\.key) == [first.key], "B is already verified through its new index")
    #expect(repair.storedBytes == 0)
    // A second interruption occurs after the bad journal suffix was removed.
    writer = try CASCStorageWriter(directory: fixture.storage, allowExisting: true, verifying: repair.storage)
    writer = nil
    // A different product can next open this shared storage without verification.
    writer = try CASCStorageWriter(directory: fixture.storage, allowExisting: true)
    writer = nil
    repair = try await fixture.installer.plan(target: fixture.target, verify: true)
    #expect(repair.storage.map(\.key) == [first.key], "Recovery must preserve B across further opens")
    let server = try DownloadServer()
    defer { server.stop() }
    repair.cdn = try fixture.serve(server)
    try await fixture.installer.apply(repair)
    #expect(try await fixture.installer.plan(target: fixture.target, verify: true).isEmpty)
    #expect(try server.requests().count == 1)
}
