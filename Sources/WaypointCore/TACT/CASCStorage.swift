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
    /// The update section starts at the sorted entries' end, rounded up to this.
    static let updateSectionAlignment = 0x1000
    /// Bytes of update section the game insists on from that point. Less and
    /// it refuses the storage ("Truncated KMT update section detected", then
    /// NeedsRepair) however sound the entries are.
    static let updateSectionReserve = 0x7800
    static let indexFileAlignment = 0x10000
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
        // Room for the update section, rounded to 64 KiB as the Agent writes it.
        let total = indexFileSize(sortedEnd: out.count)
        out += [UInt8](repeating: 0, count: total - out.count)
        return Data(out)
    }

    /// How big an `.idx` file whose sorted entries end at `sortedEnd` has to
    /// be: the game looks for its update section at the next 4 KiB boundary
    /// and wants `updateSectionReserve` bytes of it, and the file is a whole
    /// number of 64 KiB blocks.
    ///
    /// The 4 KiB step is what Waypoint 0.9.5 missed: reserving the bytes from
    /// the entries' end instead left as little as 0x7000 past the boundary
    /// (WoW Forever, 121,968 entries in a bucket: issue #3), which the game
    /// reads as a truncated update section. The sizes this returns match every
    /// Agent-written index measured so far (Warcraft III at ~4,700 entries a
    /// bucket, World of Warcraft at ~120,000).
    static func indexFileSize(sortedEnd: Int) -> Int {
        let updateStart = (sortedEnd + updateSectionAlignment - 1) & ~(updateSectionAlignment - 1)
        return (updateStart + updateSectionReserve + indexFileAlignment - 1) & ~(indexFileAlignment - 1)
    }

    public static func indexFileName(bucket: Int, version: UInt32) -> String {
        String(format: "%02x%08x.idx", bucket, version)
    }

    /// `shmem` v5: index versions and the free-space table. Nil when the path
    /// doesn't fit its fixed 256-byte field (the game rebuilds it then).
    /// `holes`: free gaps inside archives, as (size, storage offset), listed
    /// after cleaning so the Agent and the game could reuse them.
    static func shmem(storagePath: String, indexVersions: [UInt32], archiveSizes: [UInt64],
                      holes: [(size: UInt64, offset: UInt64)] = []) -> Data? {
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
        // The table holds 1,090 spans: archive tails and unused archives
        // first, then the biggest holes.
        let room = max(0, freeSpanCapacity - spans.count)
        spans += holes.filter { $0.size > 0x40 }.sorted { $0.size > $1.size }.prefix(room)
        spans.sort { $0.offset < $1.offset }
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
    private var replacing = Set<Key9>()
    private var versions = [UInt32](repeating: 0, count: 16)
    private let firstNewArchive: Int          // archives from here on are this writer's
    private var archive = -1
    private var archiveEnd: UInt64 = 0
    private var archiveHandle: FileHandle?
    private var archiveSizes: [UInt64] = []
    private let baseKey: Data
    private let lock: StorageLock
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
    /// storage is an error rather than something to start over on. Only one
    /// writer at a time (WoW's flavors share a storage): another one throws.
    public convenience init(directory: URL, allowExisting: Bool = false) throws {
        try self.init(directory: directory, allowExisting: allowExisting, verifying: nil)
    }

    /// Repair only the selected files. Replacements use the normal append
    /// journal; its keys supersede stale indexed locations when published.
    init(directory: URL, allowExisting: Bool, verifying items: [StorageItem]?) throws {
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        lock = try StorageLock(directory)
        if items != nil { try CASC.restoreMissingArchiveHeaders(directory) }
        replacing = Set((items ?? []).map { $0.key.prefix9 })
        journalURL = directory.appendingPathComponent(Self.journalName)
        var saved = (try? Data(contentsOf: journalURL, options: .alwaysMapped)) ?? Data()

        // All 16 published indexes are authoritative, even if an old fresh
        // install's journal survived beside them (or Battle.net completed the
        // folder meanwhile). Resume from those indexes, not as new storage:
        // the latter would replace archives and discard existing entries.
        if saved.count >= 16, Self.marker(in: saved.dropFirst(16)) == nil,
           let state = try CASC.scanStorage(directory) {
            guard allowExisting else { throw TACTError.unsupported("writing over the existing storage in \(directory.path)") }
            guard let last = state.archiveSizes.indices.last,
                  state.archiveSizes[last] >= UInt64(CASC.segmentHeadersSize),
                  let key = state.baseKey, try StoredKeys.load(directory) != nil
            else { throw TACTError.malformed("Cannot safely resume the stale journal in \(directory.path). Use Battle.net's Scan and Repair") }
            let header = key + Self.record(key: Self.markerKey, archive: last, offset: state.archiveSizes[last], size: 0, flag: 2)
            try header.write(to: journalURL, options: .atomic)
            saved = header
            Log.notice(.install, "stale_new_storage_journal_rebased", nil, ["path": directory.path])
        }

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

        var publishedArchiveSizes: [UInt64]?
        if let start {
            guard let state = try CASC.scanStorage(directory), let keys = try StoredKeys.load(directory) else {
                throw TACTError.malformed("storage in \(directory.path) is gone")
            }
            versions = state.versions
            // finish() may have published only some buckets before a crash.
            // A later journal integrity failure must never truncate bytes
            // those published buckets already use, including later archives.
            for bucket in 0..<16 {
                let entries = try CASC.loadBucket(directory, bucket: bucket, version: versions[bucket])
                if entries.contains(where: { $0.archive > start.archive || ($0.archive == start.archive && $0.offset + UInt64($0.size) > start.offset) }) {
                    publishedArchiveSizes = state.archiveSizes
                    break
                }
            }
            existing = keys
            archiveSizes = Array(state.archiveSizes.prefix(start.archive + 1))
            while archiveSizes.count < start.archive + 1 { archiveSizes.append(0) }
            archiveSizes[start.archive] = start.offset
            archive = start.archive
            archiveEnd = start.offset
        }
        journal = try FileHandle(forWritingTo: journalURL)
        try replay(saved.count > 16 ? saved.dropFirst(16) : Data(), skipping: isUpdate ? 1 : 0,
                   verifying: items, preserving: publishedArchiveSizes)
    }

    public func contains(_ encodedKey: Data) -> Bool { Key9(encodedKey).map(contains) ?? false }
    public func contains(_ key: Key16) -> Bool { contains(key.prefix9) }
    func contains(_ key: Key9) -> Bool { resumed.sortedContains(key) || (!replacing.contains(key) && existing?.contains(key) == true) }

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
            var additions: [CASC.IndexEntry] = []
            Self.journalEntries(journalData, skipping: isUpdate ? 1 : 0) { key9, entry in
                if key9.bucket == bucket { additions.append(entry) }
            }
            let replacementKeys = Set(additions.compactMap { Key9($0.key) })
            entries.removeAll { Key9($0.key).map(replacementKeys.contains) ?? false }
            entries += additions
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
        self.lock.release()
    }

    // MARK: Internals

    private static func randomKey() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    private static func record(key: Data, archive: Int, offset: UInt64, size: UInt32, flag: UInt8) -> Data {
        key.prefix(16) + Data(CASC.le16(UInt16(archive))) + Data(CASC.le64(offset)) + Data(CASC.le32(size)) + Data([flag])
    }

    /// Only a recognizable update marker can resume an otherwise empty
    /// update. A truncated marker must never be treated as a fresh storage.
    static func hasUnfinishedUpdate(_ directory: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(journalName)) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 + journalRecordSize), head.count >= 16 else { return false }
        return marker(in: head.dropFirst(16)) != nil
    }

    /// Whether the folder holds a new storage's journal (one without an
    /// update marker): a first write that hasn't finished.
    static func hasUnfinishedNewStorage(_ directory: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(journalName)) else { return false }
        defer { try? handle.close() }
        // Without its base key the writer ignores a journal and starts over.
        guard let head = try? handle.read(upToCount: 16 + journalRecordSize), head.count >= 16 else { return false }
        return marker(in: head.dropFirst(16)) == nil
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

    private func archiveURL(_ archive: Int) -> URL { Self.archiveURL(archive, in: directory) }

    private static func archiveURL(_ archive: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "data.%03d", archive))
    }

    /// Walks a journal's blob records (after `skipping` header records) while
    /// they can be trusted: each one's bytes made it to disk, and archives
    /// only go forward from `archive`. Returns how many it walked.
    private static func trustedRecords(_ records: Data, skipping header: Int, from archive: Int, in directory: URL,
                                       verifier: CASC.StoredBlobVerifier? = nil,
                                       _ body: (Key16, _ archive: Int, _ end: UInt64) -> Void) -> Int {
        let size = journalRecordSize
        let usable = records.count - records.count % size
        var current = archive
        var trusted = 0
        var fileSizes: [Int: UInt64] = [:]
        records.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var p = header * size
            while p + size <= usable {
                let key = Key16(base + p)
                let arc = Int(UInt16(raw[p + 16]) | UInt16(raw[p + 17]) << 8)
                let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[p + 18 + $1]) << (8 * UInt64($1)) }
                let entrySize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[p + 26 + $1]) << (8 * UInt32($1)) }
                let end = offset + UInt64(entrySize)
                if fileSizes[arc] == nil {
                    let path = archiveURL(arc, in: directory).path
                    fileSizes[arc] = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                }
                guard arc >= max(current, 0), end <= fileSizes[arc] ?? 0 else { break }
                if let verifier, !verifier.validJournalEntry(key, entry: CASC.IndexEntry(key: key.prefix9.data, archive: arc, offset: offset, size: entrySize)) { break }
                current = arc
                body(key, arc, end)
                trusted += 1
                p += size
            }
        }
        return trusted
    }

    /// Calls `body` with each key an interrupted install or update already
    /// wrote that resuming keeps (what `replay` trusts); nothing without a
    /// journal. Only reads, so a plan can tell what's left to download.
    static func forEachResumableKey(in directory: URL, verifying items: [StorageItem]? = nil, _ body: (Key16) -> Void) {
        guard let saved = try? Data(contentsOf: directory.appendingPathComponent(journalName), options: .alwaysMapped),
              saved.count >= 16 else { return }
        let records = saved.dropFirst(16)
        let start = marker(in: records)
        let verifier = items.map { CASC.StoredBlobVerifier(directory: directory, items: $0) }
        _ = trustedRecords(records, skipping: start == nil ? 0 : 1, from: start?.archive ?? -1, in: directory, verifier: verifier) { key, _, _ in body(key) }
    }

    /// Read-only recovery of pre-checkpoint installs. Ignore incomplete journal
    /// records and blobs whose archive bytes never reached disk.
    public static func journaledBytes(in directory: URL) -> UInt64 {
        guard let saved = try? Data(contentsOf: directory.appendingPathComponent(journalName), options: .alwaysMapped),
              saved.count >= 16 else { return 0 }
        let records = saved.dropFirst(16)
        let start = marker(in: records)
        let skip = start == nil ? 0 : 1
        let count = trustedRecords(records, skipping: skip, from: start?.archive ?? -1, in: directory) { _, _, _ in }
        return records.withUnsafeBytes { raw in
            (skip..<(skip + count)).reduce(UInt64(0)) { total, i in
                let p = i * journalRecordSize + 26
                let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[p + $1]) << (8 * UInt32($1)) }
                return total + UInt64(size > CASC.headerSize ? size - UInt32(CASC.headerSize) : 0)
            }
        }
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
    private func replay(_ records: Data, skipping header: Int, verifying items: [StorageItem]?, preserving published: [UInt64]?) throws {
        var lastArchive = -1
        var lastEnd: UInt64 = 0
        let verifier = items.map { CASC.StoredBlobVerifier(directory: directory, items: $0) }
        let trusted = Self.trustedRecords(records, skipping: header, from: archive, in: directory, verifier: verifier) { key, arc, end in
            while archive < arc {
                archive += 1
                archiveSizes.append(UInt64(CASC.segmentHeadersSize))
            }
            resumed.append(key.prefix9)
            archiveSizes[arc] = max(archiveSizes[arc], end)
            lastArchive = arc
            lastEnd = end
        }
        resumed.sort()
        // Forget records whose data never reached disk, or new writes would
        // land after them and a later replay would trust overwritten bytes.
        try journal.truncate(atOffset: UInt64(16 + (header + trusted) * Self.journalRecordSize))
        try journal.seekToEnd()
        if lastArchive >= 0 {
            archive = lastArchive
            archiveEnd = lastEnd
        }
        if let published {
            while archiveSizes.count < published.count { archiveSizes.append(0) }
            for i in published.indices { archiveSizes[i] = max(archiveSizes[i], published[i]) }
            if let last = published.indices.last(where: { published[$0] > 0 }) {
                if last > archive { archive = last; archiveEnd = published[last] }
                else if last == archive { archiveEnd = max(archiveEnd, published[last]) }
            }
        }
        guard archive >= 0 else { return }
        // Drop unjournaled bytes only when no published index needs them.
        let handle = try FileHandle(forWritingTo: archiveURL(archive))
        try handle.truncate(atOffset: archiveEnd)
        try handle.seek(toOffset: archiveEnd)
        archiveHandle = handle
    }
}

