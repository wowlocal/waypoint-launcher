import CryptoKit
import Foundation

/// The shape of a local storage that the game checks before it reads
/// anything, and that verifying files one by one doesn't see (issue #19):
/// every archive starts with its 16 segment headers, the index lists them,
/// and no index entry reaches past its archive's end or into another file.
/// The game refuses a storage that breaks any of these ("Missing segment
/// header for archive '0'", "Overlapping spans detected", then NeedsRepair).
///
/// `inspectStructure` only reads. `repairStructure` fixes only what it can
/// prove: segment headers are rebuilt from the storage's own base key (taken
/// from an archive whose 16 headers are all intact), and an index entry is
/// dropped only when its archive confirms the bytes aren't there, or another
/// entry that directly overlaps it fully authenticates while it doesn't.
/// Archive data is never moved or deleted; a read that fails leaves things
/// as they are.
extension CASC {
    public struct StructureReport: Sendable, Equatable {
        /// Archive → segment-header slots (0–15) whose bytes are zero, missing,
        /// or a cut-off part of the expected header: rebuilt from the base key.
        public var blankHeaderSlots: [Int: [Int]] = [:]
        /// Archive → slots holding something other than the expected header.
        /// Left alone: they may be a variant this version doesn't write.
        public var foreignHeaderSlots: [Int: [Int]] = [:]
        /// Archive → slots the index doesn't list (with the expected key).
        public var unindexedHeaderSlots: [Int: [Int]] = [:]
        /// Header slots indexed under another key than the base key gives.
        public var foreignHeaderEntries = 0
        /// Archive → blank or unindexed slots repair must not touch: the
        /// index lists another key there, or another file's bytes.
        public var conflictedHeaderSlots: [Int: [Int]] = [:]
        /// Entries reaching past their archive's end, or into an archive that
        /// isn't there: their bytes don't exist.
        public var outOfBounds: [IndexEntry] = []
        /// Entries directly overlapping another entry whose bytes fully
        /// authenticate, while theirs don't: that file was written over them.
        public var displaced: [IndexEntry] = []
        /// Overlaps where neither or both sides authenticate, or a read
        /// failed: left alone.
        public var ambiguousOverlaps = 0
        /// No archive has all 16 headers intact, or they disagree: headers
        /// can't be rebuilt.
        public var baseKeyUnknown = false
        /// Whether overlaps were looked for (they take a sort of every entry).
        public var checkedOverlaps = false

        /// What the game refuses outright, and what writing more would make
        /// worse: blank headers, headers the index doesn't list (issue #19:
        /// "Missing segment header"), entries past an archive's end, and
        /// files written over others.
        public var isDamaged: Bool {
            !blankHeaderSlots.isEmpty || !unindexedHeaderSlots.isEmpty || !outOfBounds.isEmpty || !displaced.isEmpty
                || ambiguousOverlaps > 0
        }

        /// What writing more files would bury: blank headers, and entries
        /// past an archive's end (new files go right there). Overlaps
        /// elsewhere aren't made worse by appending, so they don't stop an
        /// update; Verify Files deals with them.
        public var blocksWriting: Bool { !blankHeaderSlots.isEmpty || !outOfBounds.isEmpty }

        public var isEmpty: Bool {
            !isDamaged && foreignHeaderSlots.isEmpty && unindexedHeaderSlots.isEmpty && foreignHeaderEntries == 0
        }

        public var logFields: [String: Any] {
            func slots(_ map: [Int: [Int]]) -> String {
                map.keys.sorted().map { "\($0):\(map[$0]!.count)" }.joined(separator: ",")
            }
            return ["blank_header_slots": slots(blankHeaderSlots), "foreign_header_slots": slots(foreignHeaderSlots),
                    "unindexed_header_slots": slots(unindexedHeaderSlots), "foreign_header_entries": foreignHeaderEntries,
                    "conflicted_header_slots": slots(conflictedHeaderSlots), "out_of_bounds": outOfBounds.count, "displaced": displaced.count, "ambiguous_overlaps": ambiguousOverlaps,
                    "base_key_unknown": baseKeyUnknown, "checked_overlaps": checkedOverlaps]
        }
    }

