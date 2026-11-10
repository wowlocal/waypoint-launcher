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

/// A first install stopped before `finish()`: archives and a journal, no
/// index files. Planning the resumed install sees no storage yet (it threw
/// "has 0 of 16 index files", so Resume and Try Again failed). Without the
/// journal, missing index files still mean a broken storage.
@Test func unfinishedNewStorageIsNotAStorageYet() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: dir)
    for i in 0..<10 { try writer!.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    writer = nil
    #expect(try StoredKeys.load(dir) == nil)

    let resumed = try CASCStorageWriter(directory: dir)
    #expect(!resumed.isUpdate)
    #expect(resumed.contains(storageKey(4)))
    try resumed.finish()
    try expectStored(0..<10, in: dir, version: 1)

    for name in try fm.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".idx") {
        try fm.removeItem(at: dir.appendingPathComponent(name))
    }
    #expect(throws: TACTError.self) { try StoredKeys.load(dir) }
    // A journal without its base key isn't one the writer resumes either.
    let journal = dir.appendingPathComponent(CASCStorageWriter.journalName)
    try Data(count: 10).write(to: journal)
    #expect(throws: TACTError.self) { try StoredKeys.load(dir) }
    try fm.removeItem(at: journal)

    // An update's journal (it starts with a marker) needs the old index files.
    let other = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: other) }
    let first = try CASCStorageWriter(directory: other)
    try first.append(encodedKey: storageKey(0), blob: storageBlob(0), fullKey: false)
    try first.finish()
    var update: CASCStorageWriter? = try CASCStorageWriter(directory: other, allowExisting: true)
    try update!.append(encodedKey: storageKey(1), blob: storageBlob(1), fullKey: false)
    update = nil
    for name in try fm.contentsOfDirectory(atPath: other.path) where name.hasSuffix(".idx") {
        try fm.removeItem(at: other.appendingPathComponent(name))
    }
    #expect(throws: TACTError.self) { try StoredKeys.load(other) }
}

/// A plan counts as downloaded exactly what resuming keeps: journaled blobs
/// whose bytes reached disk, and for an update only what it added.
@Test func plansCountWhatResumingKeeps() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    func resumable() -> [Key16] {
        var keys: [Key16] = []
        CASCStorageWriter.forEachResumableKey(in: dir) { keys.append($0) }
        return keys.sorted()
    }
    func keys(_ range: Range<Int>) -> [Key16] { range.map { Key16(storageKey($0))! }.sorted() }
    let plan = (0..<20).map { StorageItem(key: Key16(storageKey($0))!, size: UInt64(storageBlob($0).count), fullKey: false) }
        .sorted { $0.key < $1.key }
    func bytes(_ range: Range<Int>) -> UInt64 { range.reduce(0) { $0 + UInt64(storageBlob($1).count) } }
    #expect(resumable().isEmpty)
    #expect(CASCInstaller.storedBytes(plan, in: dir) == 0)

    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: dir)
    for i in 0..<10 { try writer!.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    writer = nil
    // A torn write: the last blob's bytes didn't all reach disk.
    let archive0 = dir.appendingPathComponent("data.000")
    let size = try #require(archive0.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let handle = try FileHandle(forWritingTo: archive0)
    try handle.truncate(atOffset: UInt64(size - 10))
    try handle.close()
    #expect(resumable() == keys(0..<9))
    #expect(CASCInstaller.storedBytes(plan, in: dir) == bytes(0..<9))
    let resumed = try CASCStorageWriter(directory: dir)
    #expect(resumed.count == 9)
    #expect(!resumed.contains(storageKey(9)))
    try resumed.finish()
    #expect(resumable().isEmpty)

    var update: CASCStorageWriter? = try CASCStorageWriter(directory: dir, allowExisting: true)
    for i in 9..<12 { try update!.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    update = nil
    #expect(resumable() == keys(9..<12))
    #expect(CASCInstaller.storedBytes(plan, in: dir) == bytes(9..<12))
}

/// WoW's flavors share one storage: a second writer (or the cleaner) must
/// not write to it while another one is, in this process or another.
@Test func oneWriterPerStorage() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    var writer: CASCStorageWriter? = try CASCStorageWriter(directory: dir)
    try writer!.append(encodedKey: storageKey(0), blob: storageBlob(0), fullKey: false)
    #expect(throws: UpdateError.self) { _ = try CASCStorageWriter(directory: dir) }
    #expect(throws: UpdateError.self) { _ = try CASCStorageCleaner.clean(dir) { _ in true } }
    writer = nil // paused: the journal stays, the folder is free again

    let resumed = try CASCStorageWriter(directory: dir)
    #expect(resumed.contains(storageKey(0)))
    try resumed.append(encodedKey: storageKey(1), blob: storageBlob(1), fullKey: false)
    try resumed.finish() // done: the next writer needn't wait for this one to be freed
    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.finish()
    try expectStored(0..<2, in: dir, version: 2)
}

