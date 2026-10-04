import CryptoKit
import Foundation

/// The archive-group index: one index over every archive a CDN config lists
/// (and the patch-archive-group, over its patch archives). It isn't on the
/// CDN; the Battle.net Agent builds both from the archive indexes and keeps
/// them in `Data/indices`, and the game rebuilds them at startup when they're
/// missing. Built here exactly as the Agent does (byte for byte, checked
/// against Agent-written Warcraft III and Hearthstone groups), so the game
/// finds them ready.
///
/// Layout, like an archive index: 4 KB pages of entries (key 16, size u32 BE,
/// then the archive's position in the config's list and the offset there, BE:
/// 1 byte of position for up to 256 archives, else 2), zero-padded; then a
/// table of contents (each page's last key, then each page's MD5, first 8
/// bytes); then a 28-byte footer (TOC hash, version 1, 2 reserved, page size
/// in KB, field sizes, hash size, entry count u32 LE, footer hash). Entries
/// are sorted by key; a key in several archives keeps the first archive. The
/// file is named by the MD5 of its footer, which the CDN config lists.
public enum ArchiveGroup {
    static let pageSize = 4096
    static let footerSize = 28

    /// Builds the group for `indexFiles` (the archives' `.index` files, in the
    /// config's order) as `directory/<expected>.index`. Returns false, leaving
    /// nothing behind, when the result isn't named `expected`.
    @discardableResult
    public static func build(indexFiles: [URL], expected: String, in directory: URL) throws -> Bool {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("\(expected).index")
        if isValid(destination, name: expected) { return true }
        let partial = directory.appendingPathComponent("\(expected).index.\(UUID().uuidString).part")
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        let name: String
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            name = try autoreleasepool { try write(indexFiles, to: output) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        guard name == expected.lowercased() else {
            try? fm.removeItem(at: partial)
            Log.warning(.install, "archive_group_mismatch", nil, ["expected": expected, "built": name, "archives": indexFiles.count])
            return false
        }
        _ = try fm.replaceItemAt(destination, withItemAt: partial)
        return true
    }

    /// Whether a group file is complete: its footer's MD5 is its name.
    static func isValid(_ url: URL, name: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end >= UInt64(footerSize) else { return false }
        try? handle.seek(toOffset: end - UInt64(footerSize))
        guard let footer = try? handle.read(upToCount: footerSize), footer.count == footerSize else { return false }
        return Data(Insecure.MD5.hash(data: footer)).hex == name.lowercased()
    }

    /// A k-way merge of the sorted archive indexes, written page by page.
    /// Returns the name the result should have (MD5 of its footer).
    static func write(_ indexFiles: [URL], to output: FileHandle) throws -> String {
        var sources: [Source] = []
        sources.reserveCapacity(indexFiles.count)
        for file in indexFiles {
            sources.append(try Source(Data(contentsOf: file, options: .alwaysMapped), name: file.lastPathComponent))
        }
        let positionBytes = sources.count <= 0x100 ? 1 : 2
        let offsetBytes = 4 + positionBytes
        let entrySize = 16 + 4 + offsetBytes
        let perPage = pageSize / entrySize

        // Min-heap of (key, source); ties go to the earlier source.
        var heap: [(key: Key16, source: Int32)] = []
        heap.reserveCapacity(sources.count)
        func less(_ a: (key: Key16, source: Int32), _ b: (key: Key16, source: Int32)) -> Bool {
            a.key != b.key ? a.key < b.key : a.source < b.source
        }
        func siftDown(_ start: Int) {
            var i = start
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < heap.count, less(heap[l], heap[m]) { m = l }
                if r < heap.count, less(heap[r], heap[m]) { m = r }
                if m == i { return }
                heap.swapAt(i, m)
                i = m
            }
        }
        for (i, source) in sources.enumerated() where source.hasEntry { heap.append((source.key, Int32(i))) }
        for i in stride(from: heap.count / 2 - 1, through: 0, by: -1) { siftDown(i) }

        var page = [UInt8](repeating: 0, count: pageSize)
        var inPage = 0
        var lastKeys = Data()
        var pageHashes = Data()
        var count: UInt32 = 0
        var previous: Key16?
        func flush() throws {
            if inPage < perPage { for i in (inPage * entrySize)..<pageSize { page[i] = 0 } }
            let bytes = Data(page)
            try output.write(contentsOf: bytes)
            pageHashes += Data(Insecure.MD5.hash(data: bytes)).prefix(8)
            lastKeys += previous!.data
            inPage = 0
        }
        while let top = heap.first {
            let s = Int(top.source)
            if top.key != previous {
                var at = inPage * entrySize
                func put(_ value: UInt64, _ width: Int) {
                    for b in 0..<width { page[at + b] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(width - 1 - b))) }
                    at += width
                }
                put(top.key.hi, 8)
                put(top.key.lo, 8)
                put(UInt64(sources[s].size), 4)
                put(UInt64(s) << 32 | UInt64(sources[s].offset), offsetBytes)
                previous = top.key
                count += 1
                inPage += 1
                if inPage == perPage { try flush() }
            }
            sources[s].advance()
            if sources[s].hasEntry {
                heap[0] = (sources[s].key, top.source)
            } else {
                heap[0] = heap[heap.count - 1]
                heap.removeLast()
            }
            if !heap.isEmpty { siftDown(0) }
        }
        if inPage > 0 { try flush() }

        let toc = lastKeys + pageHashes
        try output.write(contentsOf: toc)
        var fields = Data([1, 0, 0, UInt8(pageSize / 1024), UInt8(offsetBytes), 4, 16, 8])
        fields += Data(CASC.le32(count))
        let footer = Data(Insecure.MD5.hash(data: toc)).prefix(8) + fields + Data(Insecure.MD5.hash(data: fields + Data(count: 8))).prefix(8)
        try output.write(contentsOf: footer)
        return Data(Insecure.MD5.hash(data: footer)).hex
    }

    /// Reads one archive index's entries in order, in place.
    struct Source {
        let data: Data
        let entrySize: Int
        let perPage: Int
        let pageBytes: Int
        let count: Int
        var index = 0
        private(set) var key = Key16(hi: 0, lo: 0)
        private(set) var size: UInt32 = 0
        private(set) var offset: UInt32 = 0

        var hasEntry: Bool { index < count }

        init(_ data: Data, name: String) throws {
            guard data.count >= ArchiveGroup.footerSize else { throw TACTError.malformed("archive index \(name)") }
            let footer = [UInt8](data.suffix(ArchiveGroup.footerSize))
            let (pageKB, offsetBytes, sizeBytes, keyBytes) = (Int(footer[11]), Int(footer[12]), Int(footer[13]), Int(footer[14]))
            guard pageKB > 0, keyBytes == 16, sizeBytes == 4, offsetBytes == 4 else {
                throw TACTError.unsupported("archive index \(name) layout (\(keyBytes)/\(sizeBytes)/\(offsetBytes))")
            }
            self.data = data
            entrySize = keyBytes + sizeBytes + offsetBytes
            pageBytes = pageKB * 1024
            perPage = pageBytes / entrySize
            count = Int(UInt32(footer[16]) | UInt32(footer[17]) << 8 | UInt32(footer[18]) << 16 | UInt32(footer[19]) << 24)
            guard (count + perPage - 1) / max(perPage, 1) * pageBytes <= data.count else { throw TACTError.malformed("archive index \(name) count") }
            load()
        }

        mutating func advance() {
            index += 1
            load()
        }

        private mutating func load() {
            guard index < count else { return }
            let at = (index / perPage) * pageBytes + (index % perPage) * entrySize
            (key, size, offset) = data.withUnsafeBytes { raw in
                let p = raw.baseAddress! + at
                return (Key16(p), UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt32.self)),
                        UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 20, as: UInt32.self)))
            }
        }
    }
}
