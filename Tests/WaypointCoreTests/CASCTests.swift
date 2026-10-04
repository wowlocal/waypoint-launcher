import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

private let fourScore = Array("Four score and seven years ago".utf8)

/// Reference values from driver5() in Bob Jenkins' lookup3.c.
@Test func lookup3MatchesReferenceVectors() {
    #expect(Lookup3.hashlittle2([], 0, 0) == (0xdeadbeef, 0xdeadbeef))
    #expect(Lookup3.hashlittle2([], 0, 0xdeadbeef) == (0xbd5b7dde, 0xdeadbeef))
    #expect(Lookup3.hashlittle2([], 0xdeadbeef, 0xdeadbeef) == (0x9c093ccd, 0xbd5b7dde))
    #expect(Lookup3.hashlittle2(fourScore, 0, 0) == (0x17770551, 0xce7226e6))
    // driver5 prints (c, b) after seeding c=1,b=0 and then c=0,b=1.
    #expect(Lookup3.hashlittle2(fourScore, 1, 0) == (0xcd628161, 0x6cbea4b3))
    #expect(Lookup3.hashlittle2(fourScore, 0, 1) == (0xe3607cae, 0xbd371de4))
    #expect(Lookup3.hashlittle(fourScore, 0) == 0x17770551)
    #expect(Lookup3.hashlittle(fourScore, 1) == 0xcd628161)
}

private func be(_ value: UInt64, _ size: Int) -> Data {
    Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
}

@Test func parsesDownloadManifestAndSelectsByTags() throws {
    func manifest(version: UInt8) -> Data {
        var d = Data("DL".utf8) + Data([version, 16, 1]) + be(3, 4) + be(2, 2)
        if version >= 2 { d += Data([1]) }
        if version >= 3 { d += Data([0, 0, 0, 0]) }
        for i: UInt8 in 1...3 {
            d += Data(repeating: i, count: 16) + be(UInt64(i) * 100, 5) + Data([i - 1]) + be(0xABCD, 4)
            if version >= 2 { d += Data([0]) }
        }
        d += Data("OSX".utf8) + Data([0]) + be(1, 2) + Data([0b1010_0000])      // entries 0, 2
        d += Data("enUS".utf8) + Data([0]) + be(3, 2) + Data([0b0110_0000])     // entries 1, 2
        return d
    }
    for version: UInt8 in 1...3 {
        let m = try DownloadManifest(manifest(version: version))
        #expect(m.entries.count == 3)
        #expect(m.entries[1] == .init(encodedKey: Data(repeating: 2, count: 16), size: 200, priority: 1))
        #expect(m.select(tagString: "OSX enUS speech?").map(\.size) == [300])
        #expect(m.select(tagString: "OSX").map(\.size) == [100, 300])
    }
}

// MARK: - Local storage writer

private func hex(_ s: String) -> Data { Data(hex: s.replacingOccurrences(of: " ", with: ""))! }

/// A real entry from an Agent-written Warcraft III storage (data.011).
@Test func entryHeaderMatchesAgentWrittenExample() {
    let key = hex("000ca380442463454b") + hex("8e13ec98a7b437")
    #expect(CASC.bucket(of: key) == 0)
    let header = CASC.entryHeader(encodedKey: key, blobSize: 24394, archive: 0xb, offset: 0x39297ed4, fullKey: false)
    #expect(header == hex("00000000000000 4b4563244480a30c00 685f0000 0000 1a5c6cfd 7944f970"))
}

/// Parses a v7 .idx the simple way, for checks.
private func parseIndex(_ data: Data) -> [CASC.IndexEntry] {
    let bytes = [UInt8](data)
    let blockSize = Int(bytes[0x20]) | Int(bytes[0x21]) << 8 | Int(bytes[0x22]) << 16 | Int(bytes[0x23]) << 24
    return stride(from: 0x28, to: 0x28 + blockSize, by: 18).map { at in
        let so = (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + 9 + $1]) }
        let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + 14 + $1]) << (8 * UInt32($1)) }
        return CASC.IndexEntry(key: Data(bytes[at..<at + 9]), archive: Int(so >> 30), offset: so & 0x3FFF_FFFF, size: size)
    }
}