/// A hold that ends within a second isn't another writer (any process being
/// started briefly has every descriptor): taking the lock waits it out.
@Test func storageLockWaitsOutAShortHold() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    nonisolated(unsafe) let first = try StorageLock(dir)
    let started = ContinuousClock.now
    // Synchronous parallel tests can occupy the shared dispatch workers for
    // longer than the lock timeout. Give the timed release its own thread.
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.2)
        first.release()
    }
    let second = try StorageLock(dir)
    #expect(ContinuousClock.now - started >= .milliseconds(150))
    second.release()
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

// MARK: - The game's update section (issue #3)

/// `count` distinct entries for one index file.
private func indexEntries(_ count: Int) -> [CASC.IndexEntry] {
    (0..<count).map { i in
        var key = [UInt8](repeating: 0, count: 9)
        for byte in 0..<4 { key[byte] = UInt8(truncatingIfNeeded: i >> (8 * byte)) }
        key[8] = 0xA5
        return CASC.IndexEntry(key: Data(key), archive: 0, offset: UInt64(CASC.segmentHeadersSize + i * 0x40), size: 0x40)
    }
}

/// Waypoint 0.9.5's rule: the reserve measured from the entries' end, not
/// from the 4 KiB boundary the game starts its update section at.
private func shortIndexFileSize(sortedEnd: Int) -> Int { (sortedEnd + 0x7800 + 0xFFFF) & ~0xFFFF }

private func updateSectionRoom(size: Int, sortedEnd: Int) -> Int {
    size - ((sortedEnd + 0xFFF) & ~0xFFF)
}

/// Every index file leaves the game its update section: 0x7800 bytes from the
/// 4 KiB boundary after the sorted entries. 121,968 entries in one bucket (WoW
/// Forever 1.60.1, issue #3) left 0x7000 of it, and the game refused the
/// storage with "Truncated KMT update section detected" and asked to be
/// repaired, with every file of the install present and sound.
@Test func indexFileSizeLeavesTheGameItsUpdateSection() {
    for entries in [0, 1, 1_000, 1_819, 1_820, 3_640, 4_738, 50_000, 119_647, 120_866, 121_968, 200_000] {
        let sortedEnd = 0x28 + 18 * entries
        let size = CASC.indexFileSize(sortedEnd: sortedEnd)
        #expect(size % 0x10000 == 0, "\(entries) entries")
        #expect(size >= sortedEnd + 0x7800, "\(entries) entries")
        #expect(updateSectionRoom(size: size, sortedEnd: sortedEnd) >= 0x7800, "\(entries) entries")
    }
    // The reported case, and the one before the boundary moved.
    #expect(CASC.indexFileSize(sortedEnd: 0x28 + 18 * 121_968) == 0x230000)
    #expect(shortIndexFileSize(sortedEnd: 0x28 + 18 * 121_968) == 0x220000)
    #expect(updateSectionRoom(size: 0x220000, sortedEnd: 0x28 + 18 * 121_968) == 0x7000)
}

/// Agent-written index files, so the fix stays byte-compatible with them:
/// the entry counts of the 16 index files of a Battle.net-installed Warcraft
/// III (131,072 bytes each) and World of Warcraft with the Forever flavor
/// (2,228,224 bytes each), measured on 2026-11-09.
@Test func indexFileSizeMatchesAgentWrittenSizes() {
    let warcraftIII = [4738, 4726, 4711, 4703, 4725, 4614, 4758, 4658, 4567, 4730, 4789, 4692, 4663, 4679, 4761, 4757]
    let worldOfWarcraft = [119_967, 119_993, 119_863, 119_776, 119_647, 120_020, 120_223, 120_508,
                           120_482, 119_805, 119_690, 119_801, 120_223, 119_975, 120_866, 120_762]
    for entries in warcraftIII {
        #expect(CASC.indexFileSize(sortedEnd: 0x28 + 18 * entries) == 131_072, "\(entries) entries")
    }
    for entries in worldOfWarcraft {
        #expect(CASC.indexFileSize(sortedEnd: 0x28 + 18 * entries) == 2_228_224, "\(entries) entries")
    }
}

/// A written index file is as big as that, and reads back whole.
@Test func writtenIndexFileHasRoomForTheUpdateSection() throws {
    // 1,819 entries is the smallest count the old rule got wrong.
    let entries = indexEntries(1_819)
    let sortedEnd = 0x28 + 18 * entries.count
    let file = CASC.indexFile(bucket: 3, entries: entries)
    #expect(file.count == 0x20000)
    #expect(shortIndexFileSize(sortedEnd: sortedEnd) == 0x10000) // what 0.9.5 wrote
    #expect(updateSectionRoom(size: file.count, sortedEnd: sortedEnd) >= 0x7800)
    let parsed = try CASC.parseIndexFile(file)
    #expect(parsed.bucket == 3)
    #expect(parsed.sortedEnd == sortedEnd)
    #expect(parsed.entries.count == entries.count)
    #expect(parsed.updates.isEmpty)
    #expect(file[sortedEnd...].allSatisfy { $0 == 0 })
}

