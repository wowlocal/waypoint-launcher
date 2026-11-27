import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

// Issue #19: the storage shape the game checks before reading anything.

private func temporaryStorage() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-structure-\(UUID().uuidString)")
}

/// A BLTE blob without a chunk table: its encoded key is the MD5 of all of it.
private func blte(_ i: Int) -> (key: Data, blob: Data) {
    let blob = Data("BLTE".utf8) + Data([0, 0, 0, 0]) + Data("N".utf8) + Data(repeating: UInt8(truncatingIfNeeded: i), count: 300 + i)
    return (Data(Insecure.MD5.hash(data: blob)), blob)
}

private func makeStorage(_ dir: URL, files: Range<Int> = 0..<20) throws {
    let writer = try CASCStorageWriter(directory: dir)
    for i in files { try writer.append(encodedKey: blte(i).key, blob: blte(i).blob, fullKey: false) }
    try writer.finish()
}

private func archiveURL(_ dir: URL, _ archive: Int) -> URL { dir.appendingPathComponent(String(format: "data.%03d", archive)) }

/// Publishes the index files' next version with `edit` applied, as the writer does.
private func rewriteIndexes(_ dir: URL, _ edit: (Int, inout [CASC.IndexEntry]) -> Void) throws {
    let state = try #require(try CASC.scanStorage(dir))
    for bucket in 0..<16 {
        var entries = try CASC.loadBucket(dir, bucket: bucket, version: state.versions[bucket])
        edit(bucket, &entries)
        try CASC.indexFile(bucket: bucket, entries: entries)
            .write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: state.versions[bucket] + 1)))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: state.versions[bucket])))
    }
}

/// A second archive holding only its 16 headers, indexed: what the base key
/// can be recovered from when the first one's are gone.
private func addArchive(_ dir: URL) throws {
    let state = try #require(try CASC.scanStorage(dir))
    let base = try #require(state.baseKey)
    let headers = CASC.segmentHeaders(baseKey: base, archive: state.archiveSizes.count)
    try headers.data.write(to: archiveURL(dir, state.archiveSizes.count))
    try rewriteIndexes(dir) { bucket, entries in entries += headers.entries.filter { $0.bucket == bucket }.map(\.entry) }
    // shmem as a writer would leave it: the new archive's headers aren't free.
    let after = try #require(try CASC.scanStorage(dir))
    try #require(CASC.shmem(storagePath: dir.path, indexVersions: after.versions, archiveSizes: after.archiveSizes))
        .write(to: dir.appendingPathComponent("shmem"))
}

private func blank(_ dir: URL, archive: Int, bytes: Int = CASC.segmentHeadersSize) throws {
    let handle = try FileHandle(forWritingTo: archiveURL(dir, archive))
    try handle.write(contentsOf: Data(count: bytes))
    try handle.close()
}

private func entries(_ dir: URL) throws -> [CASC.IndexEntry] {
    let state = try #require(try CASC.scanStorage(dir))
    return try (0..<16).flatMap { try CASC.loadBucket(dir, bucket: $0, version: state.versions[$0]) }
}

@Test func writtenStorageIsStructurallySound() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    let report = try CASC.inspectStructure(dir, checkOverlaps: true)
    #expect(report.isEmpty)
    #expect(try CASC.repairStructure(dir).isEmpty)
}

