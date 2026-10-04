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

/// Writes a local storage one blob at a time: a new one from scratch, or
/// more blobs into one that exists (an update, or another product sharing
/// it), whoever wrote it. Every write is journaled, so an interrupted run
/// picks up where it stopped: the journal is replayed and the archive being
/// written is trimmed to what it records.
///
/// Existing data is never moved or rewritten. New blobs go after the end of
/// the last archive, then into new ones; `finish()` writes every index file
/// as the next version, then `shmem`, and only then removes the old versions,
/// so a reader always finds a complete set.
///
/// Memory stays small however big the storage: the writer keeps no per-file
/// state beyond the sorted 9-byte keys a resumed run had already written
/// (and, updating, the ones the storage held), and builds each index file
/// from the journal at the end, one bucket at a time. Callers pass each key
/// once per run (plans are deduplicated); keys already stored are skipped.
public final class CASCStorageWriter {
    public let directory: URL
    /// Whether this adds to a storage that existed before.
    public let isUpdate: Bool
    private var resumed: [Key9] = []          // sorted: keys an interrupted run had written
    private var appended = 0
    private var existing: StoredKeys?         // updating: what the storage already held
    private var versions = [UInt32](repeating: 0, count: 16)
    private let firstNewArchive: Int          // archives from here on are this writer's
    private var archive = -1
    private var archiveEnd: UInt64 = 0
    private var archiveHandle: FileHandle?
    private var archiveSizes: [UInt64] = []
    private let baseKey: Data
    private let journalURL: URL
    private let journal: FileHandle
    private var unsyncedBytes = 0
    private var finished = false

    static let journalName = ".waypoint-journal"
    static let journalRecordSize = 16 + 2 + 8 + 4 + 1
    /// First journal record of an update: where appending started.
    static let markerKey = Data(repeating: 0xFF, count: 16)

    /// Keys stored, counting what an existing storage already had.
    public var count: Int { resumed.count + appended + (existing?.count ?? 0) }

    /// Starts a new storage, resumes an interrupted run, or (with
    /// `allowExisting`) adds to a finished storage. Without it, a finished
    /// storage is an error rather than something to start over on.
    public init(directory: URL, allowExisting: Bool = false) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        journalURL = directory.appendingPathComponent(Self.journalName)
        let saved = (try? Data(contentsOf: journalURL, options: .alwaysMapped)) ?? Data()