/// Writes a storage whose bucket-0 index is as short as Waypoint 0.9.5 left
/// it (the other 15 buckets are empty and were big enough all along).
private func shortIndexStorage(_ dir: URL, entries: [CASC.IndexEntry], version: UInt32 = 1,
                               tail: [UInt8] = []) throws -> (url: URL, kept: Data) {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var file = [UInt8](CASC.indexFile(bucket: 0, entries: entries))
    let sortedEnd = 0x28 + 18 * entries.count
    let short = shortIndexFileSize(sortedEnd: sortedEnd)
    #expect(short < file.count, "this index was long enough already")
    file = Array(file[0..<short])
    if !tail.isEmpty {
        let page = (sortedEnd + 0x1FF) & ~0x1FF
        file.replaceSubrange(page..<page + tail.count, with: tail)
    }
    let url = dir.appendingPathComponent(CASC.indexFileName(bucket: 0, version: version))
    try Data(file).write(to: url)
    for bucket in 1..<16 {
        try CASC.indexFile(bucket: bucket, entries: [])
            .write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: version)))
    }
    try CASC.segmentHeaders(baseKey: Data(repeating: 7, count: 16), archive: 0).data
        .write(to: dir.appendingPathComponent("data.000"))
    return (url, Data(file))
}

/// Verifying files repairs an install an older Waypoint left unlaunchable,
/// without any game content changing: the short index file gets the room the
/// game needs, and nothing else about it moves.
@Test func repairGivesShortIndexesTheirUpdateSectionBack() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let entries = indexEntries(1_819)
    let (url, before) = try shortIndexStorage(dir, entries: entries)
    let keys = try #require(try StoredKeys.load(dir))

    let repair = try CASC.repairIndexReserve(dir)
    #expect(repair.repaired == [CASC.indexFileName(bucket: 0, version: 1)])
    #expect(repair.skipped.isEmpty)

    let after = try Data(contentsOf: url)
    let sortedEnd = 0x28 + 18 * entries.count
    #expect(after.count == CASC.indexFileSize(sortedEnd: sortedEnd))
    #expect(updateSectionRoom(size: after.count, sortedEnd: sortedEnd) >= 0x7800)
    // Header, entries and checksums keep their bytes; only zeros were added.
    #expect(after.prefix(before.count) == before)
    #expect(after.dropFirst(before.count).allSatisfy { $0 == 0 })
    #expect(try CASC.loadBucket(dir, bucket: 0, version: 1).count == entries.count)
    #expect(try StoredKeys.load(dir)?.count == keys.count)
    // Index versions don't change, so no reader is sent looking for a new file.
    #expect(try CASC.scanStorage(dir)?.versions == [UInt32](repeating: 1, count: 16))
    #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }.count == 16)
    // Running it again changes nothing.
    #expect(try CASC.repairIndexReserve(dir).isEmpty)
    #expect(try Data(contentsOf: url) == after)
}

/// What the repair must not touch: storages this version or the Agent wrote,
/// an index whose update section is in use, and an unfinished install.
@Test func repairLeavesSoundAndBusyStoragesAlone() throws {
    let fm = FileManager.default

    // A storage this version wrote (so, by size, an Agent-written one too).
    let written = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: written) }
    let writer = try CASCStorageWriter(directory: written)
    for i in 0..<20 { try writer.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    try writer.finish()
    func indexSizes() throws -> [UInt64] {
        try (0..<16).map { bucket in
            let url = written.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 1))
            return try fm.attributesOfItem(atPath: url.path)[.size] as! UInt64
        }
    }
    let sizes = try indexSizes()
    #expect(try CASC.repairIndexReserve(written).isEmpty)
    #expect(try indexSizes() == sizes)

    // A short index whose update section already holds a record: appending to
    // it is safe, but a game that got that far is better left to its own
    // repair, so the file is reported and left exactly as it is.
    let used = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: used) }
    let entries = indexEntries(1_819)
    var record = [UInt8](repeating: 0x5C, count: 9) + [UInt8](repeating: 0, count: 5) + CASC.le32(0x40) + [0]
    record = CASC.le32(Lookup3.hashlittle(record, 0) | 0x8000_0000) + record + [0]
    let (usedURL, usedBefore) = try shortIndexStorage(used, entries: entries, tail: record)
    let usedRepair = try CASC.repairIndexReserve(used)
    #expect(usedRepair.repaired.isEmpty)
    #expect(usedRepair.skipped == [CASC.indexFileName(bucket: 0, version: 1)])
    #expect(try Data(contentsOf: usedURL) == usedBefore)

    // An unfinished install or update: its own writer finishes the job.
    let busy = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: busy) }
    let (busyURL, busyBefore) = try shortIndexStorage(busy, entries: entries)
    try Data(repeating: 0, count: 16).write(to: busy.appendingPathComponent(CASCStorageWriter.journalName))
    do {
        _ = try CASC.repairIndexReserve(busy)
        Issue.record("An unfinished journal must be reported")
    } catch UpdateError.unfinishedStorage(let path) {
        #expect(path == busy.path)
    }
    #expect(try Data(contentsOf: busyURL) == busyBefore)

    // Nothing to repair where there is no storage.
    #expect(try CASC.repairIndexReserve(fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)).isEmpty)
}