@Test(arguments: [false, true])
func blankHeadersAreRebuiltFromAnIntactArchive(alsoUnindexed: Bool) throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    let base = try #require(try CASC.scanStorage(dir)?.baseKey)
    let original = try Data(contentsOf: archiveURL(dir, 0)).prefix(CASC.segmentHeadersSize)
    #expect(original == CASC.segmentHeaders(baseKey: base, archive: 0).data)
    let filesBefore = try entries(dir).filter { !CASC.isHeaderSlotEntry($0) }.count

    // What cleaning did to the reporter's archive 0: header bytes zeroed,
    // and (the other variant) their index entries gone too.
    try blank(dir, archive: 0)
    if alsoUnindexed { try rewriteIndexes(dir) { _, entries in entries.removeAll { $0.archive == 0 && CASC.isHeaderSlotEntry($0) } } }
    let report = try CASC.inspectStructure(dir, checkOverlaps: false)
    #expect(report.isDamaged)
    #expect(report.blankHeaderSlots == [0: Array(0..<16)])
    #expect(report.unindexedHeaderSlots == (alsoUnindexed ? [0: Array(0..<16)] : [:]))
    #expect(!report.baseKeyUnknown)

    // An update stops rather than writing on top of it.
    #expect(throws: UpdateError.self) { try CASCStorageWriter(directory: dir, allowExisting: true) }

    let repair = try CASC.repairStructure(dir)
    #expect(repair.rebuiltHeaderSlots == 16)
    #expect(repair.indexedHeaderSlots == (alsoUnindexed ? 16 : 0))
    #expect(repair.droppedEntries == 0)
    #expect(repair.after.isEmpty)
    #expect(try Data(contentsOf: archiveURL(dir, 0)).prefix(CASC.segmentHeadersSize) == original)
    #expect(try entries(dir).filter { !CASC.isHeaderSlotEntry($0) }.count == filesBefore)
    #expect(try CASC.repairStructure(dir).isEmpty, "a second run changes nothing")

    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: blte(99).key, blob: blte(99).blob, fullKey: false)
    try update.finish()
    #expect(try CASC.inspectStructure(dir, checkOverlaps: true).isEmpty)
}

@Test func headersAreNotGuessedWithoutAnIntactArchive() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try blank(dir, archive: 0)
    let before = try Data(contentsOf: archiveURL(dir, 0))
    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.baseKeyUnknown)
    #expect(repair.rebuiltHeaderSlots == 0)
    #expect(repair.after.isDamaged)
    #expect(try Data(contentsOf: archiveURL(dir, 0)) == before)
}

@Test func anEntryPastTheArchiveEndBlocksUpdatesUntilDropped() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let size = UInt64(try Data(contentsOf: archiveURL(dir, 0)).count)
    // mbp-128: the index still pointed past where the archive now ended.
    let stale = CASC.IndexEntry(key: Data(repeating: 0xAB, count: 9), archive: 0, offset: size - 10, size: 100)
    try rewriteIndexes(dir) { bucket, entries in if bucket == CASC.bucket(of: stale.key) { entries.append(stale) } }
    let archiveBefore = try Data(contentsOf: archiveURL(dir, 0))

    let report = try CASC.inspectStructure(dir, checkOverlaps: false)
    #expect(report.outOfBounds == [stale])
    #expect(throws: UpdateError.self) { try CASCStorageWriter(directory: dir, allowExisting: true) }
    #expect(try Data(contentsOf: archiveURL(dir, 0)) == archiveBefore, "nothing was written")

    let repair = try CASC.repairStructure(dir)
    #expect(repair.droppedEntries == 1)
    #expect(repair.after.isEmpty)
    #expect(try Data(contentsOf: archiveURL(dir, 0)) == archiveBefore, "repair never touches archive data")
    #expect(!(try entries(dir)).contains(stale))
    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    #expect(update.contains(blte(3).key))
    try update.finish()
}

@Test func aFileWrittenOverOthersKeepsOnlyTheOneReallyThere() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let genuine = try #require(try entries(dir).first { $0.key == blte(10).key.prefix(9) })
    // Two stale entries inside it, as on mbp-128 where a new 141 MB file
    // landed where the index still listed two older ones.
    let stale = [CASC.IndexEntry(key: Data(repeating: 0xC1, count: 9), archive: 0, offset: genuine.offset + 40, size: 60),
                 CASC.IndexEntry(key: Data(repeating: 0xC2, count: 9), archive: 0, offset: genuine.offset + 80, size: 90)]
    try rewriteIndexes(dir) { bucket, entries in entries += stale.filter { CASC.bucket(of: $0.key) == bucket } }

    let report = try CASC.inspectStructure(dir, checkOverlaps: true)
    #expect(Set(report.displaced.map(\.key)) == Set(stale.map(\.key)))
    #expect(report.ambiguousOverlaps == 0)
    #expect(report.isDamaged)

    let repair = try CASC.repairStructure(dir)
    #expect(repair.droppedEntries == 2)
    #expect(repair.after.isEmpty)
    let after = try entries(dir)
    #expect(after.contains(genuine))
    #expect(!after.contains { stale.map(\.key).contains($0.key) })
}

