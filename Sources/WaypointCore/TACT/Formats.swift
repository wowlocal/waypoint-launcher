import Foundation

// Blizzard's content delivery formats (TACT/NGDP), as far as Waypoint needs
// them. Reference: https://wowdev.wiki/TACT

public enum TACTError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case checksumMismatch(String)
    case notFound(String)
    case network(String)

    public var description: String {
        switch self {
        case .malformed(let what): "Malformed \(what)"
        case .unsupported(let what): "Unsupported \(what)"
        case .checksumMismatch(let what): "Checksum mismatch for \(what)"
        case .notFound(let what): "Not found: \(what)"
        case .network(let what): "Network error: \(what)"
        }
    }
}

// MARK: - Bytes

/// Reads from a `Data` without copying it. `offset` is relative to the start
/// of the data, whatever its indices are.
struct ByteReader {
    let data: Data
    var offset: Int
    private var base: Int { data.startIndex }

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw TACTError.malformed("data (unexpected end)") }
        defer { offset += count }
        return Data(data[base + offset..<base + offset + count])
    }

    /// Like `bytes(_:)`, but sharing the underlying storage instead of
    /// copying (a slice: index it from its `startIndex`).
    mutating func slice(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw TACTError.malformed("data (unexpected end)") }
        defer { offset += count }
        return data[base + offset..<base + offset + count]
    }

    mutating func u8() throws -> UInt8 {
        guard offset < data.count else { throw TACTError.malformed("data (unexpected end)") }
        defer { offset += 1 }
        return data[base + offset]
    }

    /// Big-endian unsigned integer of `size` bytes.
    mutating func uintBE(_ size: Int) throws -> UInt64 {
        guard offset + size <= data.count else { throw TACTError.malformed("data (unexpected end)") }
        var value: UInt64 = 0
        for i in 0..<size { value = value << 8 | UInt64(data[base + offset + i]) }
        offset += size
        return value
    }

    mutating func cString() throws -> String {
        guard let end = data[(base + offset)...].firstIndex(of: 0) else { throw TACTError.malformed("string") }
        defer { offset = end - base + 1 }
        return String(decoding: data[(base + offset)..<end], as: UTF8.self)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - BPSV (the versions / cdns tables)

/// Pipe-separated table: a `Name!TYPE:size|…` header, `## seqn` comments, rows.
public struct BPSV: Sendable {
    public var rows: [[String: String]]

    public init(_ text: String) {
        var columns: [String] = []
        var rows: [[String: String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") || line.isEmpty { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if columns.isEmpty {
                columns = cells.map { String($0.split(separator: "!").first ?? "") }
                continue
            }
            rows.append(Dictionary(zip(columns, cells), uniquingKeysWith: { a, _ in a }))
        }
        self.rows = rows
    }
}

// MARK: - Key/value configs (build config, CDN config)

public struct TACTConfig: Sendable {
    public var values: [String: [String]]

    public init(_ text: String) {
        var values: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: eq)...].split(separator: " ").map(String.init)
        }
        self.values = values
    }

    public subscript(key: String) -> [String] { values[key] ?? [] }

    /// For `install = <content key> <encoded key>` style entries.
    public func encodedKey(_ key: String) -> String? {
        let parts = self[key]
        return parts.count >= 2 ? parts[1] : nil
    }
}

// MARK: - Encoding file (content key -> encoded key)

public struct EncodingTable: Sendable {
    public struct Entry: Sendable {
        public var encodedKey: Data
        public var size: UInt64
    }

    /// Only the entries that were asked for; the full table has every file in
    /// every build and we never need most of it.
    public var entries: [Data: Entry]