/// Rebuilds a Battle.net-written storage's index files and archive heads
/// byte-for-byte. Reads /Applications/Warcraft III only.
/// Run with `WAYPOINT_CASC_REFERENCE=1 xcrun swift test --filter matchesAgent`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAYPOINT_CASC_REFERENCE"] == "1"))
func matchesAgentWrittenStorage() throws {
    let dir = URL(fileURLWithPath: "/Applications/Warcraft III/Data/data")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }
    var latest: [Int: UInt32] = [:]
    for name in files {
        let bucket = Int(name.prefix(2), radix: 16)!, version = UInt32(name.dropFirst(2).prefix(8), radix: 16)!
        latest[bucket] = max(latest[bucket] ?? 0, version)
    }
    #expect(latest.count == 16)
    for (bucket, version) in latest {
        let real = try Data(contentsOf: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: version)))
        #expect(CASC.indexFile(bucket: bucket, entries: parseIndex(real)) == real, "bucket \(bucket)")
    }
    var archive = 0
    while let handle = try? FileHandle(forReadingFrom: dir.appendingPathComponent(String(format: "data.%03d", archive))) {
        let head = try handle.read(upToCount: CASC.segmentHeadersSize) ?? Data()
        try handle.close()
        let base = Data(head.prefix(16).reversed())
        #expect(CASC.segmentHeaders(baseKey: base, archive: archive).data == head, "data.\(archive)")
        archive += 1
    }
    #expect(archive > 0)
}

@Test func writerRoundTripsAndResumesAfterACrash() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    func key(_ i: Int) -> Data { Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i &* 7) }) }
    func blob(_ i: Int) -> Data { Data(repeating: UInt8(i), count: 100 + i) }

    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: dir)
    for i in 0..<20 { try writer!.append(encodedKey: key(i), blob: blob(i), fullKey: i == 0) }
    writer = nil // crash: no finish(); then garbage lands after the last blob
    let archive0 = dir.appendingPathComponent("data.000")
    let handle = try FileHandle(forWritingTo: archive0)
    try handle.seekToEnd()
    handle.write(Data(repeating: 0xEE, count: 777))
    try handle.close()

    let resumed = try CASCStorageWriter(directory: dir)
    #expect(resumed.count == 20)
    #expect(resumed.contains(key(5)))
    for i in 15..<30 { try resumed.append(encodedKey: key(i), blob: blob(i), fullKey: false) }
    try resumed.finish()

    #expect(!fm.fileExists(atPath: dir.appendingPathComponent(".waypoint-journal").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("shmem").path))
    let archive = try Data(contentsOf: archive0)
    var found = 0
    for bucket in 0..<16 {
        let file = try Data(contentsOf: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 1)))
        for entry in parseIndex(file) {
            #expect(CASC.bucket(of: entry.key) == bucket || entry.size == 30)
            let start = Int(entry.offset), end = start + Int(entry.size)
            #expect(end <= archive.count)
            if entry.size == 30 { continue } // segment header
            let i = (0..<30).first { key($0).prefix(9) == entry.key }!
            let header = archive.subdata(in: start..<start + 30)
            #expect(header == CASC.entryHeader(encodedKey: key(i), blobSize: blob(i).count, archive: 0, offset: entry.offset, fullKey: i == 0))
            #expect(archive.subdata(in: start + 30..<end) == blob(i))
            found += 1
        }
    }
    #expect(found == 30)
    // Nothing but whole entries: the garbage was cut off.
    let expectedSize = CASC.segmentHeadersSize + (0..<30).reduce(0) { $0 + 30 + blob($1).count }
    #expect(archive.count == expectedSize)
}

// MARK: - Installer pieces