@Test func overlapsNoFileOwnsAreLeftAlone() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    // Bytes no entry authenticates, with two entries overlapping over them.
    let handle = try FileHandle(forWritingTo: archiveURL(dir, 0))
    let end = try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x5A, count: 1000))
    try handle.close()
    let overlapping = [CASC.IndexEntry(key: Data(repeating: 0xD1, count: 9), archive: 0, offset: end, size: 400),
                       CASC.IndexEntry(key: Data(repeating: 0xD2, count: 9), archive: 0, offset: end + 200, size: 400)]
    try rewriteIndexes(dir) { bucket, entries in entries += overlapping.filter { CASC.bucket(of: $0.key) == bucket } }

    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.ambiguousOverlaps == 1)
    #expect(repair.droppedEntries == 0)
    #expect(repair.after.isDamaged)
    #expect(Set(try entries(dir).map(\.key)).isSuperset(of: overlapping.map(\.key)))
}

@Test func reclaimingSpaceIsSuspended() throws {
    // Issue #19: cleaning freed bytes the index didn't cover and destroyed
    // other files' data. It stays off until it frees only what it removed,
    // even when the cleaner is called directly.
    #expect(!CASCStorageCleaner.reclaimsSpace)
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    func snapshot() throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().map {
            ($0, try Data(contentsOf: dir.appendingPathComponent($0)))
        })
    }
    let before = try snapshot()
    let counted = try CASCStorageCleaner.clean(dir, dryRun: true) { _ in false }
    #expect(counted.removedFiles == 20, "counting still works")
    #expect(try CASCStorageCleaner.clean(dir) { _ in false } == CASCStorageCleaner.Result())
    #expect(try snapshot() == before)
}

@Test func onlyEntriesDirectlyOverAnAuthenticFileAreDropped() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let all = try entries(dir).filter { !CASC.isHeaderSlotEntry($0) }.sorted { $0.offset < $1.offset }
    // B overlaps the last genuine file's end; C overlaps only B, over bytes
    // past every file, where nothing authenticates. Dropping B is proven;
    // C never touched a genuine file, so it must stay.
    let handle = try FileHandle(forWritingTo: archiveURL(dir, 0))
    let end = try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x33, count: 2000))
    try handle.close()
    let last = all.last!
    let b = CASC.IndexEntry(key: Data(repeating: 0xB1, count: 9), archive: 0, offset: last.offset + UInt64(last.size) - 20, size: 400)
    let c = CASC.IndexEntry(key: Data(repeating: 0xC1, count: 9), archive: 0, offset: b.offset + 300, size: 400)
    #expect(c.offset > last.offset + UInt64(last.size) && c.offset + UInt64(c.size) <= end + 2000)
    try rewriteIndexes(dir) { bucket, entries in entries += [b, c].filter { CASC.bucket(of: $0.key) == bucket } }

    let report = try CASC.inspectStructure(dir, checkOverlaps: true)
    #expect(report.displaced.map(\.key) == [b.key])
    let repair = try CASC.repairStructure(dir)
    #expect(repair.droppedEntries == 1)
    let after = try entries(dir)
    #expect(after.contains(c), "C never touched an authentic file")
    #expect(after.contains(last))
    #expect(!repair.after.isDamaged, "with B gone, C overlaps nothing")
}

@Test func aChunkedFileDoesNotAuthenticateBeyondItsChunks() throws {
    // BLTE with a chunk table: the key is the header's MD5, and the chunks
    // must account for every byte the entry claims.
    let chunk = Data("Ztwelve bytes".utf8)
    var header = Data("BLTE".utf8) + Data([0, 0, 0, 36]) + Data([0x0F, 0, 0, 1])
    header += Data([0, 0, 0, UInt8(chunk.count)]) + Data([0, 0, 0, 11]) + Data(Insecure.MD5.hash(data: chunk))
    let blob = header + chunk
    let key = Data(Insecure.MD5.hash(data: header)).prefix(9)
    #expect(CASC.authenticates(blob, key9: key))
    #expect(!CASC.authenticates(blob + Data(count: 50), key9: key), "an inflated size claims bytes that aren't its own")
    var corrupt = blob
    corrupt[corrupt.count - 1] ^= 1
    #expect(!CASC.authenticates(corrupt, key9: key))
    #expect(!CASC.authenticates(blob, key9: Data(repeating: 1, count: 9)))
}