    /// Scans the table (ideally memory-mapped) in place, without copying keys.
    public init(_ data: Data, wanted: Set<Data>) throws {
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("EN".utf8) else { throw TACTError.malformed("encoding header") }
        _ = try r.u8() // version
        let ckeySize = Int(try r.u8())
        let ekeySize = Int(try r.uintBE(1))
        let pageSize = Int(try r.uintBE(2)) * 1024
        _ = try r.uintBE(2) // espec page size
        let pageCount = Int(try r.uintBE(4))
        _ = try r.uintBE(4) // espec page count
        _ = try r.u8()
        let especSize = Int(try r.uintBE(4))
        let pagesStart = r.offset + especSize + pageCount * (ckeySize + 16) // after the page index: first key + md5
        guard ckeySize == 16, ekeySize >= 1, pageSize > 0 else { throw TACTError.unsupported("encoding table key sizes \(ckeySize)/\(ekeySize)") }

        var remaining = Set(wanted.compactMap(Key16.init))
        var entries: [Data: Entry] = [:]
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for page in 0..<pageCount where !remaining.isEmpty {
                var p = pagesStart + page * pageSize
                let pageEnd = min(p + pageSize, raw.count)
                while p + 6 + ckeySize + ekeySize <= pageEnd {
                    let keyCount = Int(raw[p])
                    if keyCount == 0 { break }
                    let ckey = Key16(base + p + 6)
                    if remaining.remove(ckey) != nil {
                        let size = (1...5).reduce(UInt64(0)) { $0 << 8 | UInt64(raw[p + $1]) }
                        let ekeyStart = p + 6 + ckeySize
                        entries[ckey.data] = Entry(encodedKey: Data(raw[ekeyStart..<ekeyStart + ekeySize]), size: size)
                    }
                    p += 6 + ckeySize + keyCount * ekeySize
                }
            }
        }
        self.entries = entries
    }
}

// MARK: - Install manifest (loose files placed in the game folder)

public struct InstallManifest: Sendable {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var contentKey: Data
        public var size: UInt64
    }

    public struct Tag: Sendable {
        public var name: String
        public var type: UInt16
        /// Bit i (MSB first) set = entry i has this tag. A slice of the
        /// manifest: index it from `startIndex`.
        var mask: Data

        func contains(_ index: Int) -> Bool {
            let byte = index / 8
            guard byte < mask.count else { return false }
            return mask[mask.startIndex + byte] & (0x80 >> UInt8(index % 8)) != 0
        }
    }

    public var tags: [Tag]
    public var entries: [Entry]

    public init(_ data: Data) throws {
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("IN".utf8) else { throw TACTError.malformed("install manifest header") }
        _ = try r.u8() // version
        let hashSize = Int(try r.u8())
        let tagCount = Int(try r.uintBE(2))
        let entryCount = Int(try r.uintBE(4))
        let maskSize = (entryCount + 7) / 8

        var tags: [Tag] = []
        for _ in 0..<tagCount {
            let name = try r.cString()
            let type = UInt16(try r.uintBE(2))
            tags.append(Tag(name: name, type: type, mask: try r.slice(min(maskSize, r.data.count - r.offset))))
        }
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let path = try r.cString()
            let key = try r.bytes(hashSize)
            entries.append(Entry(path: path, contentKey: key, size: try r.uintBE(4)))
        }
        self.tags = tags
        self.entries = entries
    }

    /// Entries Battle.net would install for a tag string like
    /// `OSX EU? enUS speech?:OSX EU? deDE text?`. See
    /// `Tag.selectedIndices(_:in:entryCount:)` for the rule.
    public func select(tagString: String) -> [Entry] {
        Tag.selectedIndices(tagString, in: tags, entryCount: entries.count).map { entries[$0] }
    }
}

extension InstallManifest.Tag {
    /// Indices, in manifest order, of the entries a Battle.net tag string
    /// selects. Shared by the install and download manifests.
    ///
    /// The string holds `:`-separated tag sets, e.g.
    /// `OSX EU? enUS speech?:OSX EU? deDE text?`: the first set picks the
    /// speech-language files, the second the text-language files. An entry is
    /// selected when any set selects it.
    ///
    /// Within a set, the manifest's tags named in it are grouped by type
    /// (platform, region, locale, content…). The set selects an entry when,
    /// for every such type, the entry carries at least one of its named tags.
    /// Types the set names no tag of don't filter. Words the manifest has no
    /// tag for are ignored; a trailing `?` marks a tag as optional, which
    /// amounts to the same thing.
    static func selectedIndices(_ tagString: String, in tags: [Self], entryCount: Int) -> [Int] {
        let mask = selectionMask(tagString, in: tags, entryCount: entryCount)
        return (0..<entryCount).filter { mask[$0 / 8] & (0x80 >> UInt8($0 % 8)) != 0 }
    }