        var start: (archive: Int, offset: UInt64)?
        // The journal's first 16 bytes hold the container's base key.
        if saved.count >= 16 {
            baseKey = Data(saved.prefix(16))
            start = Self.marker(in: saved.dropFirst(16))
        } else if let state = try CASC.scanStorage(directory) {
            guard allowExisting else { throw TACTError.unsupported("writing over the existing storage in \(directory.path)") }
            guard let last = state.archiveSizes.indices.last else { throw TACTError.malformed("storage without archives in \(directory.path)") }
            baseKey = state.baseKey ?? Self.randomKey()
            start = (last, state.archiveSizes[last])
            let header = baseKey + Self.record(key: Self.markerKey, archive: last, offset: state.archiveSizes[last], size: 0, flag: 2)
            guard fm.createFile(atPath: journalURL.path, contents: header) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: journalURL.path])
            }
        } else {
            baseKey = Self.randomKey()
            guard fm.createFile(atPath: journalURL.path, contents: baseKey) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: journalURL.path])
            }
        }
        isUpdate = start != nil
        firstNewArchive = start.map { $0.archive + 1 } ?? 0

        if let start {
            guard let state = try CASC.scanStorage(directory), let keys = try StoredKeys.load(directory) else {
                throw TACTError.malformed("storage in \(directory.path) is gone")
            }
            versions = state.versions
            existing = keys
            archiveSizes = Array(state.archiveSizes.prefix(start.archive + 1))
            while archiveSizes.count < start.archive + 1 { archiveSizes.append(0) }
            archiveSizes[start.archive] = start.offset
            archive = start.archive
            archiveEnd = start.offset
        }
        journal = try FileHandle(forWritingTo: journalURL)
        try replay(saved.count > 16 ? saved.dropFirst(16) : Data(), skipping: isUpdate ? 1 : 0)
    }

    public func contains(_ encodedKey: Data) -> Bool { Key9(encodedKey).map(contains) ?? false }
    public func contains(_ key: Key16) -> Bool { contains(key.prefix9) }
    func contains(_ key: Key9) -> Bool { resumed.sortedContains(key) || existing?.contains(key) == true }

    public func append(encodedKey: Data, blob: Data, fullKey: Bool) throws {
        guard let key = Key16(encodedKey) else { throw TACTError.malformed("encoded key \(encodedKey.hex)") }
        try append(key: key, blob: blob, fullKey: fullKey)
    }

    /// Appends one BLTE blob (exactly as served by the CDN). A failed write
    /// (disk full) throws and leaves nothing behind, so the call can be
    /// retried, or the install resumed later.
    public func append(key: Key16, blob: Data, fullKey: Bool) throws {
        guard !finished else { throw TACTError.unsupported("appending to a finished storage") }
        let key9 = key.prefix9
        guard !contains(key9) else { return }
        let size = UInt64(CASC.headerSize + blob.count)
        guard size <= CASC.archiveSize - UInt64(CASC.segmentHeadersSize) else {
            throw TACTError.unsupported("\(blob.count)-byte file: larger than a storage archive")
        }
        if archive < 0 || archiveEnd + size > CASC.archiveSize { try startArchive() }
        guard let archiveHandle else { throw TACTError.unsupported("storage archive not open") }

        let encodedKey = key.data
        let header = CASC.entryHeader(encodedKey: encodedKey, blobSize: blob.count, archive: archive, offset: archiveEnd, fullKey: fullKey)
        let record = Self.record(key: encodedKey, archive: archive, offset: archiveEnd, size: UInt32(size), flag: fullKey ? 1 : 0)
        // FileHandle.write(_:) raises an Objective-C exception on failure,
        // which kills the app; write(contentsOf:) throws. Header and blob go
        // separately: the blob may be a slice of a mapped download.
        let journalEnd = try journal.offset()
        do {
            try archiveHandle.write(contentsOf: header)
            try archiveHandle.write(contentsOf: blob)
            try journal.write(contentsOf: record)
        } catch {
            // Cut off the partial write, or the next blob would land after it
            // while the index points before it.
            try? archiveHandle.truncate(atOffset: archiveEnd)
            try? journal.truncate(atOffset: journalEnd)
            throw error
        }
        appended += 1
        archiveEnd += size
        unsyncedBytes += Int(size)
        if unsyncedBytes > 64 << 20 { try sync() }
    }

    /// Writes the index files and shmem. The storage is usable afterwards,
    /// and the writer is done: further calls throw.
    public func finish() throws {
        guard !finished else { throw TACTError.unsupported("finishing a storage twice") }
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

        // This writer's segment headers, by bucket.
        var segmentEntries = [[CASC.IndexEntry]](repeating: [], count: 16)
        if archive >= firstNewArchive {
            for arc in firstNewArchive...archive {
                for (bucket, entry) in CASC.segmentHeaders(baseKey: baseKey, archive: arc).entries { segmentEntries[bucket].append(entry) }
            }
        }
        // The next version of every index file (1 for a new storage): what
        // was there, plus this writer's blobs from the journal. Then shmem;
        // only then drop the old versions.
        let journalData = try Data(contentsOf: journalURL, options: .alwaysMapped)
        let newVersions = versions.map { $0 + 1 }
        var writtenNames = Set<String>()
        struct Location: Hashable { var key: Data; var offset: UInt64 }
        for bucket in 0..<16 {
            var entries = isUpdate ? try CASC.loadBucket(directory, bucket: bucket, version: versions[bucket]) : []
            entries += segmentEntries[bucket]
            Self.journalEntries(journalData, skipping: isUpdate ? 1 : 0) { key9, entry in
                if key9.bucket == bucket { entries.append(entry) }
            }
            var seen = Set<Location>()
            entries.removeAll { !seen.insert(Location(key: $0.key, offset: $0.storageOffset)).inserted }
            let name = CASC.indexFileName(bucket: bucket, version: newVersions[bucket])
            try CASC.indexFile(bucket: bucket, entries: entries).write(to: directory.appendingPathComponent(name), options: .atomic)
            writtenNames.insert(name)
        }
        if let shmem = CASC.shmem(storagePath: directory.path, indexVersions: newVersions, archiveSizes: archiveSizes) {
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
        }
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".idx") && !writtenNames.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
        let lock = directory.appendingPathComponent("index.lock.0")
        if !fm.fileExists(atPath: lock.path) { fm.createFile(atPath: lock.path, contents: Data()) }
        try journal.close()
        try fm.removeItem(at: journalURL)
        versions = newVersions
        finished = true
    }

    // MARK: Internals

    private static func randomKey() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    private static func record(key: Data, archive: Int, offset: UInt64, size: UInt32, flag: UInt8) -> Data {
        key.prefix(16) + Data(CASC.le16(UInt16(archive))) + Data(CASC.le64(offset)) + Data(CASC.le32(size)) + Data([flag])
    }

    /// An update's journal starts with a marker: where appending began.
    private static func marker(in records: Data) -> (archive: Int, offset: UInt64)? {
        let r = [UInt8](records.prefix(journalRecordSize))
        guard r.count == journalRecordSize, Data(r[0..<16]) == markerKey, r[30] == 2 else { return nil }
        let arc = Int(UInt16(r[16]) | UInt16(r[17]) << 8)
        let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(r[18 + $1]) << (8 * UInt64($1)) }
        return (arc, offset)
    }

    /// Calls `body` for every blob record of a journal (after the base key and
    /// `skipping` header records).
    private static func journalEntries(_ journal: Data, skipping header: Int, _ body: (Key9, CASC.IndexEntry) -> Void) {
        let size = journalRecordSize
        journal.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var p = 16 + header * size
            while p + size <= raw.count {
                let key9 = Key9(base + p)
                let arc = Int(UInt16(raw[p + 16]) | UInt16(raw[p + 17]) << 8)
                let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[p + 18 + $1]) << (8 * UInt64($1)) }
                let entrySize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[p + 26 + $1]) << (8 * UInt32($1)) }
                body(key9, CASC.IndexEntry(key: key9.data, archive: arc, offset: offset, size: entrySize))
                p += size
            }
        }
    }

    /// Opens the next archive. Nothing changes unless it all succeeds.
    private func startArchive() throws {
        let next = archive + 1
        guard next < CASC.maxArchives else { throw TACTError.unsupported("storage larger than \(CASC.maxArchives) archives") }
        try archiveHandle?.synchronize()
        let url = archiveURL(next)
        let headers = CASC.segmentHeaders(baseKey: baseKey, archive: next).data
        try headers.write(to: url) // replaces what an interrupted run may have left
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        if let old = archiveHandle {
            try? old.close()
            archiveSizes[archive] = archiveEnd
        }
        archive = next
        archiveHandle = handle
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

    /// Rebuilds state from the journal (after `skipping` header records).
    /// Data after the last journaled blob is discarded (for an update with
    /// nothing journaled yet, everything after the old end); the next write
    /// continues right there.
    private func replay(_ records: Data, skipping header: Int) throws {
        let size = Self.journalRecordSize
        let usable = records.count - records.count % size
        var lastArchive = -1
        var lastEnd: UInt64 = 0
        var trusted = 0
        var fileSizes: [Int: UInt64] = [:]
        try records.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var p = header * size
            while p + size <= usable {
                let key9 = Key9(base + p)
                let arc = Int(UInt16(raw[p + 16]) | UInt16(raw[p + 17]) << 8)
                let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[p + 18 + $1]) << (8 * UInt64($1)) }
                let entrySize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[p + 26 + $1]) << (8 * UInt32($1)) }
                let end = offset + UInt64(entrySize)
                // Only trust records whose bytes made it to disk.
                if fileSizes[arc] == nil {
                    fileSizes[arc] = (try? FileManager.default.attributesOfItem(atPath: archiveURL(arc).path)[.size] as? UInt64) ?? 0
                }
                guard arc >= max(archive, 0), end <= fileSizes[arc] ?? 0 else { break }
                while archive < arc {
                    archive += 1
                    archiveSizes.append(UInt64(CASC.segmentHeadersSize))
                }
                resumed.append(key9)
                archiveSizes[arc] = max(archiveSizes[arc], end)
                lastArchive = arc
                lastEnd = end
                trusted += 1
                p += size
            }
        }
        resumed.sort()
        // Forget records whose data never reached disk, or new writes would
        // land after them and a later replay would trust overwritten bytes.
        try journal.truncate(atOffset: UInt64(16 + (header + trusted) * size))
        try journal.seekToEnd()
        if lastArchive >= 0 {
            archive = lastArchive
            archiveEnd = lastEnd
        }
        guard archive >= 0 else { return }
        // Drop anything written after that point, then keep appending.
        let handle = try FileHandle(forWritingTo: archiveURL(archive))
        try handle.truncate(atOffset: archiveEnd)
        try handle.seek(toOffset: archiveEnd)
        archiveHandle = handle
    }
}