@Test func aHeaderWithSurvivingBytesOfSomethingElseIsLeftAlone() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    // Slot 3 of archive 0 holds other bytes, not zeros or the expected header.
    let handle = try FileHandle(forWritingTo: archiveURL(dir, 0))
    try handle.seek(toOffset: UInt64(3 * CASC.headerSize))
    try handle.write(contentsOf: Data(repeating: 0x77, count: 10))
    try handle.close()
    let before = try Data(contentsOf: archiveURL(dir, 0))
    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.foreignHeaderSlots == [0: [3]])
    #expect(!repair.before.isDamaged)
    #expect(repair.rebuiltHeaderSlots == 0)
    #expect(try Data(contentsOf: archiveURL(dir, 0)) == before)
}

@Test func aPublicationCutShortIsFinished() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let shmemBefore = try Data(contentsOf: dir.appendingPathComponent("shmem"))
    #expect(CASC.shmemIndexVersions(dir) == Array(repeating: 1, count: 16))
    // All 16 next index files written, then a crash before shmem.
    let state = try #require(try CASC.scanStorage(dir))
    for bucket in 0..<16 {
        try CASC.indexFile(bucket: bucket, entries: try CASC.loadBucket(dir, bucket: bucket, version: 1))
            .write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: state.versions[bucket] + 1)))
    }
    let repair = try CASC.repairStructure(dir)
    #expect(repair.republishedShmem)
    #expect(CASC.shmemIndexVersions(dir) == Array(repeating: 2, count: 16))
    #expect(try Data(contentsOf: dir.appendingPathComponent("shmem")) != shmemBefore)
    #expect(try CASC.repairStructure(dir).isEmpty)

    // Any other mismatch (here: a stray newer file for one bucket) stays as is.
    try CASC.indexFile(bucket: 4, entries: try CASC.loadBucket(dir, bucket: 4, version: 2))
        .write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: 4, version: 9)))
    #expect(!(try CASC.repairStructure(dir)).republishedShmem)
    #expect(CASC.shmemIndexVersions(dir) == Array(repeating: 2, count: 16))
}

@Test func fourDigitArchivesAreArchives() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try Data(count: 10).write(to: dir.appendingPathComponent("data.1000"))
    #expect(try CASC.scanStorage(dir)?.archiveSizes.count == 1001)
}

@Test func anOverlapElsewhereDoesNotStopUpdatesButVerifyReportsIt() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let handle = try FileHandle(forWritingTo: archiveURL(dir, 0))
    let end = try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x5A, count: 1000))
    try handle.close()
    let overlapping = [CASC.IndexEntry(key: Data(repeating: 0xE1, count: 9), archive: 0, offset: end, size: 400),
                       CASC.IndexEntry(key: Data(repeating: 0xE2, count: 9), archive: 0, offset: end + 200, size: 400)]
    try rewriteIndexes(dir) { bucket, entries in entries += overlapping.filter { CASC.bucket(of: $0.key) == bucket } }

    // Appending can't make it worse: the update goes ahead.
    let update = try CASCStorageWriter(directory: dir, allowExisting: true)
    try update.append(encodedKey: blte(50).key, blob: blte(50).blob, fullKey: false)
    try update.finish()
    // Verify Files reports what it can't settle, and changes nothing.
    #expect(throws: UpdateError.self) { try CASCStorageWriter(directory: dir, allowExisting: true, verifying: []) }
    #expect(Set(try entries(dir).map(\.key)).isSuperset(of: overlapping.map(\.key)))
}

@Test func verifyingRepairsBeforeItWrites() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    let original = try Data(contentsOf: archiveURL(dir, 0)).prefix(CASC.segmentHeadersSize)
    try blank(dir, archive: 0)
    // The writer Verify Files uses holds the lock and repairs under it.
    let verify = try CASCStorageWriter(directory: dir, allowExisting: true, verifying: [])
    try verify.finish()
    #expect(try Data(contentsOf: archiveURL(dir, 0)).prefix(CASC.segmentHeadersSize) == original)
    #expect(try CASC.inspectStructure(dir, checkOverlaps: true).isEmpty)
}