/// An update that appends to a repaired storage keeps working: the next
/// index version is written from scratch, at the size the game wants.
@Test func updateAfterRepairWritesFullSizedIndexes() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let entries = indexEntries(1_819)
    _ = try shortIndexStorage(dir, entries: entries)
    #expect(try CASC.repairIndexReserve(dir).repaired.count == 1)

    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: storageKey(1), blob: storageBlob(1), fullKey: false)
    try update.finish()
    try expectStoredIndexesOnly(dir, version: 2)
    for bucket in 0..<16 {
        let file = try Data(contentsOf: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 2)))
        let parsed = try CASC.parseIndexFile(file)
        #expect(file.count == CASC.indexFileSize(sortedEnd: parsed.sortedEnd))
        #expect(updateSectionRoom(size: file.count, sortedEnd: parsed.sortedEnd) >= 0x7800)
    }
    #expect(try CASC.loadBucket(dir, bucket: 0, version: 2).count >= entries.count)
}

private final class IndexRepairRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class IndexRepairOfflineProtocol: URLProtocol, @unchecked Sendable {
    static let requests = IndexRepairRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.record()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

private func indexRepairPlan(at root: URL) throws -> CASCInstallPlan {
    let product = try #require(InstallableProduct.fallbackNative.first { $0.productCode == "s2" })
    let target = ProductVersion(region: "eu", buildConfig: String(repeating: "a", count: 32),
                                cdnConfig: String(repeating: "b", count: 32), buildID: 1, name: "1.0")
    let install = ProductInstall(uid: "s2", productCode: "s2", installPath: root.path, region: "eu",
                                 version: target.name, buildConfig: target.buildConfig, tagString: "OSX enUS")
    let config = try ProductConfig(json: Data(#"{"all":{"config":{"data_dir":"SC2Data/"}}}"#.utf8))
    let cdn = CDNClient(product: "s2", path: "tpr/test", servers: [])
    let loose = UpdatePlan(install: install, target: target, cdn: cdn, files: [], deletions: [])
    return CASCInstallPlan(install: install, product: product, config: config, target: target, cdn: cdn,
                           buildConfig: Data(), cdnConfig: Data(), archives: [], storage: [], loose: loose)
}

/// Both the app and CLI use isEmpty to choose between apply and a local
/// repair. A leftover backfill journal must take apply even at the same build.
@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: [true, false])
func zeroDownloadUpdateFinishesAStrandedJournalAndRepairsOldIndexes(updateJournal: Bool) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-journal-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("SC2Data/data")
    _ = try shortIndexStorage(dir, entries: indexEntries(1_819))
    let archive = dir.appendingPathComponent("data.000")
    let plan = try indexRepairPlan(at: root)
    #expect(plan.isEmpty)
    if updateJournal {
        try autoreleasepool {
            let paused = try CASCStorageWriter(directory: dir, allowExisting: true)
            try paused.append(encodedKey: storageKey(42), blob: storageBlob(42), fullKey: false)
        }
    } else {
        try Data(repeating: 0xA5, count: 16).write(to: dir.appendingPathComponent(CASCStorageWriter.journalName))
    }
    let before = try Data(contentsOf: archive)
    #expect(plan.resumesStorage)
    #expect(!GameUpdatePlan.casc(plan).isEmpty)
    #expect(plan.downloadSize == 0)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IndexRepairOfflineProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var versions = VersionService(session: session)
    versions.retry.delays = []
    let store = InstallStateStore(file: root.appendingPathComponent("state.json"))
    let updater = GameUpdate(install: plan.install, versions: versions, store: store)
    let requestsBefore = IndexRepairOfflineProtocol.requests.count
    // The same dispatch decision as DownloadRequest and waypoint-cli update.
    if GameUpdatePlan.casc(plan).isEmpty {
        try updater.repairIndexes(.casc(plan))
    } else {
        try await updater.apply(.casc(plan))
    }
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent(CASCStorageWriter.journalName).path))
    #expect(plan.isEmpty)
    #expect(try Data(contentsOf: archive) == before)
    if updateJournal { #expect(try StoredKeys.load(dir)?.contains(Key16(storageKey(42))!) == true) }
    let state = try #require(try CASC.scanStorage(dir))
    for bucket in 0..<16 {
        let file = try Data(contentsOf: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: state.versions[bucket])))
        let parsed = try CASC.parseIndexFile(file)
        #expect(file.count == CASC.indexFileSize(sortedEnd: parsed.sortedEnd))
    }
    #expect(store.load()[plan.install.uid]?.buildConfig == plan.target.buildConfig)
    #expect(IndexRepairOfflineProtocol.requests.count == requestsBefore, "Journal recovery must not run cleanup or make network requests")
    #expect(try updater.repairIndexes(.casc(plan)).isEmpty)
}

