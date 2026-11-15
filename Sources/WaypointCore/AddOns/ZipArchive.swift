import Foundation
import zlib

/// Reads a zip file: its list of entries, and each entry's contents. Only
/// what add-on zips use: one disk, no zip64, no encryption, stored or
/// deflated. Waypoint extracts entries itself rather than with `ditto` so
/// that it writes exactly the entries it checked, nothing else.
struct ZipArchive {
    struct Entry: Equatable {
        /// As stored, with `\` turned into `/`.
        var path: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localHeaderOffset: UInt64
        var isDirectory: Bool
        var isSymlink: Bool
        var isEncrypted: Bool
    }

    let url: URL
    let entries: [Entry]

    init(_ url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        // The end record is the last 22 bytes, plus a comment of up to 64 KB.
        let tailSize = min(fileSize, 22 + 65535)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.uint32(at: $0) == 0x0605_4b50 })
        else { throw ZipError.damaged }
        if end >= 20, tail.uint32(at: end - 20) == 0x0706_4b50 { throw ZipError.unsupported("zip64") }
        let disk = tail.uint16(at: end + 4), cdDisk = tail.uint16(at: end + 6)
        let count = Int(tail.uint16(at: end + 10))
        let cdSize = UInt64(tail.uint32(at: end + 12)), cdOffset = UInt64(tail.uint32(at: end + 16))
        guard disk == 0, cdDisk == 0 else { throw ZipError.unsupported("multi-disk") }
        guard count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("zip64") }
        guard cdOffset + cdSize <= fileSize - tailSize + UInt64(end) else { throw ZipError.damaged }
        try handle.seek(toOffset: cdOffset)
        let directory = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard directory.count == Int(cdSize) else { throw ZipError.damaged }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.uint32(at: at) == 0x0201_4b50 else { throw ZipError.damaged }
            let madeBy = directory.uint16(at: at + 4)
            let flags = directory.uint16(at: at + 8)
            let method = directory.uint16(at: at + 10)
            let crc = directory.uint32(at: at + 16)
            let compressed = UInt64(directory.uint32(at: at + 20)), size = UInt64(directory.uint32(at: at + 24))
            let nameLength = Int(directory.uint16(at: at + 28))
            let extraLength = Int(directory.uint16(at: at + 30)), commentLength = Int(directory.uint16(at: at + 32))
            let external = directory.uint32(at: at + 38)
            let offset = UInt64(directory.uint32(at: at + 42))
            guard at + 46 + nameLength <= directory.count else { throw ZipError.damaged }
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw ZipError.unsupported("zip64") }
            let nameData = directory.subdata(in: (at + 46)..<(at + 46 + nameLength))
            // Bit 11 marks UTF-8; older tools wrote code page 437, which
            // Latin-1 reads well enough for the ASCII names add-ons use.
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            let unixMode = madeBy >> 8 == 3 ? (external >> 16) & 0o170000 : 0
            entries.append(Entry(path: name.replacingOccurrences(of: "\\", with: "/"),
                                 method: method, crc: crc, compressedSize: compressed, size: size, localHeaderOffset: offset,
                                 isDirectory: name.hasSuffix("/") || name.hasSuffix("\\") || unixMode == 0o040000 || (madeBy >> 8 == 0 && external & 0x10 != 0),
                                 isSymlink: unixMode == 0o120000,
                                 isEncrypted: flags & 1 != 0))
            at += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Writes the entry's contents to `file`, which must not exist. Checks
    /// its size and CRC as it goes: it stops at the size the zip declared.
    func extract(_ entry: Entry, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        try read(entry) { try output.write(contentsOf: $0) }
    }

    /// The whole entry, when it's at most `maximum` bytes.
    func data(_ entry: Entry, maximum: Int) throws -> Data {
        guard entry.size <= UInt64(maximum) else { throw ZipError.tooLarge }
        var data = Data(capacity: Int(entry.size))
        try read(entry) { data.append($0) }
        return data
    }

    private func read(_ entry: Entry, emit: (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.unsupported("encrypted") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30, header.uint32(at: 0) == 0x0403_4b50 else {
            throw ZipError.damaged
        }
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28)))

        var remaining = entry.compressedSize
        var written: UInt64 = 0
        var crc = crc32(0, nil, 0)
        func output(_ piece: Data) throws {
            written += UInt64(piece.count)
            // Count what really comes out, not what the header claims.
            guard written <= entry.size else { throw ZipError.damaged }
            crc = piece.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try emit(piece)
        }
        let inflater: Inflater?
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw ZipError.damaged }
            inflater = nil
        case 8: inflater = try Inflater(raw: true)
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw ZipError.damaged }
            remaining -= UInt64(chunk.count)
            if let inflater {
                do { _ = try inflater.feed(chunk, emit: output) } catch is TACTError { throw ZipError.damaged }
            } else {
                try output(chunk)
            }
        }
        if let inflater {
            do { try inflater.finish() } catch is TACTError { throw ZipError.damaged }
        }
        guard written == entry.size, UInt32(crc) == entry.crc else { throw ZipError.damaged }
    }
}

enum ZipError: Error, Equatable, LocalizedError {
    case damaged, tooLarge
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .damaged: "The download was damaged. Try again."
        case .tooLarge: "The add-on’s download is too large."
        case .unsupported: "This add-on’s download is in a format Waypoint can’t open."
        }
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