    /// The same selection as a bitmap (bit i, MSB first, set = entry i
    /// selected): ⌈entryCount/8⌉ bytes however many entries there are.
    static func selectionMask(_ tagString: String, in tags: [Self], entryCount: Int) -> [UInt8] {
        let byteCount = (entryCount + 7) / 8
        var sets = tagString.split(separator: ":")
        if sets.isEmpty { sets = [""] } // no tags at all: everything
        var result = [UInt8](repeating: 0, count: byteCount)
        for set in sets {
            let names = Set(set.split(whereSeparator: \.isWhitespace).map { word in
                String(word.hasSuffix("?") ? word.dropLast() : word)
            })
            var selected = [UInt8](repeating: 0xFF, count: byteCount)
            for group in Dictionary(grouping: tags.filter { names.contains($0.name) }, by: \.type).values {
                var any = [UInt8](repeating: 0, count: byteCount)
                for tag in group {
                    tag.mask.withUnsafeBytes { m in
                        for i in 0..<min(byteCount, m.count) { any[i] |= m[i] }
                    }
                }
                for i in 0..<byteCount { selected[i] &= any[i] }
            }
            for i in 0..<byteCount { result[i] |= selected[i] }
        }
        if entryCount % 8 != 0 { result[byteCount - 1] &= UInt8(truncatingIfNeeded: 0xFF00 >> (entryCount % 8)) }
        return result
    }
}

// MARK: - Download manifest (every encoded file a game keeps in local storage)

public struct DownloadManifest: Sendable {
    public struct Entry: Sendable, Equatable {
        public var encodedKey: Data
        public var size: UInt64
        /// Lower downloads first; games can start before low-priority data arrives.
        public var priority: Int8
    }

    /// Entries are read from the manifest's bytes on demand: WoW's lists
    /// about 3 million, far too many to hold as values. Keep the data
    /// memory-mapped (`CDNClient.decoded`) and this costs next to nothing.
    public struct Entries: RandomAccessCollection, Sendable {
        let manifest: DownloadManifest
        public var startIndex: Int { 0 }
        public var endIndex: Int { manifest.count }
        public subscript(i: Int) -> Entry {
            Entry(encodedKey: Data(manifest.data[manifest.recordStart(i)..<manifest.recordStart(i) + manifest.keySize]),
                  size: manifest.size(at: i), priority: manifest.priority(at: i))
        }
    }

    let data: Data
    let keySize: Int
    let entrySize: Int
    let entriesStart: Int
    public let count: Int
    var tags: [InstallManifest.Tag]

    public var entries: Entries { Entries(manifest: self) }

    /// Layout: `DL`, version, key size, has-checksum, entry count (u32),
    /// tag count (u16); v2 adds a flag-byte count, v3 a base priority and 3
    /// reserved bytes. Entries: key, 40-bit size, priority, optional u32
    /// checksum, flag bytes. Then tags, as in the install manifest.
    public init(_ data: Data) throws {
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("DL".utf8) else { throw TACTError.malformed("download manifest header") }
        let version = try r.u8()
        guard (1...3).contains(version) else { throw TACTError.unsupported("download manifest v\(version)") }
        keySize = Int(try r.u8())
        let hasChecksum = try r.u8() != 0
        count = Int(try r.uintBE(4))
        let tagCount = Int(try r.uintBE(2))
        var flagBytes = 0
        if version >= 2 { flagBytes = Int(try r.u8()) }
        if version >= 3 { _ = try r.bytes(4) }
        entrySize = keySize + 5 + 1 + (hasChecksum ? 4 : 0) + flagBytes
        entriesStart = data.startIndex + r.offset
        guard keySize > 0, r.offset + count * entrySize <= data.count else { throw TACTError.malformed("download manifest entries") }
        r.offset += count * entrySize

        let maskSize = (count + 7) / 8
        var tags: [InstallManifest.Tag] = []
        for _ in 0..<tagCount {
            let name = try r.cString()
            let type = UInt16(try r.uintBE(2))
            tags.append(InstallManifest.Tag(name: name, type: type, mask: try r.slice(min(maskSize, data.count - r.offset))))
        }
        self.data = data
        self.tags = tags
    }