@Test func batchesMergeNeighboursAndSplitOnGapsAndSize() {
    // Archive 0 is "a", 1 is "b".
    func item(_ archive: Int32, _ offset: UInt32, _ size: UInt64) -> StorageItem {
        var item = StorageItem(key: Key16(hi: UInt64(archive), lo: UInt64(offset)), size: size, fullKey: false)
        item.archive = archive
        item.offset = offset
        return item
    }
    let loose = StorageItem(key: Key16(hi: 9, lo: 9), size: 5, fullKey: false)
    let items = [item(1, 0, 100), item(0, 300, 100), item(0, 0, 100), item(0, 100, 100), item(0, 10_000, 100), loose]
    let batches = CASCInstaller.batches(items, maxBytes: 1_000, maxGap: 500)
    #expect(batches.map(\.archive) == [0, 0, 1, -1])
    #expect(batches[0].items == [2, 3, 1])     // offsets 0, 100 and 300 (gap 100)
    #expect((batches[0].start, batches[0].end) == (0, 400))
    #expect(batches[1].start == 10_000)          // gap too big
    #expect(batches[3].items == [5])
    #expect(CASCInstaller.batches(items, maxBytes: 250, maxGap: 500).filter { $0.archive == 0 }.count == 3)
    // Already stored items are left out.
    #expect(CASCInstaller.batches(items, maxBytes: 1_000, maxGap: 500) { $0.offset == 100 }[0].items == [2, 1])
}

/// Keys as integers keep the byte order, and the bucket matches the Data path.
@Test func compactKeysMatchTheirBytes() {
    let bytes = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) })
    let key = Key16(bytes)!
    #expect(key.data == bytes)
    #expect(key.hex == bytes.hex)
    #expect(key.prefix9 == Key9(bytes)!)
    #expect(key.prefix9.data == bytes.prefix(9))
    #expect(key.prefix9.bucket == CASC.bucket(of: bytes))
    let smaller = Key16(Data([0x00] + [UInt8](repeating: 0xFF, count: 15)))!, larger = Key16(Data([0x01] + [UInt8](repeating: 0, count: 15)))!
    #expect(smaller < larger)
    #expect([Key9(hi: 1, lo: 0), Key9(hi: 1, lo: 5), Key9(hi: 2, lo: 0)].sortedContains(Key9(hi: 1, lo: 5)))
    #expect(![Key9(hi: 1, lo: 0), Key9(hi: 2, lo: 0)].sortedContains(Key9(hi: 1, lo: 5)))
}

@Test func verifiesBlobsWithoutDecodingThem() throws {
    let chunk = Data("N".utf8) + Data("hello".utf8)
    var blob = Data("BLTE".utf8) + Data([0, 0, 0, 36, 0x0F, 0, 0, 1])
    blob += Data([0, 0, 0, UInt8(chunk.count), 0, 0, 0, 5]) + Data(Insecure.MD5.hash(data: chunk))
    blob += chunk
    let key = Data(Insecure.MD5.hash(data: blob.prefix(36)))
    try BLTE.verify(blob, encodedKey: key)

    var badChunk = blob
    badChunk[badChunk.count - 1] ^= 1
    #expect(throws: TACTError.self) { try BLTE.verify(badChunk, encodedKey: key) }
    #expect(throws: TACTError.self) { try BLTE.verify(blob, encodedKey: Data(repeating: 0, count: 16)) }
    #expect(throws: TACTError.self) { try BLTE.verify(blob + Data([0]), encodedKey: key) }
}

/// A failed write (a full disk; here a file-size limit) used to raise an
/// Objective-C exception in FileHandle.write(_:) and abort the app. It must
/// throw, cut off the partial write, and let the caller retry. Runs in a
/// child process because the limit applies to the whole process.
@Test func writeFailureThrowsAndCanBeRetried() async {
    await #expect(processExitsWith: .success) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let first = Data(repeating: 0xA1, count: 16), second = Data(repeating: 0xB2, count: 16)
        let small = Data(repeating: 1, count: 1000), big = Data(repeating: 2, count: 200_000)
        let writer = try CASCStorageWriter(directory: dir)
        try writer.append(encodedKey: first, blob: small, fullKey: false)
        let archive = dir.appendingPathComponent("data.000")
        let sizeBefore = try fm.attributesOfItem(atPath: archive.path)[.size] as! Int

        signal(SIGXFSZ, SIG_IGN) // make write(2) fail with EFBIG instead of killing us
        var limit = rlimit()
        getrlimit(RLIMIT_FSIZE, &limit)
        let unlimited = limit
        limit.rlim_cur = 100_000
        setrlimit(RLIMIT_FSIZE, &limit)
        var threw = false
        do { try writer.append(encodedKey: second, blob: big, fullKey: false) } catch { threw = true }
        limit = unlimited
        setrlimit(RLIMIT_FSIZE, &limit)
        guard threw, !writer.contains(second) else { exit(1) }
        guard try fm.attributesOfItem(atPath: archive.path)[.size] as! Int == sizeBefore else { exit(2) }

        try writer.append(encodedKey: second, blob: big, fullKey: false)
        try writer.finish()
        let data = try Data(contentsOf: archive)
        guard data.count == sizeBefore + 30 + big.count, data.suffix(big.count) == big else { exit(3) }
    }
}