@Test func aBlankHeaderIndexedUnderAnotherKeyIsLeftAlone() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    try blank(dir, archive: 0)
    // Slot 2's index entry names some other key.
    try rewriteIndexes(dir) { _, entries in
        for i in entries.indices where entries[i].archive == 0 && entries[i].offset == UInt64(2 * CASC.headerSize) && CASC.isHeaderSlotEntry(entries[i]) {
            entries[i].key = Data(repeating: 0x42, count: 9)
        }
    }
    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.conflictedHeaderSlots[0]?.contains(2) == true)
    #expect(repair.rebuiltHeaderSlots == 15)
    #expect(repair.indexedHeaderSlots == 0)
    #expect(repair.after.blankHeaderSlots == [0: [2]], "left for something that knows what belongs there")
    #expect(try Data(contentsOf: archiveURL(dir, 0))[2 * CASC.headerSize..<3 * CASC.headerSize].allSatisfy { $0 == 0 })
}

@Test func theBaseKeyMostIntactArchivesShareWins() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    try addArchive(dir)
    let base = try #require(try CASC.corroboratedBaseKey(dir, archives: 3))
    // One more archive, self-consistent but from padded keys (as
    // restoreMissingArchiveHeaders writes): outvoted, not a tie-breaker.
    var padded = base
    for i in 9..<16 { padded[i] = 0 }
    try CASC.segmentHeaders(baseKey: padded, archive: 3).data.write(to: archiveURL(dir, 3))
    #expect(try CASC.corroboratedBaseKey(dir, archives: 4)?.dropFirst(3) == base.dropFirst(3))
    // Half isn't more than half: archives 0 and 1 against 2 and 3.
    try FileManager.default.removeItem(at: archiveURL(dir, 2))
    try CASC.segmentHeaders(baseKey: padded, archive: 2).data.write(to: archiveURL(dir, 2))
    #expect(try CASC.corroboratedBaseKey(dir, archives: 4) == nil)
    // Nor is a tie between two archives once the others are gone.
    try blank(dir, archive: 1)
    try blank(dir, archive: 2)
    #expect(try CASC.corroboratedBaseKey(dir, archives: 4) == nil)
}

@Test func blteVerifiesAgainstTheNineBytesAnIndexKeeps() throws {
    let (key, blob) = blte(7)
    try BLTE.verify(blob, encodedKey: key)
    try BLTE.verify(blob, encodedKey: key.prefix(9))
    #expect(throws: (any Error).self) { try BLTE.verify(blob, encodedKey: key.prefix(8)) }
    #expect(throws: (any Error).self) { try BLTE.verify(blob, encodedKey: Data(repeating: 1, count: 9)) }
}

@Test func aRepairCutShortAfterOneBucketIsFinished() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let size = UInt64(try Data(contentsOf: archiveURL(dir, 0)).count)
    let stale = CASC.IndexEntry(key: Data(repeating: 0xAB, count: 9), archive: 0, offset: size - 10, size: 100)
    let bucket = CASC.bucket(of: stale.key)
    // Published the way the writer does, shmem included: versions 2.
    try rewriteIndexes(dir) { b, entries in if b == bucket { entries.append(stale) } }
    let state = try #require(try CASC.scanStorage(dir))
    try #require(CASC.shmem(storagePath: dir.path, indexVersions: state.versions, archiveSizes: state.archiveSizes))
        .write(to: dir.appendingPathComponent("shmem"))
    // A repair wrote only the bucket holding the bad entry, then stopped.
    try CASC.indexFile(bucket: bucket, entries: try CASC.loadBucket(dir, bucket: bucket, version: 2).filter { $0 != stale })
        .write(to: dir.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 3)))

    let repair = try CASC.repairStructure(dir)
    #expect(repair.republishedShmem)
    let named = try #require(CASC.shmemIndexVersions(dir))
    #expect(named[bucket] == 3, "the game reads the repaired bucket")
    #expect((0..<16).filter { $0 != bucket }.allSatisfy { named[$0] == 2 })
    #expect(!repair.after.isDamaged)
}