/// Covers both a crash after publishing a first install's indexes and an
/// unrelated completed installation beside a stale 16-byte journal header.
@Test(arguments: [true, false])
func markerlessJournalsNeverReplaceCompletedStorage(publishedJournal: Bool) throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-stale-journal-\(UUID())")
    defer { try? fm.removeItem(at: dir) }
    let writer = try CASCStorageWriter(directory: dir)
    for i in 0..<3 { try writer.append(encodedKey: storageKey(i), blob: storageBlob(i), fullKey: false) }
    let journal = dir.appendingPathComponent(CASCStorageWriter.journalName)
    let saved = try Data(contentsOf: journal)
    try writer.finish()
    let archive = dir.appendingPathComponent("data.000")
    let before = try Data(contentsOf: archive)
    try (publishedJournal ? saved : Data(repeating: 0xA5, count: 16)).write(to: journal)
    let journalBefore = try Data(contentsOf: journal)
    #expect(throws: TACTError.self) { try CASCStorageWriter(directory: dir) }
    #expect(try Data(contentsOf: journal) == journalBefore)
    #expect(try Data(contentsOf: archive) == before)

    let resumed = try CASCStorageWriter(directory: dir, allowExisting: true)
    for i in 0..<3 { #expect(resumed.contains(storageKey(i))) }
    try resumed.append(encodedKey: storageKey(42), blob: storageBlob(42), fullKey: false)
    try resumed.finish()

    let after = try Data(contentsOf: archive)
    #expect(after.prefix(before.count) == before)
    #expect(after.count == before.count + CASC.headerSize + storageBlob(42).count)
    let stored = try #require(try StoredKeys.load(dir))
    for i in [0, 1, 2, 42] { #expect(stored.contains(Key16(storageKey(i))!)) }
    #expect(!fm.fileExists(atPath: journal.path))
    try expectStoredIndexesOnly(dir, version: 2)
}

/// A journal can appear after a no-download decision; the direct repair
/// must fail visibly rather than claiming success while leaving it untouched.
@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
func journalAppearingAfterPlanningIsReported() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-journal-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("SC2Data/data")
    let (url, before) = try shortIndexStorage(dir, entries: indexEntries(1_819))
    let plan = try indexRepairPlan(at: root)
    #expect(plan.isEmpty)
    try Data(repeating: 0, count: 16).write(to: dir.appendingPathComponent(CASCStorageWriter.journalName))
    // A re-plan can now recover the stale header using the published indexes.
    // The already-chosen direct repair still reports the late journal safely.
    #expect(plan.resumesStorage)
    #expect(!plan.isEmpty)
    do {
        _ = try GameUpdate(install: plan.install, store: InstallStateStore(file: root.appendingPathComponent("state.json")))
            .repairIndexes(.casc(plan))
        Issue.record("An unfinished journal must not silently complete a repair")
    } catch UpdateError.unfinishedStorage(let path) {
        #expect(path == dir.path)
    }
    #expect(try Data(contentsOf: url) == before)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: [0o755, 0o666])
@MainActor func skippedIndexRepairFailsTheJobWithAnActionableMessage(dataMode: Int) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-skipped-index-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("SC2Data/data")
    let (url, before) = try shortIndexStorage(dir, entries: indexEntries(1_819), tail: [0x5C])
    try fm.setAttributes([.posixPermissions: dataMode], ofItemAtPath: dir.path)
    let plan = try indexRepairPlan(at: root)
    let updater = GameUpdate(install: plan.install, store: InstallStateStore(file: root.appendingPathComponent("state.json")))
    let job = DownloadJob(uid: plan.install.uid, category: .gameUpdate) { _ in
        _ = try updater.repairIndexes(.casc(plan))
    }
    let message = UpdateError.indexRepairIncomplete(dir.path, [url.lastPathComponent]).description
    #expect(await job.run() == .failed(message))
    #expect(message.contains("Scan and Repair"))
    #expect(try Data(contentsOf: url) == before)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: [0o755, 0o666])
func anApplyWithAnUnrepairableIndexFailsBeforeWritingBuildData(dataMode: Int) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-index-preflight-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("SC2Data/data")
    let (url, before) = try shortIndexStorage(dir, entries: indexEntries(1_819), tail: [0x5C])
    try fm.setAttributes([.posixPermissions: dataMode], ofItemAtPath: dir.path)
    var plan = try indexRepairPlan(at: root)
    plan.setsLanguages = true // A switch to already-downloaded content still applies.
    #expect(!plan.isEmpty)
    let store = InstallStateStore(file: root.appendingPathComponent("state.json"))
    do {
        try await GameUpdate(install: plan.install, store: store).apply(.casc(plan))
        Issue.record("An apply must report the unrepairable index before its first write")
    } catch UpdateError.indexRepairIncomplete(let path, let files) {
        #expect(path == dir.path)
        #expect(files == [url.lastPathComponent])
    }
    for path in ["SC2Data/config", "SC2Data/indices", ".build.info", ".waypoint-platform", "state.json"] {
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(path).path))
    }
    #expect(try Data(contentsOf: url) == before)
    #expect(store.load().isEmpty)
}