/// Opening a writer on a finished storage used to start over silently:
/// the first blob overwrote data.000, and finish() deleted the other archives
/// (or, with nothing appended, every archive).
@Test func finishedStorageIsNeverOverwritten() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let key = Data(repeating: 0x5A, count: 16)
    let writer = try CASCStorageWriter(directory: dir)
    // Too big for any archive: would overflow the 30-bit offsets.
    #expect(throws: TACTError.self) { try writer.append(encodedKey: key, blob: Data(count: 1 << 30), fullKey: false) }
    try writer.append(encodedKey: key, blob: Data(repeating: 7, count: 500), fullKey: false)
    try writer.finish()
    #expect(throws: TACTError.self) { try writer.append(encodedKey: Data(repeating: 1, count: 16), blob: Data([1]), fullKey: false) }
    #expect(throws: TACTError.self) { try writer.finish() }

    let archive = dir.appendingPathComponent("data.000")
    let before = try Data(contentsOf: archive)
    #expect(throws: TACTError.self) { _ = try CASCStorageWriter(directory: dir) }
    #expect(try Data(contentsOf: archive) == before)
    #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }.count == 16)
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent(".waypoint-journal").path))
}

// MARK: - Updates (adding to a finished storage)

private func storageKey(_ i: Int) -> Data { Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ i &* 29 &+ 1) }) }
private func storageBlob(_ i: Int) -> Data { Data(repeating: UInt8(truncatingIfNeeded: i), count: 200 + i) }

/// Every key's index entry points at its header and blob in the archive.
private func expectStored(_ keys: Range<Int>, in dir: URL, version: UInt32) throws {
    let fm = FileManager.default
    let indexes = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }.sorted()
    #expect(indexes == (0..<16).map { CASC.indexFileName(bucket: $0, version: version) })
    var entries: [Data: CASC.IndexEntry] = [:]
    for bucket in 0..<16 {
        for entry in parseIndex(try Data(contentsOf: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: version))))
        where entry.size != 30 {
            #expect(entries[entry.key] == nil, "one entry per key")
            entries[entry.key] = entry
        }
    }
    #expect(entries.count == keys.count)
    for i in keys {
        let entry = try #require(entries[storageKey(i).prefix(9)])
        let archive = try Data(contentsOf: dir.appendingPathComponent(String(format: "data.%03d", entry.archive)))
        let start = Int(entry.offset)
        #expect(archive.subdata(in: start..<start + 30)
                == CASC.entryHeader(encodedKey: storageKey(i), blobSize: storageBlob(i).count, archive: entry.archive, offset: entry.offset, fullKey: false))
        #expect(archive.subdata(in: start + 30..<start + Int(entry.size)) == storageBlob(i))
    }
    let shmem = try Data(contentsOf: dir.appendingPathComponent("shmem"))
    #expect((0..<16).allSatisfy { shmem[0x110 + 4 * $0] == UInt8(version) })
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent(".waypoint-journal").path))
}

