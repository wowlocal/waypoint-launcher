import Foundation

/// Local CASC storage (`<root>/Data/data`): the archive store most Blizzard
/// games read their data from. Written the way the Battle.net Agent writes
/// it. Every layout and checksum here was checked byte-for-byte against an
/// Agent-written install (Warcraft III): 48 `.idx` files, 35 archive heads
/// and `shmem`.
///
///   data.###      archives of [30-byte header][BLTE blob verbatim from the CDN],
///                 at most 1 GiB each, starting with 16 segment headers
///   XXYYYYYYYY.idx  16 index files (bucket XX, version YYYYYYYY):
///                 9-byte key → archive/offset/size, sorted, lookup3-checked
///   shmem         free-space table and index versions
public enum CASC {
    static let offsetBits = 30
    static let archiveSize: UInt64 = 1 << 30
    static let maxArchives = 0x3FF
    static let headerSize = 30
    static let segmentHeadersSize = 16 * 30
    static let freeSpanCapacity = 1090
    static let checksumSeedA: UInt32 = 0x3D6BE971
    static let checksumTable: [UInt32] = [
        0x049396B8, 0x72A82A9B, 0xEE626CCA, 0x9917754F, 0x15DE40B1, 0xF5A8A9B6, 0x421EAC7E, 0xA9D55C9A,
        0x317FD40C, 0x04FAF80D, 0x3D6BE971, 0x52933CFD, 0x27F64B7D, 0xC6F5C11B, 0xD5757E3A, 0x6C388745,
    ]

    public struct IndexEntry: Sendable, Equatable {
        public var key: Data         // first 9 bytes of the encoded key
        public var archive: Int
        public var offset: UInt64
        public var size: UInt32      // header + blob

        var storageOffset: UInt64 { UInt64(archive) << UInt64(offsetBits) | offset }
    }

    /// Which of the 16 index files a key goes in.
    public static func bucket(of key: Data, seed: UInt8 = 0) -> Int {
        var x: UInt8 = 0
        for byte in key.prefix(9) { x ^= byte }
        return Int(((x >> 4) ^ x) &+ seed) & 0x0F
    }

    /// The 30-byte header in front of each blob: the reversed key (all 16
    /// bytes for build-config files, else 9 plus zeros), size including the
    /// header, flags, and two checksums tied to the blob's position.
    public static func entryHeader(encodedKey: Data, blobSize: Int, archive: Int, offset: UInt64,
                                   flags: UInt16 = 0, fullKey: Bool) -> Data {
        var key = [UInt8](encodedKey.prefix(16))
        if !fullKey { for i in 9..<16 { key[i] = 0 } }
        var h = [UInt8](repeating: 0, count: headerSize)
        for i in 0..<16 { h[i] = key[15 - i] }
        put32LE(&h, 0x10, UInt32(blobSize + headerSize))
        h[0x14] = UInt8(flags & 0xFF)
        h[0x15] = UInt8(flags >> 8)
        put32LE(&h, 0x16, Lookup3.hashlittle(Array(h[0..<0x16]), checksumSeedA))

        let p = UInt32(truncatingIfNeeded: UInt64(archive) << UInt64(offsetBits) | offset)
        let x = p &+ 0x1E
        let encoded = checksumTable[Int(x & 0xF)] ^ x
        let e = [UInt8(encoded & 0xFF), UInt8(encoded >> 8 & 0xFF), UInt8(encoded >> 16 & 0xFF), UInt8(encoded >> 24)]
        var folded = [UInt8](repeating: 0, count: 4)
        for i in 0..<0x1A { folded[i & 3] ^= h[i] }
        for j in 0..<4 {
            let i = 0x1A + j
            h[i] = folded[i & 3] ^ e[Int((p &+ UInt32(i)) & 3)]
        }
        return Data(h)
    }