// MARK: - Battle.net detection

@Test func recognizesBattleNetProcesses() {
    #expect(BattleNet.kind(ofExecutable: "/Applications/Battle.net.app/Contents/MacOS/Battle.net") == .app)
    #expect(BattleNet.kind(ofExecutable: "/Users/me/Apps/Battle.net.app/Contents/Frameworks/Battle.net Helper.app/Contents/MacOS/Battle.net Helper") == .app)
    #expect(BattleNet.kind(ofExecutable: "/Users/Shared/Battle.net/Agent/Agent.9824/Agent.app/Contents/MacOS/Agent") == .agent)
    #expect(BattleNet.kind(ofExecutable: "/Users/Shared/Battle.net/Agent/Blizzard Error.app/Contents/MacOS/Blizzard Error") == nil)
    #expect(BattleNet.kind(ofExecutable: "/Applications/Warcraft III/Warcraft III Launcher.app/Contents/MacOS/Warcraft III Launcher") == nil)
    #expect(BattleNet.kind(ofExecutable: "/Applications/Waypoint.app/Contents/MacOS/Waypoint") == nil)
    #expect(BattleNet.kind(ofExecutable: "/usr/libexec/UserEventAgent") == nil)
    // Nothing of Battle.net's runs while the tests do (or this says so).
    #expect(BattleNet.running().isEmpty || (try? BattleNet.ensureNotRunning()) == nil)
}

// MARK: - Cleaning (what no build needs any more)

private func allocated(_ url: URL) -> UInt64 {
    var info = stat()
    return stat(url.path, &info) == 0 ? UInt64(info.st_blocks) * 512 : 0
}

@Test func cleaningRemovesUnneededFilesAndGivesSpaceBack() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    // 40 blobs of ~64 KB: 0..<20 an "old build", 20..<40 the current one,
    // interleaved so the dead ones leave holes and a dead tail.
    func blob(_ i: Int) -> Data { Data(repeating: UInt8(truncatingIfNeeded: i), count: 64 * 1024 + i) }
    let writer = try CASCStorageWriter(directory: dir)
    for i in 0..<40 { try writer.append(encodedKey: storageKey(i), blob: blob(i), fullKey: false) }
    try writer.finish()
    let archive = dir.appendingPathComponent("data.000")
    let sizeBefore = try fm.attributesOfItem(atPath: archive.path)[.size] as! UInt64
    let allocatedBefore = allocated(archive)
    let live = Set((0..<40).filter { $0 % 2 == 0 || $0 >= 30 }.map { storageKey($0).prefix(9) }) // dead: odd ones below 30
    let isLive: (Key9) -> Bool = { live.contains($0.data) }

    let preview = try CASCStorageCleaner.clean(dir, dryRun: true, isLive: isLive)
    #expect(preview.removedFiles == 15 && preview.reclaimedBytes == 0)
    #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".idx") }.allSatisfy { $0.hasSuffix("00000001.idx") })

    let result = try CASCStorageCleaner.clean(dir, isLive: isLive)
    #expect(result.removedFiles == 15)
    #expect(result.removedBytes == (0..<30).filter { $0 % 2 == 1 }.reduce(UInt64(0)) { $0 + 30 + UInt64(blob($1).count) })
    #expect(result.reclaimedBytes >= 15 * 60 * 1024) // the whole 4 KB blocks inside each hole
    #expect(allocated(archive) < allocatedBefore)
    #expect(try fm.attributesOfItem(atPath: archive.path)[.size] as! UInt64 == sizeBefore) // no dead tail: 39 is live

    // The live files read back from the new index (version 2); the rest is gone.
    var found = 0
    for bucket in 0..<16 {
        let names = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(String(format: "%02x", bucket)) && $0.hasSuffix(".idx") }
        #expect(names == [CASC.indexFileName(bucket: bucket, version: 2)])
        for entry in parseIndex(try Data(contentsOf: dir.appendingPathComponent(names[0]))) where entry.size != 30 {
            let i = try #require((0..<40).first { storageKey($0).prefix(9) == entry.key })
            #expect(live.contains(entry.key))
            let handle = try FileHandle(forReadingFrom: archive)
            try handle.seek(toOffset: entry.offset + 30)
            #expect(try handle.read(upToCount: blob(i).count) == blob(i))
            try handle.close()
            found += 1
        }
    }
    #expect(found == 25)
    let shmem = try Data(contentsOf: dir.appendingPathComponent("shmem"))
    #expect(shmem[0x110] == 2)
    let spans = Int(shmem[0x1004]) | Int(shmem[0x1005]) << 8
    #expect(spans == 0x3FF + 15) // data.000's tail and 1,022 unused archives, plus the 15 holes

    // Cleaning again finds nothing; a later update still appends fine.
    #expect(try CASCStorageCleaner.clean(dir, isLive: isLive).removedFiles == 0)
    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: storageKey(100), blob: blob(100), fullKey: false)
    try update.finish()
    #expect(try StoredKeys.load(dir)!.contains(Key16(storageKey(100))!))
}