/// One writer's hold on a storage folder, across processes too (the CLI can
/// run next to the app): an exclusive `flock` on the folder itself, so no
/// file is left behind. Released by `release()` or when freed.
final class StorageLock {
    private var fd: Int32

    init(_ directory: URL) throws {
        // Not inherited: a process started meanwhile (a game) would keep holding it.
        fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path]) }
        // While any process is being started, it briefly holds a copy of every
        // descriptor, close-on-exec or not. Only a hold that lasts is a writer.
        let deadline = ContinuousClock.now + .seconds(1)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // A filesystem without locks still gets written, as before.
            guard errno == EWOULDBLOCK else { return }
            guard ContinuousClock.now < deadline else {
                close(fd)
                throw UpdateError.storageBusy(directory.path)
            }
            usleep(10_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// The 9-byte keys a local storage holds, sorted per index bucket and
/// searched by bisection: 16 bytes a key, a fraction of a `Set`'s cost.
public struct StoredKeys: Sendable {
    var buckets: [[Key9]]
    /// The storage as it was loaded: index versions and archive sizes
    /// change with every finished write.
    var versions: [UInt32] = []
    var archiveSizes: [UInt64] = []

    public var count: Int { buckets.reduce(0) { $0 + $1.count } }
    public func contains(_ key: Key9) -> Bool { buckets[key.bucket].sortedContains(key) }

    /// Position of a key within its bucket, for per-key flags.
    func position(of key: Key9) -> Int? {
        let keys = buckets[key.bucket]
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low < keys.count && keys[low] == key ? low : nil
    }
    public func contains(_ key: Key16) -> Bool { contains(key.prefix9) }

    /// Nil when the folder holds no storage, or only an unfinished new one.
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
        return StoredKeys(buckets: buckets, versions: state.versions, archiveSizes: state.archiveSizes)
    }
}