    /// The 16 headers every archive starts with, and their index entries
    /// (header i is indexed in bucket i).
    static func segmentHeaders(baseKey: Data, archive: Int) -> (data: Data, entries: [(bucket: Int, entry: IndexEntry)]) {
        var out = Data()
        var entries: [(Int, IndexEntry)] = []
        for bucket in 0..<16 {
            var key = [UInt8](baseKey.prefix(16))
            key[1] = UInt8(archive & 0xFF)
            key[2] = UInt8(archive >> 8 & 0xFF)
            key[0] = (0...255).first { probe in
                key[0] = UInt8(probe)
                return CASC.bucket(of: Data(key), seed: 1) == bucket
            }.map(UInt8.init)!
            out += entryHeader(encodedKey: Data(key), blobSize: 0, archive: archive, offset: UInt64(bucket * headerSize),
                               flags: 1, fullKey: true)
            entries.append((bucket, IndexEntry(key: Data(key.prefix(9)), archive: archive, offset: UInt64(bucket * headerSize),
                                               size: UInt32(headerSize))))
        }
        return (out, entries)
    }

    /// One `.idx` file (version 7).
    public static func indexFile(bucket: Int, entries: [IndexEntry]) -> Data {
        var header: [UInt8] = []
        header += le16(7)
        header += [UInt8(bucket), 0, 4, 5, 9, UInt8(offsetBits)]
        header += le64(UInt64(maxArchives) << UInt64(offsetBits))
        var out: [UInt8] = le32(UInt32(header.count)) + le32(Lookup3.hashlittle(header, 0)) + header
        out += [UInt8](repeating: 0, count: (16 - out.count % 16) % 16)

        let sorted = entries.sorted { a, b in
            a.key.lexicographicallyPrecedes(b.key) || (a.key == b.key && a.storageOffset < b.storageOffset)
        }
        var body: [UInt8] = []
        body.reserveCapacity(sorted.count * 18)
        var pc: UInt32 = 0, pb: UInt32 = 0
        for entry in sorted {
            var record = [UInt8](entry.key.prefix(9))
            let so = entry.storageOffset
            record += (0..<5).reversed().map { UInt8(truncatingIfNeeded: so >> (8 * UInt64($0))) }
            record += le32(entry.size)
            (pc, pb) = Lookup3.hashlittle2(record, pc, pb)
            body += record
        }
        out += le32(UInt32(body.count)) + le32(pc) + body
        // Room for the Agent's update section, rounded to 64 KiB.
        let total = (out.count + 0x7800 + 0xFFFF) & ~0xFFFF
        out += [UInt8](repeating: 0, count: total - out.count)
        return Data(out)
    }

    public static func indexFileName(bucket: Int, version: UInt32) -> String {
        String(format: "%02x%08x.idx", bucket, version)
    }

    /// `shmem` v5: index versions and the free-space table. Nil when the path
    /// doesn't fit its fixed 256-byte field (the game rebuilds it then).
    static func shmem(storagePath: String, indexVersions: [UInt32], archiveSizes: [UInt64]) -> Data? {
        var d = [UInt8](repeating: 0, count: 0x5000)
        let path = Array((storagePath.hasSuffix("/") ? String(storagePath.dropLast()) : storagePath).utf8) + Array("/index".utf8)
        guard path.count < 0x100 else { return nil }
        put32LE(&d, 0, 5)
        put32LE(&d, 4, 0x154)
        for (i, byte) in path.enumerated() { d[8 + i] = byte }
        put32LE(&d, 0x108, 0x2AB8)
        put32LE(&d, 0x10C, 0x1000)
        for (i, version) in indexVersions.prefix(16).enumerated() { put32LE(&d, 0x110 + 4 * i, version) }
        put32LE(&d, 0x150, 2)
        put32LE(&d, 0x154, 1)
        put32LE(&d, 0x158, 0x228)
        put32LE(&d, 0x1D8, 0x4000)
        for (i, value) in [1, 0, 0, 0, 1, 0, 0x40, 0x0C, 0x40, 0x104].enumerated() { put32LE(&d, 0x4000 + 4 * i, UInt32(value)) }

        var spans: [(size: UInt64, offset: UInt64)] = []
        for (archive, size) in archiveSizes.enumerated() where archiveSize - size > 0x40 {
            spans.append((archiveSize - size, UInt64(archive) << UInt64(offsetBits) | size))
        }
        for archive in archiveSizes.count..<maxArchives {
            spans.append((archiveSize, UInt64(archive) << UInt64(offsetBits)))
        }
        spans = Array(spans.prefix(freeSpanCapacity))
        put32LE(&d, 0x1000, 1)
        put32LE(&d, 0x1004, UInt32(spans.count))
        for (i, span) in spans.enumerated() {
            put40BE(&d, 0x1020 + 5 * i, span.size)
            put40BE(&d, 0x1020 + 5 * freeSpanCapacity + 5 * i, span.offset)
        }
        return Data(d)
    }