/// The 9-byte keys a local storage holds, sorted per index bucket and
/// searched by bisection: 16 bytes a key, a fraction of a `Set`'s cost.
public struct StoredKeys: Sendable {
    var buckets: [[Key9]]

    public var count: Int { buckets.reduce(0) { $0 + $1.count } }
    public func contains(_ key: Key9) -> Bool { buckets[key.bucket].sortedContains(key) }
    public func contains(_ key: Key16) -> Bool { contains(key.prefix9) }

    /// Nil when the folder holds no storage.
    public static func load(_ directory: URL) throws -> StoredKeys? {
        guard let state = try CASC.scanStorage(directory) else { return nil }
        var buckets = [[Key9]](repeating: [], count: 16)
        for bucket in 0..<16 {
            var keys = try CASC.loadBucket(directory, bucket: bucket, version: state.versions[bucket]).compactMap { Key9($0.key) }
            keys.sort()
            var unique: [Key9] = []
            unique.reserveCapacity(keys.count)
            for key in keys where unique.last != key { unique.append(key) }
            buckets[bucket] = unique
        }
        return StoredKeys(buckets: buckets)
    }
}

extension CASC {
    /// One `.idx` file: its sorted entries, then the changes its update
    /// section records, oldest first (status 0: stored; anything else: gone
    /// or not resident).
    struct ParsedIndex {
        var bucket: Int
        var entries: [IndexEntry]
        var updates: [(entry: IndexEntry, status: UInt8)]
    }