@Test func updateAppendsToAFinishedStorage() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let first = try CASCStorageWriter(directory: dir)
    for i in 0..<20 { try first.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    try first.finish()
    let before = try Data(contentsOf: dir.appendingPathComponent("data.000"))
    try expectStored(0..<20, in: dir, version: 1)

    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    #expect(update.isUpdate)
    #expect(update.contains(storageKey(7)))
    for i in 15..<30 { try update.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) } // 15..<20 are skipped
    try update.finish()

    try expectStored(0..<30, in: dir, version: 2)
    let after = try Data(contentsOf: dir.appendingPathComponent("data.000"))
    #expect(after.prefix(before.count) == before, "existing data is never rewritten")
    #expect(after.count == before.count + (20..<30).reduce(0) { $0 + 30 + storageBlob($1).count })

    // A second update with nothing new still leaves a consistent storage.
    let noop = try CASCStorageWriter(directory: dir, allowExisting: true)
    try noop.finish()
    try expectStored(0..<30, in: dir, version: 3)
}

@Test func interruptedUpdateResumesAndKeepsOldData() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let first = try CASCStorageWriter(directory: dir)
    for i in 0..<10 { try first.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    try first.finish()
    let archive0 = dir.appendingPathComponent("data.000")
    let before = try Data(contentsOf: archive0)

    func addGarbage() throws {
        let handle = try FileHandle(forWritingTo: archive0)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 333))
        try handle.close()
    }
    // Crash before anything was written: the garbage after the old end goes.
    var update: CASCStorageWriter? = try CASCStorageWriter(directory: dir, allowExisting: true)
    update = nil
    try addGarbage()
    // Crash midway: the old index files are still the complete old storage.
    update = try CASCStorageWriter(directory: dir, allowExisting: true)
    for i in 10..<15 { try update!.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    update = nil
    try addGarbage()
    try expectStoredIndexesOnly(dir, version: 1)

    let resumed = try CASCStorageWriter(directory: dir, allowExisting: false) // a journal: resuming needs no permission
    #expect(resumed.isUpdate)
    #expect(resumed.contains(storageKey(12)) && resumed.contains(storageKey(3)))
    for i in 15..<20 { try resumed.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    try resumed.finish()

    try expectStored(0..<20, in: dir, version: 2)
    let after = try Data(contentsOf: archive0)
    #expect(after.prefix(before.count) == before)
    #expect(after.count == before.count + (10..<20).reduce(0) { $0 + 30 + storageBlob($1).count })
}

private func expectStoredIndexesOnly(_ dir: URL, version: UInt32) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }.sorted()
    #expect(names == (0..<16).map { CASC.indexFileName(bucket: $0, version: version) })
}

/// The update section the game and the Agent append to before merging:
/// later records win, and a non-zero status removes the key.
@Test func loadsIndexUpdateSection() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = Data(repeating: 0x11, count: 9), b = Data(repeating: 0x22, count: 9), c = Data(repeating: 0x33, count: 9)
    var index = [UInt8](CASC.indexFile(bucket: 0, entries: [
        CASC.IndexEntry(key: a, archive: 0, offset: 0x1E0, size: 100),
        CASC.IndexEntry(key: b, archive: 0, offset: 0x244, size: 100),
    ]))
    func record(_ key: Data, offset: UInt64, size: UInt32, status: UInt8) -> [UInt8] {
        var body = [UInt8](key) + (0..<5).reversed().map { UInt8(truncatingIfNeeded: offset >> (8 * UInt64($0))) }
        body += CASC.le32(size) + [status]
        let guardValue = Lookup3.hashlittle(body, 0) | 0x8000_0000
        return CASC.le32(guardValue) + body + [0]
    }
    let page = (0x28 + 2 * 18 + 0x1FF) & ~0x1FF
    let updates = record(c, offset: 0x2A8, size: 50, status: 0) + record(b, offset: 0x244, size: 100, status: 3)
    index.replaceSubrange(page..<page + updates.count, with: updates)
    try Data(index).write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: 0, version: 5)))
    for bucket in 1..<16 {
        try CASC.indexFile(bucket: bucket, entries: []).write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 5)))
    }
    let state = try #require(try CASC.scanStorage(dir))
    #expect(state.versions == [UInt32](repeating: 5, count: 16))
    let entries = try CASC.loadBucket(dir, bucket: 0, version: 5)
    #expect(Set(entries.map(\.key)) == [a, c])
    #expect(entries.first { $0.key == c }?.size == 50)
    let keys = try #require(try StoredKeys.load(dir))
    #expect(keys.count == 2)
}