    // MARK: Bytes

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static func put32LE(_ d: inout [UInt8], _ at: Int, _ v: UInt32) { for (i, b) in le32(v).enumerated() { d[at + i] = b } }
    static func put40BE(_ d: inout [UInt8], _ at: Int, _ v: UInt64) {
        for i in 0..<5 { d[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(4 - i))) }
    }
}

/// Builds a local storage from scratch, one blob at a time. Every write is
/// journaled, so an interrupted install picks up where it stopped: the
/// journal is replayed and the last archive trimmed to what it records.
public final class CASCStorageWriter {
    public let directory: URL
    private var buckets = [[CASC.IndexEntry]](repeating: [], count: 16)
    private var stored = Set<Data>()          // 9-byte keys already written
    private var archive = -1
    private var archiveEnd: UInt64 = 0
    private var archiveHandle: FileHandle?
    private var archiveSizes: [UInt64] = []
    private let baseKey: Data
    private let journal: FileHandle
    private var unsyncedBytes = 0

    static let journalName = ".waypoint-journal"
    static let journalRecordSize = 16 + 2 + 8 + 4 + 1

    public var count: Int { stored.count }

    public init(directory: URL) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let journalURL = directory.appendingPathComponent(Self.journalName)
        let existing = (try? Data(contentsOf: journalURL)) ?? Data()