    static func isHeaderSlotEntry(_ entry: IndexEntry) -> Bool {
        entry.size == UInt32(headerSize) && entry.offset < UInt64(segmentHeadersSize) && entry.offset % UInt64(headerSize) == 0
    }

    static func archiveFile(_ archive: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "data.%03d", archive))
    }

    /// An archive's size, nil if it confirmedly isn't there. Any other
    /// failure throws: absence must be known, not assumed.
    static func archiveSize(_ archive: Int, in directory: URL) throws -> UInt64? {
        var info = stat()
        if stat(archiveFile(archive, in: directory).path, &info) == 0 { return UInt64(info.st_size) }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// The first `segmentHeadersSize` bytes of an archive (fewer if it's
    /// shorter, none if it isn't there). A failed read throws.
    static func archiveHead(_ archive: Int, in directory: URL) throws -> Data {
        guard try archiveSize(archive, in: directory) != nil else { return Data() }
        let handle = try FileHandle(forReadingFrom: archiveFile(archive, in: directory))
        defer { try? handle.close() }
        return try handle.read(upToCount: segmentHeadersSize) ?? Data()
    }

    /// The key an archive's own headers derive from: every slot holding a
    /// full header must be exactly what one key gives (each header's
    /// checksums tie it to its archive and slot, so one is proof), and they
    /// must agree. Blank or cut-off slots don't count; other bytes rule it out.
    static func ownBaseKey(_ head: Data, archive: Int) -> Data? {
        if case .key(let key) = headerEvidence(head, archive: archive) { return key }
        return nil
    }

    enum HeaderEvidence: Equatable { case none, key(Data), conflict }

    /// What an archive's own header bytes say about its key: nothing (all
    /// blank), one key, or a conflict (bytes that aren't a valid header, or
    /// headers of different keys). Only `.none` lets the storage's key in.
    static func headerEvidence(_ head: Data, archive: Int) -> HeaderEvidence {
        var found: Data?
        for slot in 0..<16 {
            let start = head.startIndex + slot * headerSize
            guard start < head.endIndex else { break }   // the rest is missing: blank
            let bytes = head[start..<min(start + headerSize, head.endIndex)]
            if bytes.allSatisfy({ $0 == 0 }) { continue }
            guard bytes.count == headerSize else { return .conflict }
            let candidate = Data(bytes.prefix(16).reversed())
            let expected = segmentHeaders(baseKey: candidate, archive: archive).data
            guard expected[expected.startIndex + slot * headerSize..<expected.startIndex + (slot + 1) * headerSize].elementsEqual(bytes),
                  found.map({ $0.dropFirst(3) == candidate.dropFirst(3) }) ?? true else { return .conflict }
            if found == nil { found = candidate }
        }
        return found.map { .key($0) } ?? .none
    }

    /// The base key all of a storage's segment headers derive from, taken
    /// only from archives whose 16 headers are exactly what that key gives
    /// (their checksums tie each to its archive and slot). Nil if none is
    /// intact, or no base key is shared by more than half of the intact
    /// ones (an archive restored from padded index keys can differ).
    static func corroboratedBaseKey(_ directory: URL, archives: Int) throws -> Data? {
        var votes: [Data: (base: Data, count: Int)] = [:]
        for archive in 0..<archives {
            let head = try archiveHead(archive, in: directory)
            guard head.count == segmentHeadersSize else { continue }
            let base = Data(head.prefix(16).reversed())
            guard segmentHeaders(baseKey: base, archive: archive).data == head else { continue }
            // Bytes 0–2 vary per archive and slot; 3–15 are the storage's.
            votes[Data(base.dropFirst(3)), default: (base, 0)].count += 1
        }
        // More than half of the intact archives, not just the most.
        let total = votes.values.reduce(0) { $0 + $1.count }
        return votes.values.first { 2 * $0.count > total }?.base
    }

    /// Reads a storage's structure; changes nothing. Without `checkOverlaps`
    /// it streams the index one bucket at a time; with it, it also keeps
    /// every entry's range (8 bytes each) to sort them per archive.
    public static func inspectStructure(_ directory: URL, checkOverlaps: Bool) throws -> StructureReport {
        var report = StructureReport()
        report.checkedOverlaps = checkOverlaps
        guard let state = try scanStorage(directory) else { return report }
        let sizes = try state.archiveSizes.indices.map { try archiveSize($0, in: directory) }
        let base = try corroboratedBaseKey(directory, archives: sizes.count)

        // Header entries can name an archive whose file is gone: its headers
        // are then blank, and get rebuilt like any others.
        struct HeaderKey: Equatable { var key: Data; var bucket: Int }
        var headerKeys: [Int: [Int: [HeaderKey]]] = [:]   // archive → slot → indexed keys
        var headerAreaFiles: [Int: [(start: UInt64, end: UInt64)]] = [:]   // other entries reaching into the headers
        var referenced = Set<Int>()
        var ranges = [[(start: UInt32, end: UInt32)]](repeating: [], count: checkOverlaps ? sizes.count : 0)
        for bucket in 0..<16 {
            try Task.checkCancellation()
            for entry in try loadBucket(directory, bucket: bucket, version: state.versions[bucket]) {
                if isHeaderSlotEntry(entry) {
                    // Their bytes are checked as headers below, missing or not.
                    guard entry.archive < maxArchives else { report.outOfBounds.append(entry); continue }
                    headerKeys[entry.archive, default: [:]][Int(entry.offset) / headerSize, default: []]
                        .append(HeaderKey(key: entry.key, bucket: bucket))
                    referenced.insert(entry.archive)
                    continue
                }
                let end = entry.offset + UInt64(entry.size)
                // Even one past its archive's end keeps its claim on header bytes.
                if entry.offset < UInt64(segmentHeadersSize) { headerAreaFiles[entry.archive, default: []].append((entry.offset, end)) }
                guard entry.archive < sizes.count, let size = sizes[entry.archive], end <= size else {
                    report.outOfBounds.append(entry)
                    continue
                }
                referenced.insert(entry.archive)
                // An empty entry (Battle.net lists some, several at offset 0)
                // takes up no bytes, so it can't overlap anything.
                if checkOverlaps, entry.size > 0 { ranges[entry.archive].append((UInt32(entry.offset), UInt32(truncatingIfNeeded: end))) }
            }
        }

        let archives = Set(sizes.indices.filter { sizes[$0] != nil }).union(referenced).sorted()
        for archive in archives {
            let head = try archiveHead(archive, in: directory)
            // An archive whose 16 headers agree with each other is judged by
            // its own key: archives written at different times can differ.
            let evidence = headerEvidence(head, archive: archive)
            // A conflict still reads against the storage's key (so a single bad
            // slot shows as just that); only writing there is ruled out.
            let archiveKey: Data? = switch evidence { case .key(let key): key; case .none, .conflict: base }
            let expected = archiveKey.map { segmentHeaders(baseKey: $0, archive: archive) }
            var blank: [Int] = [], foreign: [Int] = [], unindexed: [Int] = [], conflicted: [Int] = []
            for slot in 0..<16 {
                let start = slot * headerSize, end = start + headerSize
                let present = head[head.startIndex + min(start, head.count)..<head.startIndex + min(end, head.count)]
                let want = expected.map { $0.data[$0.data.startIndex + start..<$0.data.startIndex + end] }
                if let want, present.count == headerSize, present.elementsEqual(want) {
                    // Intact.
                } else if present.allSatisfy({ $0 == 0 }) || (want.map { present.elementsEqual($0.prefix(present.count)) } ?? false) {
                    // Zeroed, missing, or the start of the right header cut off.
                    blank.append(slot)
                } else {
                    foreign.append(slot)
                }
                let keys = headerKeys[archive]?[slot] ?? []
                var foreignKey = false
                if let expected {
                    // The expected key, in the bucket it belongs in.
                    let want = HeaderKey(key: expected.entries[slot].entry.key, bucket: expected.entries[slot].bucket)
                    if !keys.contains(want) { unindexed.append(slot) }
                    report.foreignHeaderEntries += keys.filter { $0 != want }.count
                    foreignKey = keys.contains { $0 != want }
                } else if keys.isEmpty {
                    unindexed.append(slot)
                }
                let occupied = (headerAreaFiles[archive] ?? []).contains { $0.start < UInt64(end) && UInt64(start) < $0.end }
                if foreignKey || occupied { conflicted.append(slot) }
            }
            if !conflicted.isEmpty { report.conflictedHeaderSlots[archive] = conflicted }
            if !blank.isEmpty { report.blankHeaderSlots[archive] = blank }
            if !foreign.isEmpty { report.foreignHeaderSlots[archive] = foreign }
            if !unindexed.isEmpty { report.unindexedHeaderSlots[archive] = unindexed }
        }
        report.baseKeyUnknown = base == nil && !(report.blankHeaderSlots.isEmpty && report.unindexedHeaderSlots.isEmpty)

        guard checkOverlaps else { return report }
        // Pairs of ranges that directly intersect (an identical range is one
        // file indexed twice, not an overlap), then the entries behind them.
        struct Span: Hashable { var archive: Int; var start: UInt32; var end: UInt32 }
        var pairs: [(Span, Span)] = []
        var shared = Set<Span>()   // one range listed under more than one entry
        let pairLimit = 100_000
        for archive in ranges.indices where ranges[archive].count > 1 {
            ranges[archive].sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
            var unique: [(start: UInt32, end: UInt32)] = []
            unique.reserveCapacity(ranges[archive].count)
            for range in ranges[archive] {
                if let last = unique.last, last == range {
                    shared.insert(Span(archive: archive, start: range.start, end: range.end))
                } else {
                    unique.append(range)
                }
            }
            ranges[archive] = []
            for i in unique.indices {
                var j = i + 1
                while j < unique.count, unique[j].start < unique[i].end, pairs.count <= pairLimit {
                    pairs.append((Span(archive: archive, start: unique[i].start, end: unique[i].end),
                                  Span(archive: archive, start: unique[j].start, end: unique[j].end)))
                    j += 1
                }
            }
        }
        guard !pairs.isEmpty || !shared.isEmpty else { return report }
        guard pairs.count <= pairLimit else {
            // Not a stray overwrite: nothing here is clear enough to repair.
            report.ambiguousOverlaps = pairs.count
            return report
        }
        var involved: [Span: [IndexEntry]] = [:]
        for (a, b) in pairs { involved[a] = []; involved[b] = [] }
        for span in shared { involved[span] = [] }
        for bucket in 0..<16 {
            for entry in try loadBucket(directory, bucket: bucket, version: state.versions[bucket]) where !isHeaderSlotEntry(entry) {
                let span = Span(archive: entry.archive, start: UInt32(entry.offset),
                                end: UInt32(truncatingIfNeeded: entry.offset + UInt64(entry.size)))
                if involved[span] != nil { involved[span]!.append(entry) }
            }
        }
        // Per range: whether a file there authenticates, and whether every
        // entry there was read and failed (a failed read proves nothing).
        var authenticator = Authenticator(directory: directory)
        var genuine: [Span: Bool] = [:], refuted: [Span: Bool] = [:]
        var results: [Span: [Bool?]] = [:]
        for (span, entries) in involved {
            let checked = entries.map { authenticator.authenticates($0) }
            results[span] = checked
            genuine[span] = checked.contains(true)
            refuted[span] = !checked.isEmpty && checked.allSatisfy { $0 == false }
        }
        // An entry is displaced when it fails to authenticate and directly
        // overlaps one that does. Anything else that overlaps stays.
        var displaced = Set<Span>()
        for (a, b) in pairs {
            if genuine[a] == true, refuted[b] == true { displaced.insert(b) }
            else if genuine[b] == true, refuted[a] == true { displaced.insert(a) }
        }
        // Overlaps that dropping those doesn't settle.
        report.ambiguousOverlaps = pairs.filter { !displaced.contains($0.0) && !displaced.contains($0.1) }.count
        report.displaced = displaced.flatMap { involved[$0] ?? [] }
        // Different keys listed at exactly the same range: only one can be
        // what's there. Those that fail while one checks out go.
        for span in shared where !displaced.contains(span) {
            let entries = involved[span] ?? [], checked = results[span] ?? []
            guard Set(entries.map(\.key)).count > 1 else { continue }
            if checked.contains(true) {
                report.displaced += zip(entries, checked).filter { $0.1 == false }.map(\.0)
            }
            // Nothing checks out, or one couldn't be read: not settled.
            if !checked.contains(true) || checked.contains(where: { $0 == nil }) { report.ambiguousOverlaps += 1 }
        }
        return report
    }

    /// Whether the bytes an entry points at are the file its key names, in
    /// full: the encoded key is the MD5 of the BLTE header, whose chunk table
    /// then accounts for every byte, each chunk checked against its MD5 (or
    /// of the whole blob when there's no chunk table, or of the raw file for
    /// the few stored raw). Nil when the archive can't be read.
    struct Authenticator {
        let directory: URL
        private var mapped: [Int: Data] = [:]

        init(directory: URL) { self.directory = directory }

        mutating func authenticates(_ entry: IndexEntry) -> Bool? {
            guard entry.size > UInt32(headerSize) else { return false }
            if mapped[entry.archive] == nil {
                guard let data = try? Data(contentsOf: archiveFile(entry.archive, in: directory), options: .alwaysMapped) else { return nil }
                mapped[entry.archive] = data
            }
            let archive = mapped[entry.archive]!
            guard entry.offset + UInt64(entry.size) <= UInt64(archive.count) else { return false }
            let blob = archive[archive.startIndex + Int(entry.offset) + headerSize..<archive.startIndex + Int(entry.offset) + Int(entry.size)]
            return CASC.authenticates(blob, key9: entry.key.prefix(9))
        }
    }

    static func authenticates(_ blob: Data, key9: Data) -> Bool {
        guard blob.count >= 4, blob.prefix(4).elementsEqual("BLTE".utf8) else {
            return Data(Insecure.MD5.hash(data: blob)).prefix(key9.count) == key9   // stored raw
        }
        return (try? BLTE.verify(blob, encodedKey: key9)) != nil
    }

    /// What `repairStructure` changed.
    public struct StructureRepair: Sendable, Equatable {
        public var before = StructureReport()
        public var after = StructureReport()
        public var rebuiltHeaderSlots = 0
        public var indexedHeaderSlots = 0
        public var droppedEntries = 0
        /// `shmem` named older index files than the newest set (an interrupted
        /// publication), and now names the newest.
        public var republishedShmem = false
        public var isEmpty: Bool { rebuiltHeaderSlots == 0 && indexedHeaderSlots == 0 && droppedEntries == 0 && !republishedShmem }
    }

    /// The free spans `shmem` lists, if it's one this version reads.
    static func shmemFreeSpans(_ directory: URL) -> [(archive: Int, offset: UInt64, size: UInt64)]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("shmem")),
              data.count >= 0x1020 + 10 * freeSpanCapacity else { return nil }
        let b = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        func be40(_ at: Int) -> UInt64 { (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(b[at + $1]) } }
        guard u32(0) == 5 else { return nil }
        let count = min(u32(0x1004), freeSpanCapacity)
        return (0..<count).map { i in
            let offset = be40(0x1020 + 5 * freeSpanCapacity + 5 * i)
            return (Int(offset >> UInt64(offsetBits)), offset & ((1 << UInt64(offsetBits)) - 1), be40(0x1020 + 5 * i))
        }
    }

    /// The index versions `shmem` names, if it's one this version reads.
    static func shmemIndexVersions(_ directory: URL) -> [UInt32]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("shmem")), data.count >= 0x150 else { return nil }
        let b = [UInt8](data.prefix(0x150))
        func u32(_ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
        guard u32(0) == 5 else { return nil }
        return (0..<16).map { u32(0x110 + 4 * $0) }
    }

    /// Fixes what `inspectStructure` finds and can be proven: blank segment
    /// headers rebuilt and unlisted ones indexed (when the base key is
    /// known), and entries whose bytes don't exist or were written over
    /// dropped from the index, as its next version. Everything else stays.
    /// A dropped file that an installed build needs is then simply missing,
    /// so verifying downloads it again. Safe to repeat after a crash: header
    /// bytes are written in place; new index files, then shmem, then the old
    /// index files go, and a later run finishes a publication cut short.
    /// The caller has checked that no game or Battle.net is running, and
    /// holds the storage's lock when `locked`.
    @discardableResult
    public static func repairStructure(_ directory: URL, locked: Bool = false) throws -> StructureRepair {
        let fm = FileManager.default
        var repair = StructureRepair()
        guard fm.fileExists(atPath: directory.path) else { return repair }
        let journal = directory.appendingPathComponent(CASCStorageWriter.journalName)
        guard !fm.fileExists(atPath: journal.path) else { throw UpdateError.unfinishedStorage(directory.path) }
        let lock = locked ? nil : try StorageLock(directory)
        defer { lock?.release() }
        guard !fm.fileExists(atPath: journal.path) else { throw UpdateError.unfinishedStorage(directory.path) }
        guard var state = try scanStorage(directory) else { return repair }

        /// What shmem can describe for these index versions, with sizes read
        /// for certain (a failed read throws rather than looking free).
        func publishable(_ versions: [UInt32]) throws -> Data? {
            let sizes = try (0..<state.archiveSizes.count).map { try archiveSize($0, in: directory) ?? 0 }
            guard sizes.count <= maxArchives, sizes.allSatisfy({ $0 <= archiveSize }) else { return nil }
            return shmem(storagePath: directory.path, indexVersions: versions, archiveSizes: sizes)
        }

        // A publication cut short: some buckets' next index files written
        // (every one of them readable), shmem still naming the previous set,
        // all still there. Finishing it makes the game read what this repair
        // (or a writer) meant it to; then the check below starts from there.
        if let named = shmemIndexVersions(directory), named != state.versions,
           (0..<16).allSatisfy({ state.versions[$0] == named[$0]
               || (named[$0] < UInt32.max && state.versions[$0] == named[$0] + 1
                   && fm.fileExists(atPath: directory.appendingPathComponent(indexFileName(bucket: $0, version: named[$0])).path)
                   && (try? loadBucket(directory, bucket: $0, version: state.versions[$0])) != nil) }),
           let shmem = try publishable(state.versions) {
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
            repair.republishedShmem = true
        }

        // Free spans over an archive's headers (a repair stopped after giving
        // an empty archive its headers, before shmem): no longer free.
        if let spans = shmemFreeSpans(directory),
           try spans.contains(where: { span in
               // Any header bytes already there, a whole block or part of one.
               guard span.offset < UInt64(segmentHeadersSize), span.archive < state.archiveSizes.count else { return false }
               return span.offset < min(try archiveSize(span.archive, in: directory) ?? 0, UInt64(segmentHeadersSize)) }),
           let shmem = try publishable(shmemIndexVersions(directory) ?? state.versions) {
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
            repair.republishedShmem = true
        }

        let before = try inspectStructure(directory, checkOverlaps: true)
        repair.before = before
        repair.after = before
        guard !before.isEmpty else { return finish(repair, directory) }
        // Sizes before anything is written: any archive that grows gets shmem
        // published again from its final size.
        let sizeCount = max(state.archiveSizes.count, (before.blankHeaderSlots.keys.max() ?? -1) + 1)
        let initialSizes = try (0..<sizeCount).map { try archiveSize($0, in: directory) ?? 0 }
        var base = try corroboratedBaseKey(directory, archives: state.archiveSizes.count)
        // Limits first: nothing is written unless the index and shmem that
        // follow can describe this storage.
        guard state.versions.allSatisfy({ $0 < UInt32.max }), try publishable(state.versions) != nil else {
            Log.warning(.install, "storage_structure_repair_skipped", "shmem can't describe this storage", ["path": directory.path])
            return finish(repair, directory)
        }
        if base == nil {
            // No archive left intact, as when a storage's only archive was
            // deleted: its indexed header keys still give it its headers.
            // Only for exactly one archive, confirmedly empty or gone, and
            // only while no archive keeps part of its headers (the helper
            // rewrites every short one). A deleted last archive is only known
            // from its indexed headers.
            let blank = Array(before.blankHeaderSlots.keys)
            let partial = try (0..<state.archiveSizes.count).contains { archive in
                let size = try archiveSize(archive, in: directory) ?? 0
                return size > 0 && size < UInt64(segmentHeadersSize)
            }
            if blank.count == 1, !partial, try (archiveSize(blank[0], in: directory) ?? 0) == 0 {
                try restoreMissingArchiveHeaders(directory)
                if let rescanned = try scanStorage(directory) { state = rescanned }
                base = try corroboratedBaseKey(directory, archives: state.archiveSizes.count)
            }
        }
        let current = base == nil ? before : try inspectStructure(directory, checkOverlaps: false)
        func conflicted(_ archive: Int) -> [Int] { current.conflictedHeaderSlots[archive] ?? [] }
        /// An archive's key: what its surviving headers prove, else the storage's.
        func key(for archive: Int) throws -> Data? {
            switch headerEvidence(try archiveHead(archive, in: directory), archive: archive) {
            case .key(let key): key
            case .none: base
            case .conflict: nil   // its own bytes disagree: nothing is written there
            }
        }

        // What gets written: header bytes, and the index's next version with
        // the header entries it lacks and without entries with no bytes of
        // their own.
        var rebuilds: [(archive: Int, key: Data, slots: [Int])] = []
        for (archive, slots) in current.blankHeaderSlots.sorted(by: { $0.key < $1.key }) {
            let rebuild = slots.filter { !conflicted(archive).contains($0) }
            if !rebuild.isEmpty, let key = try key(for: archive) { rebuilds.append((archive, key, rebuild)) }
        }
        var additions = [[IndexEntry]](repeating: [], count: 16)
        var indexed = 0
        for (archive, slots) in current.unindexedHeaderSlots where current.foreignHeaderSlots[archive] == nil {
            guard let key = try key(for: archive) else { continue }
            let entries = segmentHeaders(baseKey: key, archive: archive).entries
            for slot in slots where !conflicted(archive).contains(slot) {
                additions[entries[slot].bucket].append(entries[slot].entry)
                indexed += 1
            }
        }
        struct Location: Hashable { var key: Data; var storageOffset: UInt64; var size: UInt32 }
        let dropped = Set((before.outOfBounds.filter { !isHeaderSlotEntry($0) } + before.displaced)
            .map { Location(key: $0.key, storageOffset: $0.storageOffset, size: $0.size) })
        let rewritesIndex = !dropped.isEmpty || indexed > 0
        let newVersions = state.versions.map { $0 &+ 1 }
        let archiveCount = max(state.archiveSizes.count, sizeCount, (rebuilds.map(\.archive).max() ?? -1) + 1)
        /// shmem for these versions from the archives' sizes as they are now,
        /// at least `segmentHeadersSize` for those getting headers: rebuilt
        /// headers must never look like free space.
        func table(_ versions: [UInt32], growing: Set<Int>) throws -> Data? {
            let sizes = try (0..<archiveCount).map { archive -> UInt64 in
                let size = try archiveSize(archive, in: directory) ?? 0
                return growing.contains(archive) ? max(size, UInt64(segmentHeadersSize)) : size
            }
            guard sizes.count <= maxArchives, sizes.allSatisfy({ $0 <= archiveSize }) else { return nil }
            return shmem(storagePath: directory.path, indexVersions: versions, archiveSizes: sizes)
        }
        let grown = try Set(rebuilds.map(\.archive).filter { try (archiveSize($0, in: directory) ?? 0) < UInt64(segmentHeadersSize) })
        guard try table(rewritesIndex ? newVersions : state.versions, growing: grown) != nil else {
            Log.warning(.install, "storage_structure_repair_skipped", "shmem can't describe this storage", ["path": directory.path])
            return finish(repair, directory)
        }

        // Header bytes, in place: nothing indexes them as anything else.
        for rebuild in rebuilds {
            let url = archiveFile(rebuild.archive, in: directory)
            if try archiveSize(rebuild.archive, in: directory) == nil {
                guard fm.createFile(atPath: url.path, contents: nil) else { continue }
            }
            let expected = segmentHeaders(baseKey: rebuild.key, archive: rebuild.archive).data
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for slot in rebuild.slots {
                try handle.seek(toOffset: UInt64(slot * headerSize))
                try handle.write(contentsOf: expected[expected.startIndex + slot * headerSize..<expected.startIndex + (slot + 1) * headerSize])
                repair.rebuiltHeaderSlots += 1
            }
            try handle.synchronize()
        }

        if rewritesIndex {
            var written = Set<String>()
            for bucket in 0..<16 {
                var entries = try loadBucket(directory, bucket: bucket, version: state.versions[bucket])
                let count = entries.count
                entries.removeAll { dropped.contains(Location(key: $0.key, storageOffset: $0.storageOffset, size: $0.size)) }
                repair.droppedEntries += count - entries.count
                entries += additions[bucket]
                let name = indexFileName(bucket: bucket, version: newVersions[bucket])
                try indexFile(bucket: bucket, entries: entries).write(to: directory.appendingPathComponent(name), options: .atomic)
                written.insert(name)
            }
            repair.indexedHeaderSlots = indexed
            if let shmem = try table(newVersions, growing: []) {
                try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
                for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".idx") && !written.contains(file) {
                    try? fm.removeItem(at: directory.appendingPathComponent(file))
                }
            }
        } else if try (0..<archiveCount).contains(where: { archive in
                      try (archiveSize(archive, in: directory) ?? 0) != (archive < initialSizes.count ? initialSizes[archive] : 0) }),
                  let shmem = try table(state.versions, growing: []) {
            // Headers given to an archive shmem had as empty: no longer free.
            try shmem.write(to: directory.appendingPathComponent("shmem"), options: .atomic)
        }
        repair.after = try inspectStructure(directory, checkOverlaps: true)
        return finish(repair, directory)
    }

    private static func finish(_ repair: StructureRepair, _ directory: URL) -> StructureRepair {
        guard !repair.before.isEmpty || !repair.isEmpty else { return repair }
        var fields = repair.before.logFields
        fields["path"] = directory.path
        fields["rebuilt_header_slots"] = repair.rebuiltHeaderSlots
        fields["indexed_header_slots"] = repair.indexedHeaderSlots
        fields["dropped_entries"] = repair.droppedEntries
        fields["republished_shmem"] = repair.republishedShmem
        fields["damaged_after"] = repair.after.isDamaged
        Log.notice(.install, repair.isEmpty ? "storage_structure_found" : "storage_structure_repaired", nil, fields)
        return repair
    }
}