@Test func aHeaderIndexedInTheWrongBucketDoesNotCount() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    // Slot 0 of archive 1, moved from bucket 0 to bucket 5.
    let state = try #require(try CASC.scanStorage(dir))
    let slot0 = CASC.segmentHeaders(baseKey: try #require(state.baseKey), archive: 1).entries[0]
    try rewriteIndexes(dir) { bucket, entries in
        if bucket == slot0.bucket { entries.removeAll { $0 == slot0.entry } }
        if bucket == 5 { entries.append(slot0.entry) }
    }
    let report = try CASC.inspectStructure(dir, checkOverlaps: false)
    #expect(report.unindexedHeaderSlots[1] == [0])
    #expect(report.foreignHeaderEntries == 1)
    #expect(report.conflictedHeaderSlots[1] == [0], "not re-added beside an entry that disagrees")
}

@Test func aResumedDownloadFinishesAndVerifyThenSettlesWhatItCovered() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let size = UInt64(try Data(contentsOf: archiveURL(dir, 0)).count)
    autoreleasepool {
        let paused = try? CASCStorageWriter(directory: dir, allowExisting: true)
        try? paused?.append(encodedKey: blte(60).key, blob: blte(60).blob, fullKey: false)
    }
    // An entry with no bytes, listed where the paused download carries on.
    let stale = CASC.IndexEntry(key: Data(repeating: 0xAC, count: 9), archive: 0, offset: size + 30, size: 100)
    try rewriteIndexes(dir) { bucket, entries in if bucket == CASC.bucket(of: stale.key) { entries.append(stale) } }
    // Resuming isn't stranded (repair can't run while its journal is open)…
    let resumed = try CASCStorageWriter(directory: dir, allowExisting: true)
    for i in 61..<64 { try resumed.append(encodedKey: blte(i).key, blob: blte(i).blob, fullKey: false) }
    try resumed.finish()
    // …and what it wrote over the stale entry is settled by which file checks out.
    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.displaced == [stale] || repair.before.outOfBounds == [stale])
    #expect(repair.after.isEmpty)
    #expect(try CASCStorageWriter(directory: dir, allowExisting: true).contains(blte(62).key))
}

private func freeSpans(_ dir: URL) throws -> [(archive: Int, offset: UInt64, size: UInt64)] {
    let d = [UInt8](try Data(contentsOf: dir.appendingPathComponent("shmem")))
    func be40(_ at: Int) -> UInt64 { (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(d[at + $1]) } }
    let count = Int(d[0x1004]) | Int(d[0x1005]) << 8
    return (0..<count).map { i in
        let offset = be40(0x1020 + 5 * CASC.freeSpanCapacity + 5 * i)
        return (Int(offset >> 30), offset & 0x3FFF_FFFF, be40(0x1020 + 5 * i))
    }
}

@Test func rebuiltHeadersAreNeverListedAsFreeSpace() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    // Archive 1 emptied, its headers still indexed: shmem must not offer them.
    try Data().write(to: archiveURL(dir, 1))
    let repair = try CASC.repairStructure(dir)
    #expect(repair.rebuiltHeaderSlots == 16)
    #expect(try Data(contentsOf: archiveURL(dir, 1)).count == CASC.segmentHeadersSize)
    let spans = try freeSpans(dir).filter { $0.archive == 1 }
    #expect(!spans.isEmpty && spans.allSatisfy { $0.offset >= UInt64(CASC.segmentHeadersSize) })
}

@Test func aBlankSlotIsRebuiltWithItsArchivesOwnKey() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    try addArchive(dir)
    // Archive 3 from another session (its own key), with slot 7 zeroed.
    var other = Data(repeating: 0x5C, count: 16)
    other[3] = 0x77
    let headers = CASC.segmentHeaders(baseKey: other, archive: 3)
    var bytes = headers.data
    bytes.replaceSubrange(7 * CASC.headerSize..<8 * CASC.headerSize, with: Data(count: CASC.headerSize))
    try bytes.write(to: archiveURL(dir, 3))
    try rewriteIndexes(dir) { bucket, entries in entries += headers.entries.filter { $0.bucket == bucket }.map(\.entry) }

    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.blankHeaderSlots == [3: [7]])
    #expect(repair.rebuiltHeaderSlots == 1)
    #expect(try Data(contentsOf: archiveURL(dir, 3)) == headers.data, "its own key, not the majority's")
    #expect(repair.after.isEmpty)
}