    @inline(__always) func recordStart(_ i: Int) -> Int { entriesStart + i * entrySize }

    /// Entry i's encoded key (the first 16 bytes; manifests use 16).
    func key(at i: Int) -> Key16 {
        data.withUnsafeBytes { raw in Key16(raw.baseAddress! + (recordStart(i) - data.startIndex)) }
    }

    func size(at i: Int) -> UInt64 {
        let start = recordStart(i) + keySize
        return (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(data[start + $1]) }
    }

    func priority(at i: Int) -> Int8 { Int8(bitPattern: data[recordStart(i) + keySize + 5]) }

    /// Same selection rule as `InstallManifest.select(tagString:)`.
    public func select(tagString: String) -> [Entry] {
        InstallManifest.Tag.selectedIndices(tagString, in: tags, entryCount: count).map { entries[$0] }
    }

    /// The selection as a bitmap; see `InstallManifest.Tag.selectionMask`.
    func selectionMask(tagString: String) -> [UInt8] {
        InstallManifest.Tag.selectionMask(tagString, in: tags, entryCount: count)
    }
}

// MARK: - CDN archive index (where an encoded file sits inside an archive)

public struct ArchiveLocation: Sendable, Equatable {
    public var archive: String
    public var offset: UInt64
    public var size: UInt64
}

public enum ArchiveIndex {
    /// Visits every entry of an `.index` file in place (ideally memory-mapped),
    /// without copying keys: `visit(key, keySize, size, offset)` returns false
    /// to stop early.
    static func scan(_ data: Data, archive: String,
                     _ visit: (UnsafeRawPointer, Int, UInt64, UInt64) -> Bool) throws {
        // Footer: toc hash[8], version, 2 reserved, block size KB, offset bytes,
        // size bytes, key bytes, checksum bytes, element count (LE u32), checksum[8].
        let footerSize = 28
        guard data.count >= footerSize else { throw TACTError.malformed("archive index \(archive)") }
        var f = ByteReader(data, offset: data.count - footerSize + 8)
        _ = try f.u8()
        _ = try f.bytes(2)
        let blockSize = Int(try f.u8()) * 1024
        let offsetBytes = Int(try f.u8())
        let sizeBytes = Int(try f.u8())
        let keySize = Int(try f.u8())
        let checksumSize = Int(try f.u8())
        let entrySize = keySize + sizeBytes + offsetBytes
        guard blockSize > 0, entrySize > 0, keySize > 0 else { throw TACTError.malformed("archive index \(archive)") }

        // After the blocks: a table of contents with each block's last key and a checksum.
        let blockCount = (data.count - footerSize) / (blockSize + keySize + checksumSize)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            func uint(_ at: Int, _ n: Int) -> UInt64 { (0..<n).reduce(UInt64(0)) { $0 << 8 | UInt64(raw[at + $1]) } }
            for block in 0..<blockCount {
                var p = block * blockSize
                let end = p + blockSize
                while p + entrySize <= end {
                    if (0..<keySize).allSatisfy({ raw[p + $0] == 0 }) { break }
                    let size = uint(p + keySize, sizeBytes)
                    let offset = uint(p + keySize + sizeBytes, offsetBytes)
                    if !visit(base + p, keySize, size, offset) { return }
                    p += entrySize
                }
            }
        }
    }

    /// Finds the wanted encoded keys in an `.index` file.
    public static func locate(_ wanted: Set<Data>, in data: Data, archive: String) throws -> [Data: ArchiveLocation] {
        var remaining = Set(wanted.compactMap(Key16.init))
        var found: [Data: ArchiveLocation] = [:]
        try scan(data, archive: archive) { key, keySize, size, offset in
            guard keySize >= 16 else { return false }
            let k = Key16(key)
            if remaining.remove(k) != nil { found[k.data] = ArchiveLocation(archive: archive, offset: offset, size: size) }
            return !remaining.isEmpty
        }
        return found
    }
}