@Test func cleaningCutsADeadTail() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let writer = try CASCStorageWriter(directory: dir)
    for i in 0..<10 { try writer.append(encodedKey: storageKey(i), blob: Data(repeating: 1, count: 100_000), fullKey: false) }
    try writer.finish()
    let live = Set((0..<4).map { storageKey($0).prefix(9) })
    let result = try CASCStorageCleaner.clean(dir) { live.contains($0.data) }
    #expect(result.removedFiles == 6)
    let size = try fm.attributesOfItem(atPath: dir.appendingPathComponent("data.000").path)[.size] as! UInt64
    #expect(size == UInt64(CASC.segmentHeadersSize + 4 * (30 + 100_000)))
    // New blobs go right after the cut.
    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: storageKey(50), blob: Data(repeating: 2, count: 1000), fullKey: false)
    try update.finish()
    let after = try fm.attributesOfItem(atPath: dir.appendingPathComponent("data.000").path)[.size] as! UInt64
    #expect(after == size + 1030)
}

// MARK: - Archive-group indexes

/// A minimal archive index: 24-byte entries in 4 KB pages, then the TOC and
/// footer fields the group builder reads.
private func archiveIndex(_ entries: [(key: Data, size: UInt32, offset: UInt32)]) -> Data {
    var pages = Data()
    var page = Data()
    for e in entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
        page += e.key + be(UInt64(e.size), 4) + be(UInt64(e.offset), 4)
        if page.count + 24 > 4096 { pages += page + Data(count: 4096 - page.count); page = Data() }
    }
    if !page.isEmpty { pages += page + Data(count: 4096 - page.count) }
    let pageCount = pages.count / 4096
    return pages + Data(count: pageCount * 24) + Data(count: 8) + Data([1, 0, 0, 4, 4, 4, 16, 8])
        + Data(CASC.le32(UInt32(entries.count))) + Data(count: 8)
}