/// The reporter's storage: bucket 12 lost its entries, so slot 12's header
/// went unlisted in every archive ("Missing segment header for archive '0'"),
/// and archives written in another session have their own base key.
@Test func headersMissingFromTheIndexAreListedAgainEachWithItsOwnKey() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    var other = Data(repeating: 0x5C, count: 16)
    other[3] = 0x77
    let headers = CASC.segmentHeaders(baseKey: other, archive: 2)
    try headers.data.write(to: archiveURL(dir, 2))
    try rewriteIndexes(dir) { bucket, entries in
        entries += headers.entries.filter { $0.bucket == bucket }.map(\.entry)
        if bucket == 12 { entries.removeAll { CASC.isHeaderSlotEntry($0) } }
    }
    let report = try CASC.inspectStructure(dir, checkOverlaps: true)
    #expect(report.unindexedHeaderSlots == [0: [12], 1: [12], 2: [12]])
    #expect(report.foreignHeaderSlots.isEmpty, "archive 2 is judged by its own key")
    #expect(report.isDamaged)
    #expect(!report.blocksWriting, "appending doesn't make it worse")

    let repair = try CASC.repairStructure(dir)
    #expect(repair.indexedHeaderSlots == 3)
    #expect(repair.after.isEmpty)
    #expect(try entries(dir).contains(headers.entries[12].entry), "archive 2's slot 12 under its own key")
}

/// Also the reporter's: the same key listed twice, at its header and again
/// one header further on, both ending where the file ends.
@Test func aCopyListedOneHeaderTooFarIsDropped() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let genuine = try #require(try entries(dir).first { $0.key == blte(4).key.prefix(9) })
    let shifted = CASC.IndexEntry(key: genuine.key, archive: 0, offset: genuine.offset + UInt64(CASC.headerSize),
                                  size: genuine.size - UInt32(CASC.headerSize))
    try rewriteIndexes(dir) { bucket, entries in if bucket == CASC.bucket(of: genuine.key) { entries.append(shifted) } }

    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.displaced == [shifted])
    #expect(repair.droppedEntries == 1)
    #expect(repair.after.isEmpty)
    let after = try entries(dir)
    #expect(after.contains(genuine) && !after.contains(shifted))
}

@Test func anArchiveWhoseOwnHeadersDisagreeIsLeftAlone() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    try addArchive(dir)
    var other = Data(repeating: 0x5C, count: 16)
    other[3] = 0x77
    let headers = CASC.segmentHeaders(baseKey: other, archive: 3)
    var bytes = headers.data
    bytes.replaceSubrange(7 * CASC.headerSize..<8 * CASC.headerSize, with: Data(count: CASC.headerSize))   // blank
    bytes[9 * CASC.headerSize + 3] ^= 0xFF                                                               // malformed
    try bytes.write(to: archiveURL(dir, 3))
    try rewriteIndexes(dir) { bucket, entries in
        entries += headers.entries.filter { $0.bucket == bucket && $0.entry.offset != UInt64(7 * CASC.headerSize) }.map(\.entry)
    }
    let repair = try CASC.repairStructure(dir)
    #expect(repair.rebuiltHeaderSlots == 0, "no majority key written into an archive that proves another")
    #expect(repair.indexedHeaderSlots == 0)
    #expect(try Data(contentsOf: archiveURL(dir, 3)) == bytes)
    #expect(repair.after.isDamaged)
}