    /// Reads a v7 index file, checking its lookup3 hashes. The update
    /// section (24-byte records in 512-byte pages after the sorted entries,
    /// each guarded by `hashlittle(record[4..<23]) | 0x80000000`) is read too:
    /// the game and the Agent append there before merging.
    static func parseIndexFile(_ data: Data) throws -> ParsedIndex {
        try data.withUnsafeBytes { raw -> ParsedIndex in
            let b = raw.bindMemory(to: UInt8.self)
            func u32(_ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
            func entry(_ at: Int) -> IndexEntry {
                let so = (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(b[at + 9 + $1]) }
                return IndexEntry(key: Data(b[at..<at + 9]), archive: Int(so >> UInt64(offsetBits)),
                                  offset: so & ((1 << UInt64(offsetBits)) - 1), size: u32(at + 14))
            }
            guard b.count >= 0x28 else { throw TACTError.malformed("index file") }
            let headerSize = Int(u32(0))
            guard headerSize >= 16, 8 + headerSize <= b.count,
                  Lookup3.hashlittle(Array(b[8..<8 + headerSize]), 0) == u32(4) else { throw TACTError.malformed("index header") }
            let revision = UInt16(b[8]) | UInt16(b[9]) << 8
            guard revision == 7, b[0x0C] == 4, b[0x0D] == 5, b[0x0E] == 9, b[0x0F] == UInt8(offsetBits) else {
                throw TACTError.unsupported("index format \(revision) (sizes \(b[0x0C])/\(b[0x0D])/\(b[0x0E]))")
            }
            let blockStart = (8 + headerSize + 15) & ~15
            guard blockStart + 8 <= b.count else { throw TACTError.malformed("index file") }
            let blockSize = Int(u32(blockStart))
            let entriesStart = blockStart + 8
            guard blockSize % 18 == 0, entriesStart + blockSize <= b.count else { throw TACTError.malformed("index entries") }
            var entries: [IndexEntry] = []
            entries.reserveCapacity(blockSize / 18)
            var pc: UInt32 = 0, pb: UInt32 = 0
            for at in stride(from: entriesStart, to: entriesStart + blockSize, by: 18) {
                (pc, pb) = Lookup3.hashlittle2(Array(b[at..<at + 18]), pc, pb)
                entries.append(entry(at))
            }
            guard pc == u32(blockStart + 4) else { throw TACTError.checksumMismatch("index file for bucket \(b[0x0A])") }

            var updates: [(IndexEntry, UInt8)] = []
            var page = (entriesStart + blockSize + 0x1FF) & ~0x1FF
            while page + 0x200 <= b.count {
                for slot in 0..<(0x200 / 24) {
                    let at = page + slot * 24
                    let guardValue = u32(at)
                    if guardValue == 0 { break }
                    guard guardValue & 0x8000_0000 != 0,
                          Lookup3.hashlittle(Array(b[at + 4..<at + 23]), 0) | 0x8000_0000 == guardValue else { continue }
                    updates.append((entry(at + 4), b[at + 22]))
                }
                page += 0x200
            }
            return ParsedIndex(bucket: Int(b[0x0A]), entries: entries, updates: updates)
        }
    }

    /// One bucket's entries from its index file, update section applied.
    static func loadBucket(_ directory: URL, bucket: Int, version: UInt32) throws -> [IndexEntry] {
        let url = directory.appendingPathComponent(indexFileName(bucket: bucket, version: version))
        let parsed = try parseIndexFile(Data(contentsOf: url, options: .alwaysMapped))
        guard parsed.bucket == bucket else { throw TACTError.malformed("\(url.lastPathComponent) is for bucket \(parsed.bucket)") }
        var entries = parsed.entries
        for (entry, status) in parsed.updates {
            entries.removeAll { $0.key == entry.key }
            if status == 0 { entries.append(entry) }
        }
        return entries
    }

    /// A storage's shape, without its entries.
    struct StorageState {
        /// Newest index file version per bucket.
        var versions: [UInt32]
        /// Size of every data.### file, by archive number.
        var archiveSizes: [UInt64]
        /// Bytes 3–15 of the segment-header keys; the rest is per archive.
        var baseKey: Data?
    }

    /// Nil when the folder holds no storage.
    static func scanStorage(_ directory: URL) throws -> StorageState? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var latest: [Int: UInt32] = [:]
        for name in files where name.count == 14 && name.hasSuffix(".idx") {
            guard let bucket = Int(name.prefix(2), radix: 16), bucket < 16,
                  let version = UInt32(name.dropFirst(2).prefix(8), radix: 16) else { continue }
            latest[bucket] = max(latest[bucket] ?? 0, version)
        }
        let archiveNumbers = files.compactMap { name in name.wholeMatch(of: /data\.(\d{3})/).flatMap { Int($0.1) } }
        guard !latest.isEmpty || !archiveNumbers.isEmpty else { return nil }
        guard latest.count == 16 else { throw TACTError.malformed("storage in \(directory.path) has \(latest.count) of 16 index files") }
        var state = StorageState(versions: (0..<16).map { latest[$0] ?? 0 }, archiveSizes: [], baseKey: nil)
        if let highest = archiveNumbers.max() {
            state.archiveSizes = (0...highest).map { archive in
                let path = directory.appendingPathComponent(String(format: "data.%03d", archive)).path
                return (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            }
        }
        if let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("data.000")) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 16), head.count == 16 { state.baseKey = Data(head.reversed()) }
        }
        return state
    }
}
