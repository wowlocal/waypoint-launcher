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

    public init(_ data: Data, wanted: Set<Data>) throws {
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("EN".utf8) else { throw TACTError.malformed("encoding header") }
        _ = try r.u8() // version
        let ckeySize = Int(try r.u8())
        let ekeySize = Int(try r.u8())
        let pageSize = Int(try r.uintBE(2)) * 1024
        _ = try r.uintBE(2) // espec page size
        let pageCount = Int(try r.uintBE(4))
        _ = try r.uintBE(4) // espec page count
        _ = try r.u8()
        let especSize = Int(try r.uintBE(4))
        r.offset += especSize
        r.offset += pageCount * (ckeySize + 16) // page index: first key + md5

        var entries: [Data: Entry] = [:]
        for page in 0..<pageCount {
            var p = ByteReader(data, offset: r.offset + page * pageSize)
            let pageEnd = p.offset + pageSize
            while p.offset + 6 + ckeySize <= min(pageEnd, data.count) {
                let keyCount = Int(try p.u8())
                if keyCount == 0 { break }
                let size = try p.uintBE(5)
                let ckey = try p.bytes(ckeySize)
                let firstEKey = try p.bytes(ekeySize)
                p.offset += (keyCount - 1) * ekeySize
                if wanted.contains(ckey) {
                    entries[ckey] = Entry(encodedKey: firstEKey, size: size)
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
        /// Bit i (MSB first) set = entry i has this tag.
        var mask: Data

        func contains(_ index: Int) -> Bool {
            mask[index / 8] & (0x80 >> UInt8(index % 8)) != 0
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
            tags.append(Tag(name: name, type: type, mask: try r.bytes(maskSize)))
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
    /// `OSX base … EU? enUS speech?:OSX base … enUS text?`.
    ///
    /// Tags are grouped by type (platform, region, locale, content…). An entry
    /// is selected when, for every type the string mentions, it carries at
    /// least one of the mentioned tags. Types not mentioned don't filter.
    /// Unknown words (`speech?`, `acct-CZE?`) are ignored.
    public func select(tagString: String) -> [Entry] {
        let words = Set(tagString.split(whereSeparator: { $0 == " " || $0 == ":" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "?")) })
        let byType = Dictionary(grouping: tags.filter { words.contains($0.name) }, by: \.type)
        return entries.indices.filter { index in
            byType.values.allSatisfy { group in group.contains { $0.contains(index) } }
        }.map { entries[$0] }
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

    public var entries: [Entry]
    var tags: [InstallManifest.Tag]

    /// Layout: `DL`, version, key size, has-checksum, entry count (u32),
    /// tag count (u16); v2 adds a flag-byte count, v3 a base priority and 3
    /// reserved bytes. Entries: key, 40-bit size, priority, optional u32
    /// checksum, flag bytes. Then tags, as in the install manifest.
    public init(_ data: Data) throws {
        var r = ByteReader(data)
        guard try r.bytes(2) == Data("DL".utf8) else { throw TACTError.malformed("download manifest header") }
        let version = try r.u8()
        guard (1...3).contains(version) else { throw TACTError.unsupported("download manifest v\(version)") }
        let keySize = Int(try r.u8())
        let hasChecksum = try r.u8() != 0
        let entryCount = Int(try r.uintBE(4))
        let tagCount = Int(try r.uintBE(2))
        var flagBytes = 0
        if version >= 2 { flagBytes = Int(try r.u8()) }
        if version >= 3 { _ = try r.bytes(4) }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let key = try r.bytes(keySize)
            let size = try r.uintBE(5)
            let priority = Int8(bitPattern: try r.u8())
            if hasChecksum { _ = try r.uintBE(4) }
            if flagBytes > 0 { _ = try r.bytes(flagBytes) }
            entries.append(Entry(encodedKey: key, size: size, priority: priority))
        }
        let maskSize = (entryCount + 7) / 8
        var tags: [InstallManifest.Tag] = []
        for _ in 0..<tagCount {
            let name = try r.cString()
            let type = UInt16(try r.uintBE(2))
            tags.append(InstallManifest.Tag(name: name, type: type, mask: try r.bytes(maskSize)))
        }
        self.entries = entries
        self.tags = tags
    }

    /// Same selection rule as `InstallManifest.select(tagString:)`.
    public func select(tagString: String) -> [Entry] {
        let words = Set(tagString.split(whereSeparator: { $0 == " " || $0 == ":" }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "?")) })
        let byType = Dictionary(grouping: tags.filter { words.contains($0.name) }, by: \.type)
        return entries.indices.filter { index in
            byType.values.allSatisfy { group in group.contains { $0.contains(index) } }
        }.map { entries[$0] }
    }
}

// MARK: - CDN archive index (where an encoded file sits inside an archive)

public struct ArchiveLocation: Sendable, Equatable {
    public var archive: String
    public var offset: UInt64
    public var size: UInt64
}

public enum ArchiveIndex {
    /// Scans an `.index` file for the wanted encoded keys.
    public static func locate(_ wanted: Set<Data>, in data: Data, archive: String) throws -> [Data: ArchiveLocation] {
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
        guard blockSize > 0, entrySize > 0 else { throw TACTError.malformed("archive index \(archive)") }

        // After the blocks: a table of contents with each block's last key and a checksum.
        let blockCount = (data.count - footerSize) / (blockSize + keySize + checksumSize)
        var found: [Data: ArchiveLocation] = [:]
        for block in 0..<blockCount {
            var r = ByteReader(data, offset: block * blockSize)
            let end = r.offset + blockSize
            while r.offset + entrySize <= end {
                let key = try r.bytes(keySize)
                if key.allSatisfy({ $0 == 0 }) { break }
                let size = try r.uintBE(sizeBytes)
                let offset = try r.uintBE(offsetBytes)
                if wanted.contains(key) {
                    found[key] = ArchiveLocation(archive: archive, offset: offset, size: size)
                }
            }
        }
        return found
    }
}