extension CASC {
    /// The full encoded keys come from the download/build manifests. Indexes
    /// contain only nine bytes, so membership alone cannot verify game data.
    final class StoredBlobVerifier {
        let directory: URL
        let items: [StorageItem]
        private var mappedArchive = -1
        private var mapped: Data?

        init(directory: URL, items: [StorageItem], sortedByKey: Bool = false) {
            self.directory = directory
            self.items = sortedByKey ? items : items.sorted { $0.key < $1.key }
        }

        func index(of key: Key9) -> Int? {
            var low = 0, high = items.count
            while low < high {
                let mid = (low + high) / 2
                if items[mid].key.prefix9 < key { low = mid + 1 } else { high = mid }
            }
            return low < items.count && items[low].key.prefix9 == key ? low : nil
        }

        func validJournalEntry(_ key: Key16, entry: IndexEntry) -> Bool {
            // A shared storage may have a paused sibling product's journal.
            // Preserve unrelated records rather than guessing their format.
            guard let i = index(of: key.prefix9) else { return true }
            return valid(entry, item: items[i])
        }

        func valid(_ entry: IndexEntry, item: StorageItem) -> Bool {
            guard entry.size > UInt32(headerSize), entry.offset >= UInt64(segmentHeadersSize) else { return false }
            if mappedArchive != entry.archive {
                mappedArchive = entry.archive
                let url = directory.appendingPathComponent(String(format: "data.%03d", entry.archive))
                mapped = try? Data(contentsOf: url, options: .alwaysMapped)
            }
            guard let mapped, entry.offset <= UInt64(mapped.count),
                  UInt64(entry.size) <= UInt64(mapped.count) - entry.offset else { return false }
            let start = mapped.startIndex + Int(entry.offset)
            let header = mapped[start..<start + headerSize]
            let storedKey = Data(header.prefix(16).reversed())
            guard storedKey.prefix(9) == item.encodedKey.prefix(9) else { return false }
            let flags = UInt16(header[header.startIndex + 20]) | UInt16(header[header.startIndex + 21]) << 8
            let expected = entryHeader(encodedKey: storedKey, blobSize: Int(entry.size) - headerSize,
                                       archive: entry.archive, offset: entry.offset, flags: flags, fullKey: true)
            guard header == expected else { return false }
            let blob = mapped[start + headerSize..<start + Int(entry.size)]
            if item.isRaw { return item.size == 0 || UInt64(blob.count) == item.size }
            do { try BLTE.verify(blob, encodedKey: item.encodedKey); return true }
            catch { return false }
        }
    }

