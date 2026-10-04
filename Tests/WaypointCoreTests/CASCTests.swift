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