        // The journal's first record holds the container's base key.
        if existing.count >= 16 {
            baseKey = existing.prefix(16)
        } else {
            baseKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            fm.createFile(atPath: journalURL.path, contents: baseKey)
        }
        journal = try FileHandle(forWritingTo: journalURL)
        try journal.seekToEnd()
        try replay(existing.dropFirst(16))
    }

    public func contains(_ encodedKey: Data) -> Bool { stored.contains(encodedKey.prefix(9)) }

    /// Appends one BLTE blob (exactly as served by the CDN).
    public func append(encodedKey: Data, blob: Data, fullKey: Bool) throws {
        let key9 = Data(encodedKey.prefix(9))
        guard !stored.contains(key9) else { return }
        let size = UInt64(CASC.headerSize + blob.count)
        if archive < 0 || archiveEnd + size > CASC.archiveSize { try startArchive() }

        let header = CASC.entryHeader(encodedKey: encodedKey, blobSize: blob.count, archive: archive, offset: archiveEnd, fullKey: fullKey)
        archiveHandle!.write(header + blob)
        let entry = CASC.IndexEntry(key: key9, archive: archive, offset: archiveEnd, size: UInt32(size))
        buckets[CASC.bucket(of: key9)].append(entry)
        stored.insert(key9)
        archiveEnd += size

        var record = Data(encodedKey.prefix(16))
        record += Data(CASC.le16(UInt16(archive))) + Data(CASC.le64(entry.offset)) + Data(CASC.le32(entry.size)) + Data([fullKey ? 1 : 0])
        journal.write(record)
        unsyncedBytes += Int(size)
        if unsyncedBytes > 64 << 20 { try sync() }
    }

    /// Writes the index files and shmem. The storage is usable afterwards.
    public func finish() throws {
        try sync()
        try archiveHandle?.close()
        archiveHandle = nil
        if archive >= 0 { archiveSizes[archive] = archiveEnd }
        let fm = FileManager.default
        // An interrupted run can leave a started-but-empty archive behind.
        var extra = archive + 1
        while fm.fileExists(atPath: archiveURL(extra).path) {
            try fm.removeItem(at: archiveURL(extra))
            extra += 1
        }
        // A fresh storage: version 1 of every bucket. Remove stale ones.
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".idx") {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
        for bucket in 0..<16 {
            try CASC.indexFile(bucket: bucket, entries: buckets[bucket])
                .write(to: directory.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: 1)), options: .atomic)
        }
        if let shmem = CASC.shmem(storagePath: directory.path, indexVersions: Array(repeating: 1, count: 16), archiveSizes: archiveSizes) {
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
        }
        fm.createFile(atPath: directory.appendingPathComponent("index.lock.0").path, contents: Data())
        try journal.close()
        try fm.removeItem(at: directory.appendingPathComponent(Self.journalName))
    }

    // MARK: Internals

    private func startArchive() throws {
        if let handle = archiveHandle {
            try handle.synchronize()
            try handle.close()
            archiveSizes[archive] = archiveEnd
        }
        archive += 1
        guard archive < CASC.maxArchives else { throw TACTError.unsupported("storage larger than \(CASC.maxArchives) archives") }
        let url = archiveURL(archive)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        archiveHandle = try FileHandle(forWritingTo: url)
        let (headers, entries) = CASC.segmentHeaders(baseKey: baseKey, archive: archive)
        archiveHandle!.write(headers)
        for (bucket, entry) in entries { buckets[bucket].append(entry) }
        archiveEnd = UInt64(headers.count)
        archiveSizes.append(archiveEnd)
    }

    private func archiveURL(_ archive: Int) -> URL {
        directory.appendingPathComponent(String(format: "data.%03d", archive))
    }

    private func sync() throws {
        try archiveHandle?.synchronize()
        try journal.synchronize()
        unsyncedBytes = 0
    }

    /// Rebuilds state from the journal. Data after the last journaled blob is
    /// discarded; the next write continues right there.
    private func replay(_ records: Data) throws {
        let size = Self.journalRecordSize
        var bytes = [UInt8](records)
        bytes = Array(bytes.prefix(bytes.count - bytes.count % size))
        var lastArchive = -1
        var lastEnd: UInt64 = 0
        var trusted = 0
        for start in stride(from: 0, to: bytes.count, by: size) {
            let r = Array(bytes[start..<start + size])
            let key = Data(r[0..<16])
            let arc = Int(UInt16(r[16]) | UInt16(r[17]) << 8)
            let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(r[18 + $1]) << (8 * UInt64($1)) }
            let entrySize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(r[26 + $1]) << (8 * UInt32($1)) }
            let end = offset + UInt64(entrySize)
            // Only trust records whose bytes made it to disk.
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: archiveURL(arc).path)[.size] as? UInt64) ?? 0
            guard end <= fileSize else { break }
            while archive < arc {
                archive += 1
                let (_, entries) = CASC.segmentHeaders(baseKey: baseKey, archive: archive)
                for (bucket, e) in entries { buckets[bucket].append(e) }
                archiveSizes.append(UInt64(CASC.segmentHeadersSize))
            }
            let key9 = Data(key.prefix(9))
            buckets[CASC.bucket(of: key9)].append(CASC.IndexEntry(key: key9, archive: arc, offset: offset, size: entrySize))
            stored.insert(key9)
            archiveSizes[arc] = max(archiveSizes[arc], end)
            lastArchive = arc
            lastEnd = end
            trusted += 1
        }
        // Forget records whose data never reached disk, or new writes would
        // land after them and a later replay would trust overwritten bytes.
        try journal.truncate(atOffset: UInt64(16 + trusted * size))
        try journal.seekToEnd()
        guard lastArchive >= 0 else { return }
        // Drop anything written after the last journaled blob, then keep appending.
        archive = lastArchive
        archiveEnd = lastEnd
        let handle = try FileHandle(forWritingTo: archiveURL(lastArchive))
        try handle.truncate(atOffset: lastEnd)
        try handle.seek(toOffset: lastEnd)
        archiveHandle = handle
    }
}