    /// Returns one flag per selected item (which must be sorted by key),
    /// checking one mapped archive at a time. Normal update planning keeps
    /// its fast index-membership path.
    static func verifiedStorage(_ directory: URL, items: [StorageItem]) throws -> [Bool] {
        var valid = [Bool](repeating: false, count: items.count)
        guard let state = try scanStorage(directory) else { return valid }
        let verifier = StoredBlobVerifier(directory: directory, items: items, sortedByKey: true)
        for bucket in 0..<16 {
            try Task.checkCancellation()
            let entries = try loadBucket(directory, bucket: bucket, version: state.versions[bucket])
                .sorted { $0.storageOffset < $1.storageOffset }
            for (n, entry) in entries.enumerated() {
                if n % 256 == 0 { try Task.checkCancellation() }
                guard let key = Key9(entry.key), let i = verifier.index(of: key), !valid[i] else { continue }
                valid[i] = verifier.valid(entry, item: verifier.items[i])
            }
        }
        return valid
    }

    /// A missing archive also lost its segment headers. Their indexed keys
    /// are enough to restore an empty archive without changing any index or
    /// overwriting surviving game data. Retry after a crash repeats this safely.
    static func restoreMissingArchiveHeaders(_ directory: URL) throws {
        guard let state = try scanStorage(directory) else { return }
        var headers: [Int: [IndexEntry]] = [:]
        for bucket in 0..<16 {
            for entry in try loadBucket(directory, bucket: bucket, version: state.versions[bucket])
            where entry.size == UInt32(headerSize) && entry.offset < UInt64(segmentHeadersSize) {
                headers[entry.archive, default: []].append(entry)
            }
        }
        for (archive, entries) in headers {
            let url = directory.appendingPathComponent(String(format: "data.%03d", archive))
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < segmentHeadersSize else { continue }
            let offsets = Set(entries.map(\.offset))
            guard offsets == Set((0..<16).map { UInt64($0 * headerSize) }) else {
                throw TACTError.malformed("missing archive segment headers in \(url.path)")
            }
            var data = Data(count: segmentHeadersSize)
            for entry in entries {
                let key = entry.key + Data(repeating: 0, count: 16 - entry.key.count)
                let header = entryHeader(encodedKey: key, blobSize: 0, archive: archive,
                                         offset: entry.offset, flags: 1, fullKey: true)
                data.replaceSubrange(Int(entry.offset)..<Int(entry.offset) + headerSize, with: header)
            }
            try data.write(to: url, options: .atomic)
        }
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
        /// Where the sorted entries end: the update section starts at the next
        /// 4 KiB boundary from here.
        var sortedEnd: Int
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
            return ParsedIndex(bucket: Int(b[0x0A]), entries: entries, updates: updates,
                               sortedEnd: entriesStart + blockSize)
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

    /// What `repairIndexReserve` did.
    public struct IndexRepair: Sendable, Equatable {
        /// Index files that were extended, by name.
        public var repaired: [String] = []
        /// Short index files left alone: their update section already holds
        /// records, or they aren't in a format this version writes.
        public var skipped: [String] = []

        public var isEmpty: Bool { repaired.isEmpty && skipped.isEmpty }
    }

    /// Gives the game the update-section room an older Waypoint left out
    /// (issue #3: "Truncated KMT update section detected", then NeedsRepair,
    /// with every file of the install present and sound).
    ///
    /// Only the newest version of each of the 16 index files is considered,
    /// only when it is shorter than `indexFileSize` wants, and the only change
    /// is zeros appended past its end: the header, the sorted entries and
    /// their lookup3 checksums keep their bytes, and so does anything the game
    /// already wrote. An Agent-written storage — or one this version wrote — is
    /// long enough already and comes out untouched, so this can run on any
    /// install, including one Battle.net manages.
    ///
    /// An unfinished journal must be resumed by the writer, which rewrites
    /// the indexes itself. Report it rather than silently completing a repair.
    @discardableResult
    public static func repairIndexReserve(_ directory: URL) throws -> IndexRepair {
        let fm = FileManager.default
        var result = IndexRepair()
        guard fm.fileExists(atPath: directory.path) else { return result }
        let journal = directory.appendingPathComponent(CASCStorageWriter.journalName)
        guard !fm.fileExists(atPath: journal.path) else { throw UpdateError.unfinishedStorage(directory.path) }
        let lock = try StorageLock(directory)
        defer { lock.release() }
        // A writer may have left a journal while this repair waited for its lock.
        guard !fm.fileExists(atPath: journal.path) else { throw UpdateError.unfinishedStorage(directory.path) }
        guard let state = try scanStorage(directory) else { return result }

        for bucket in 0..<16 {
            let name = indexFileName(bucket: bucket, version: state.versions[bucket])
            let url = directory.appendingPathComponent(name)
            // Mapped only for the measurement: the file grows right after.
            var measured: (size: Int, needed: Int, emptyTail: Bool)?
            do {
                measured = try autoreleasepool {
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    let parsed = try parseIndexFile(data)
                    guard parsed.bucket == bucket else { throw TACTError.malformed("\(name) is for bucket \(parsed.bucket)") }
                    let tail = data[(data.startIndex + parsed.sortedEnd)...]
                    return (size: data.count, needed: indexFileSize(sortedEnd: parsed.sortedEnd),
                            emptyTail: tail.allSatisfy { $0 == 0 })
                }
            } catch {
                // A format this version doesn't write is not ours to pad.
                Log.warning(.install, "index_unreadable", nil, ["path": url.path, "error": error])
                result.skipped.append(name)
                continue
            }
            guard let measured, measured.size < measured.needed else { continue }
            guard measured.emptyTail else {
                Log.warning(.install, "index_tail_in_use", "update section already written", ["path": url.path])
                result.skipped.append(name)
                continue
            }
            let handle = try FileHandle(forWritingTo: url)
            do {
                // Past the end, so the new bytes read as zeros: an empty
                // update section, which is what the game expects to find.
                try handle.truncate(atOffset: UInt64(measured.needed))
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            result.repaired.append(name)
        }
        if !result.isEmpty {
            Log.notice(.install, "index_reserve_repaired", nil, ["path": directory.path, "repaired": result.repaired.count,
                                                                 "skipped": result.skipped.count])
        }
        return result
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

    /// Nil when the folder holds no storage, or only a new one still being
    /// written (archives and a journal, no complete index files yet).
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
        guard latest.count == 16 else {
            // A first install that stopped before `finish()` wrote the index
            // files: not a storage yet. The writer resumes it from its journal.
            if CASCStorageWriter.hasUnfinishedNewStorage(directory) { return nil }
            throw TACTError.malformed("storage in \(directory.path) has \(latest.count) of 16 index files")
        }
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

/// Removes what no installed build needs any more from a local storage, and
/// gives the space back to the disk. Updates only ever add files, so
/// without this a storage grows with every patch.
///
/// The index files lose the unneeded entries (written as their next
/// version, then shmem, then the old versions go, as when writing). Then
/// the archives shrink in place: a dead tail is cut off, and dead ranges
/// inside are punched out (APFS frees the blocks; the file keeps its
/// size). No data is moved, so it's quick and an interruption is harmless:
/// running it again finishes the job.
public enum CASCStorageCleaner {
    public struct Result: Sendable, Equatable {
        public var removedFiles = 0
        /// Bytes the removed entries took in the archives.
        public var removedBytes: UInt64 = 0
        /// Disk space actually given back (allocated size before minus after).
        public var reclaimedBytes: UInt64 = 0
        /// CDN indexes of old CDN configs removed from `Data/indices`.
        public var removedIndexBytes: UInt64 = 0
    }

    /// `isLive` says whether some installed build still needs a key; archive
    /// segment headers always stay. With `dryRun`, only counts.
    ///
    /// `isLive` is worked out from `snapshot` (and whatever `isCurrent`
    /// checks, such as `.build.info`), which takes network fetches: if
    /// another version's update wrote meanwhile, its new files would look
    /// dead. Nothing is removed then; that update cleans up after itself.
    public static func clean(_ directory: URL, dryRun: Bool = false, unchangedSince snapshot: StoredKeys? = nil,
                             isCurrent: () -> Bool = { true }, isLive: (Key9) -> Bool) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return Result() }
        let lock = try StorageLock(directory)
        defer { lock.release() }
        guard !fm.fileExists(atPath: directory.appendingPathComponent(CASCStorageWriter.journalName).path) else {
            throw TACTError.unsupported("cleaning a storage with an unfinished install or update")
        }
        guard let state = try CASC.scanStorage(directory) else { return Result() }
        if let snapshot, snapshot.versions != state.versions || snapshot.archiveSizes != state.archiveSizes || !isCurrent() {
            throw UpdateError.storageChanged
        }
        func keeps(_ entry: CASC.IndexEntry) -> Bool {
            let isSegmentHeader = entry.size == UInt32(CASC.headerSize) && entry.offset < UInt64(CASC.segmentHeadersSize)
                && entry.offset % UInt64(CASC.headerSize) == 0
            return isSegmentHeader || Key9(entry.key).map(isLive) == true
        }

        // Pass 1: what goes, and where what stays sits (for finding gaps).
        var result = Result()
        var ranges = [[(start: UInt32, end: UInt32)]](repeating: [], count: state.archiveSizes.count)
        struct Location: Hashable { var archive: Int; var offset: UInt64 }
        var removedAt = Set<Location>()
        for bucket in 0..<16 {
            for entry in try CASC.loadBucket(directory, bucket: bucket, version: state.versions[bucket]) {
                if keeps(entry) {
                    if entry.archive < ranges.count {
                        ranges[entry.archive].append((UInt32(entry.offset), UInt32(entry.offset + UInt64(entry.size))))
                    }
                } else {
                    result.removedFiles += 1
                    if removedAt.insert(Location(archive: entry.archive, offset: entry.offset)).inserted { result.removedBytes += UInt64(entry.size) }
                }
            }
        }
        removedAt = []
        guard !dryRun else { return result }

        // Pass 2: the index files without them, as their next version.
        var versions = state.versions
        if result.removedFiles > 0 {
            versions = state.versions.map { $0 + 1 }
            for bucket in 0..<16 {
                let entries = try CASC.loadBucket(directory, bucket: bucket, version: state.versions[bucket]).filter(keeps)
                try CASC.indexFile(bucket: bucket, entries: entries)
                    .write(to: directory.appendingPathComponent(CASC.indexFileName(bucket: bucket, version: versions[bucket])), options: .atomic)
            }
        }

        // Where the archives are dead: past the last live entry, and between entries.
        var holes: [(size: UInt64, offset: UInt64)] = []
        var liveEnds = [UInt64](repeating: 0, count: ranges.count)
        for archive in ranges.indices {
            ranges[archive].sort { $0.start < $1.start }
            var covered: UInt32 = 0
            for range in ranges[archive] {
                if range.start > covered {
                    holes.append((UInt64(range.start - covered), UInt64(archive) << UInt64(CASC.offsetBits) | UInt64(covered)))
                }
                covered = max(covered, range.end)
            }
            liveEnds[archive] = UInt64(covered)
        }
        ranges = []
        var sizes = state.archiveSizes
        for archive in sizes.indices where liveEnds[archive] > 0 { sizes[archive] = min(sizes[archive], liveEnds[archive]) }
        if result.removedFiles > 0 || !holes.isEmpty || sizes != state.archiveSizes,
           let shmem = CASC.shmem(storagePath: directory.path, indexVersions: versions, archiveSizes: sizes, holes: holes) {
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
        }
        if result.removedFiles > 0 {
            let current = Set((0..<16).map { CASC.indexFileName(bucket: $0, version: versions[$0]) })
            for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".idx") && !current.contains(file) {
                try? fm.removeItem(at: directory.appendingPathComponent(file))
            }
        }

        // Only now, with no index pointing there, give the dead bytes back.
        for archive in liveEnds.indices where liveEnds[archive] > 0 {
            let url = directory.appendingPathComponent(String(format: "data.%03d", archive))
            let before = allocatedSize(url)
            let fd = open(url.path, O_RDWR)
            guard fd >= 0 else { continue }
            if UInt64(lseek(fd, 0, SEEK_END)) > liveEnds[archive] { ftruncate(fd, off_t(liveEnds[archive])) }
            for hole in holes where hole.offset >> UInt64(CASC.offsetBits) == UInt64(archive) {
                punch(fd, from: hole.offset & ((1 << UInt64(CASC.offsetBits)) - 1), length: hole.size)
            }
            close(fd)
            let after = allocatedSize(url)
            if before > after { result.reclaimedBytes += before - after }
        }
        Log.notice(.install, "storage_cleaned", nil, ["path": directory.path, "removed_files": result.removedFiles,
                                                    "removed_bytes": result.removedBytes, "reclaimed_bytes": result.reclaimedBytes])
        return result
    }

    /// Frees the whole filesystem blocks inside a range (APFS; elsewhere it
    /// does nothing and the space stays used).
    private static func punch(_ fd: Int32, from offset: UInt64, length: UInt64) {
        let block: UInt64 = 4096
        let start = (offset + block - 1) / block * block
        let end = (offset + length) / block * block
        guard end > start else { return }
        var args = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(fd, F_PUNCHHOLE, &args)
    }

    private static func allocatedSize(_ url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_blocks) * 512
    }
}