@Test func archiveGroupMergesSortsAndKeepsTheFirstArchive() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-group-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    // Never all zeros: an index reads a zero key as the end of a page.
    func k(_ i: Int) -> Data { Data([0xA5]) + Data((1..<16).map { UInt8(truncatingIfNeeded: i >> (8 * (15 - $0) % 64)) }) }
    // 400 keys over three archives; keys 100..<110 are in archives 0 and 2.
    var lists: [[(key: Data, size: UInt32, offset: UInt32)]] = [[], [], []]
    for i in 0..<400 { lists[i % 3].append((k(i * 7919 % 100_003), UInt32(i), UInt32(i * 10))) }
    for i in 0..<10 { lists[2].append((lists[0][i].key, 999, 999)) }
    let files = try lists.enumerated().map { n, list in
        let url = dir.appendingPathComponent("archive\(n).index")
        try archiveIndex(list).write(to: url)
        return url
    }
    let output = dir.appendingPathComponent("group.bin")
    fm.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    let name = try ArchiveGroup.write(files, to: handle)
    try handle.close()
    let group = try Data(contentsOf: output)
    #expect(Data(Insecure.MD5.hash(data: group.suffix(28))).hex == name)
    let footer = [UInt8](group.suffix(28))
    #expect(Array(footer[8..<16]) == [1, 0, 0, 4, 5, 4, 16, 8]) // 1-byte archive position
    #expect(Array(footer[16..<20]) == CASC.le32(400))

    // Read it back like any index: sorted, one entry per key, the first archive wins.
    var seen: [(Data, UInt64, UInt64)] = []
    try ArchiveIndex.scan(group, archive: "group") { key, _, size, offset in
        seen.append((Data(UnsafeRawBufferPointer(start: key, count: 16)), size, offset))
        return true
    }
    #expect(seen.count == 400)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.0.lexicographicallyPrecedes($1.0) })
    for (n, list) in lists.enumerated() {
        for e in list where e.size != 999 {
            let hit = try #require(seen.first { $0.0 == e.key })
            #expect(hit.1 == UInt64(e.size) && hit.2 == UInt64(n) << 32 | UInt64(e.offset))
        }
    }

    // Built into a folder under the expected name; a wrong name leaves nothing.
    #expect(try ArchiveGroup.build(indexFiles: files, expected: name, in: dir))
    #expect(try Data(contentsOf: dir.appendingPathComponent("\(name).index")) == group)
    #expect(try !ArchiveGroup.build(indexFiles: files, expected: String(repeating: "0", count: 32), in: dir))
    #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".part") || $0.hasPrefix("0000") }.isEmpty)
}

/// Rebuilds Battle.net's own group indexes from a Warcraft III install's
/// archive indexes (read-only) and compares them byte for byte.
/// Run with `WAYPOINT_CASC_REFERENCE=1 xcrun swift test --filter archiveGroupMatches`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAYPOINT_CASC_REFERENCE"] == "1"))
func archiveGroupMatchesAgentBuiltOnes() throws {
    let root = URL(fileURLWithPath: "/Applications/Warcraft III/Data")
    let fm = FileManager.default
    let out = fm.temporaryDirectory.appendingPathComponent("waypoint-group-\(UUID().uuidString)")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: out) }
    var compared = 0
    for prefix in try fm.contentsOfDirectory(atPath: root.appendingPathComponent("config").path) {
        for sub in try fm.contentsOfDirectory(atPath: root.appendingPathComponent("config/\(prefix)").path) {
            for hash in try fm.contentsOfDirectory(atPath: root.appendingPathComponent("config/\(prefix)/\(sub)").path) {
                let config = TACTConfig(try String(contentsOf: root.appendingPathComponent("config/\(prefix)/\(sub)/\(hash)"), encoding: .utf8))
                for (list, group) in [("archives", "archive-group"), ("patch-archives", "patch-archive-group")] {
                    guard let name = config[group].first else { continue }
                    let real = root.appendingPathComponent("indices/\(name).index")
                    let files = config[list].map { root.appendingPathComponent("indices/\($0).index") }
                    guard fm.fileExists(atPath: real.path), files.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { continue }
                    #expect(try ArchiveGroup.build(indexFiles: files, expected: name, in: out), "\(group) \(name)")
                    #expect(try Data(contentsOf: out.appendingPathComponent("\(name).index")) == Data(contentsOf: real), "\(group) \(name)")
                    compared += 1
                }
            }
        }
    }
    #expect(compared >= 2)
}

/// The cleaner's idea of what's live comes from a snapshot taken before
/// minutes of network fetches. Another version's update finishing meanwhile
/// must not lose the files it just added.
@Test func cleaningLeavesAStorageThatChangedSinceItsSnapshot() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let writer = try CASCStorageWriter(directory: dir)
    for i in 0..<4 { try writer.append(encodedKey: storageKey(i), blob: Data(repeating: 1, count: 10_000), fullKey: false) }
    try writer.finish()
    let snapshot = try #require(try StoredKeys.load(dir))
    let live = Set([storageKey(0).prefix(9)])
    let isLive: (Key9) -> Bool = { live.contains($0.data) }

    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: storageKey(100), blob: Data(repeating: 2, count: 10_000), fullKey: false)
    try update.finish()
    #expect(throws: UpdateError.self) { try CASCStorageCleaner.clean(dir, unchangedSince: snapshot, isLive: isLive) }
    #expect(try StoredKeys.load(dir)!.contains(Key16(storageKey(100))!), "the update's file stays")
    #expect(try StoredKeys.load(dir)!.contains(Key16(storageKey(1))!), "nothing is removed")

    // Nor when only .build.info changed (another version recorded a new build).
    let fresh = try #require(try StoredKeys.load(dir))
    #expect(throws: UpdateError.self) { try CASCStorageCleaner.clean(dir, unchangedSince: fresh, isCurrent: { false }, isLive: isLive) }
    #expect(try CASCStorageCleaner.clean(dir, unchangedSince: fresh, isLive: isLive).removedFiles == 4)
}