@Test func anotherKeyListedOverAFileThatChecksOutIsDropped() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let genuine = try #require(try entries(dir).first { $0.key == blte(8).key.prefix(9) })
    let stale = CASC.IndexEntry(key: Data(repeating: 0xBE, count: 9), archive: 0, offset: genuine.offset, size: genuine.size)
    try rewriteIndexes(dir) { bucket, entries in if bucket == CASC.bucket(of: stale.key) { entries.append(stale) } }
    let repair = try CASC.repairStructure(dir)
    #expect(repair.before.displaced == [stale])
    #expect(repair.after.isEmpty)
    #expect(try entries(dir).contains(genuine))
}

@Test func restoringAMissingArchiveNeverReplacesSurvivingBytes() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    let partial = Data((try Data(contentsOf: archiveURL(dir, 1))).prefix(100))
    try partial.write(to: archiveURL(dir, 1))
    try CASC.restoreMissingArchiveHeaders(dir)
    #expect(try Data(contentsOf: archiveURL(dir, 1)) == partial)
}

@Test func freeSpaceOverHeadersIsWithdrawn() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    try addArchive(dir)
    // A repair gave archive 1 its headers and stopped before shmem: shmem
    // still has the archive empty, free from offset 0.
    let state = try #require(try CASC.scanStorage(dir))
    var sizes = state.archiveSizes
    sizes[1] = 0
    try #require(CASC.shmem(storagePath: dir.path, indexVersions: state.versions, archiveSizes: sizes))
        .write(to: dir.appendingPathComponent("shmem"))
    #expect(try freeSpans(dir).contains { $0.archive == 1 && $0.offset == 0 })
    let repair = try CASC.repairStructure(dir)
    #expect(repair.republishedShmem)
    #expect(try freeSpans(dir).filter { $0.archive == 1 }.allSatisfy { $0.offset >= UInt64(CASC.segmentHeadersSize) })
}

@Test func verifyingReportsHowFarItHasRead() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir, files: 0..<5000)
    let items = (0..<5000).map { StorageItem(key: Key16(blte($0).key)!, size: UInt64(blte($0).blob.count), fullKey: false) }
        .sorted { $0.key < $1.key }
    var reports: [UInt64] = []
    let valid = try CASC.verifiedStorage(dir, items: items) { reports.append($0) }
    #expect(valid.allSatisfy { $0 })
    #expect(reports.count > 1, "progress along the way, not only at the end")
    #expect(reports == reports.sorted())
    let total = try entries(dir).filter { !CASC.isHeaderSlotEntry($0) }.reduce(UInt64(0)) { $0 + UInt64($1.size) }
    #expect(reports.last == total)
}

@Test func savedProgressFromOlderVersionsStillLoads() throws {
    let old = Data(#"{"completedBytes":5,"totalBytes":10,"completedFiles":1,"totalFiles":2}"#.utf8)
    let progress = try JSONDecoder().decode(UpdateProgress.self, from: old)
    #expect(progress.stage == nil && !progress.isChecking && progress.fraction == 0.5)
    let checking = UpdateProgress(completedBytes: 1, totalBytes: 4, completedFiles: 0, totalFiles: 9, stage: .checking)
    #expect(try JSONDecoder().decode(UpdateProgress.self, from: JSONEncoder().encode(checking)) == checking)
}

/// The reporter's storage also lists two different keys as empty entries
/// at archive 0, offset 0 (as Battle.net writes them): no bytes, no overlap.
@Test func emptyEntriesOverlapNothing() throws {
    let dir = temporaryStorage()
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeStorage(dir)
    let inside = try #require(try entries(dir).first { $0.key == blte(6).key.prefix(9) })
    let empty = [CASC.IndexEntry(key: Data(hex: "53cdbd51d46de07e35")!, archive: 0, offset: 0, size: 0),
                 CASC.IndexEntry(key: Data(hex: "20f336185a8bbdb56d")!, archive: 0, offset: 0, size: 0),
                 CASC.IndexEntry(key: Data(repeating: 0xE0, count: 9), archive: 0, offset: inside.offset + 40, size: 0)]
    try rewriteIndexes(dir) { bucket, entries in entries += empty.filter { CASC.bucket(of: $0.key) == bucket } }
    let report = try CASC.inspectStructure(dir, checkOverlaps: true)
    #expect(report.ambiguousOverlaps == 0)
    #expect(report.isEmpty)
    #expect(try CASC.repairStructure(dir).isEmpty, "left exactly as they are")
}
