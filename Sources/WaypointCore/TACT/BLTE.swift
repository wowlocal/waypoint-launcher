import CryptoKit
import Foundation
import zlib

/// BLTE: the container every file on the CDN is wrapped in. A header lists
/// chunks (each with its own MD5), and each chunk is stored raw (`N`),
/// zlib-compressed (`Z`), encrypted (`E`) or nested BLTE (`F`).
public enum BLTE {
    /// Decodes a small blob (configs, manifests) in memory.
    public static func decode(_ data: Data) throws -> Data {
        var out = Data()
        var source = DataSource(data: data)
        try decode(&source) { out.append($0) }
        return out
    }

    /// Decodes a downloaded BLTE file into `output` chunk by chunk, so large
    /// game files never sit in memory whole. Returns the MD5 of the decoded
    /// content, which is the file's content key.
    public static func decode(file: URL, to output: FileHandle) throws -> Data {
        var md5 = Insecure.MD5()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var source = FileSource(handle: input)
        try decode(&source) { chunk in
            md5.update(data: chunk)
            // write(_:) raises an Objective-C exception on failure (disk full).
            try output.write(contentsOf: chunk)
        }
        return Data(md5.finalize())
    }

    /// Checks a blob exactly as served by the CDN, without decoding it: the
    /// encoded key is the MD5 of the BLTE header (or of the whole blob when
    /// there's no chunk table), and every chunk carries its own MD5.
    public static func verify(_ blob: Data, encodedKey: Data) throws {
        var r = ByteReader(blob)
        guard blob.count >= 8, try r.bytes(4) == Data("BLTE".utf8) else { throw TACTError.malformed("BLTE magic") }
        let headerSize = Int(try r.uintBE(4))
        let key = encodedKey.prefix(16)
        guard headerSize > 0 else {
            guard Data(Insecure.MD5.hash(data: blob)) == key else { throw TACTError.checksumMismatch(key.hex) }
            return
        }
        // Slices, not copies: blobs can be large and memory-mapped.
        guard headerSize <= blob.count,
              Data(Insecure.MD5.hash(data: blob[blob.startIndex..<blob.startIndex + headerSize])) == key
        else { throw TACTError.checksumMismatch(key.hex) }
        _ = try r.u8() // flags
        let chunkCount = Int(try r.uintBE(3))
        var offset = headerSize
        for index in 0..<chunkCount {
            let compressed = Int(try r.uintBE(4))
            _ = try r.uintBE(4)
            let md5 = try r.bytes(16)
            guard offset + compressed <= blob.count else { throw TACTError.malformed("BLTE chunk \(index) of \(key.hex)") }
            let chunk = blob[blob.startIndex + offset..<blob.startIndex + offset + compressed]
            guard Data(Insecure.MD5.hash(data: chunk)) == md5 else { throw TACTError.checksumMismatch("\(key.hex) chunk \(index)") }
            offset += compressed
        }
        guard offset == blob.count else { throw TACTError.malformed("BLTE length of \(key.hex)") }
    }

    /// Pieces are read and decoded this many bytes at a time: WoW's
    /// encoding table is a single 110 MB chunk.
    static let pieceSize = 4 << 20

    private static func decode<S: BLTESource>(_ source: inout S, emit: (Data) throws -> Void) throws {
        var header = ByteReader(try source.read(8))
        guard try header.bytes(4) == Data("BLTE".utf8) else { throw TACTError.malformed("BLTE magic") }
        let headerSize = Int(try header.uintBE(4))

        guard headerSize > 0 else {
            // No chunk table: the rest of the file is a single chunk, unchecked.
            _ = try decodeChunk(&source, size: nil, md5: nil, emit: emit)
            return
        }

        var table = ByteReader(try source.read(headerSize - 8))
        let flags = try table.u8()
        guard flags == 0x0F else { throw TACTError.unsupported("BLTE chunk table flags \(flags)") }
        let chunkCount = Int(try table.uintBE(3))
        var chunks: [(compressed: Int, decompressed: Int, md5: Data)] = []
        for _ in 0..<chunkCount {
            let compressed = Int(try table.uintBE(4))
            let decompressed = Int(try table.uintBE(4))
            chunks.append((compressed, decompressed, try table.bytes(16)))
        }

        for (index, chunk) in chunks.enumerated() {
            let produced = try decodeChunk(&source, size: chunk.compressed, md5: chunk.md5, emit: emit)
            guard produced == chunk.decompressed else { throw TACTError.malformed("BLTE chunk \(index) size") }
        }
    }

    /// Decodes one chunk of `size` bytes (nil: up to the end), reading and
    /// emitting it piece by piece, never whole. The MD5 is checked at the
    /// end, so on a mismatch the caller throws away what was emitted.
    /// Returns the decoded size.
    private static func decodeChunk<S: BLTESource>(_ source: inout S, size: Int?, md5 expected: Data?,
                                                   emit: (Data) throws -> Void) throws -> Int {
        var md5 = Insecure.MD5()
        var remaining = size ?? Int.max
        var mode: UInt8?
        var inflater: Inflater?
        var nested = Data() // `F` chunks: nested BLTE, rare and small
        var produced = 0
        while remaining > 0 {
            // FileHandle reads hand back autoreleased buffers: without a pool
            // per piece they'd all live until the whole file is done.
            let atEnd: Bool = try autoreleasepool {
                let piece = try source.readPiece(min(remaining, pieceSize))
                if piece.isEmpty {
                    guard size == nil else { throw TACTError.malformed("BLTE (unexpected end)") }
                    return true
                }
                remaining -= piece.count
                md5.update(data: piece)
                var body = piece[...]
                if mode == nil {
                    mode = body.first
                    body = body.dropFirst()
                    switch mode {
                    case UInt8(ascii: "N"), UInt8(ascii: "F"): break
                    case UInt8(ascii: "Z"): inflater = try Inflater()
                    case UInt8(ascii: "E"): throw TACTError.unsupported("encrypted content")
                    default: throw TACTError.unsupported("BLTE chunk mode \(mode ?? 0)")
                    }
                }
                guard !body.isEmpty else { return false }
                switch mode {
                case UInt8(ascii: "N"):
                    try emit(body)
                    produced += body.count
                case UInt8(ascii: "Z"):
                    produced += try inflater!.feed(body, emit: emit)
                default:
                    nested.append(body)
                }
                return false
            }
            if atEnd { break }
        }
        if let expected, Data(md5.finalize()) != expected { throw TACTError.checksumMismatch("BLTE chunk") }
        if let inflater { try inflater.finish() }
        if mode == UInt8(ascii: "F") {
            var source = DataSource(data: nested)
            try decode(&source) { piece in
                produced += piece.count
                try emit(piece)
            }
        }
        return produced
    }

    static func inflate(_ data: Data, sizeHint: Int?) throws -> Data {
        var output = Data(capacity: sizeHint ?? data.count * 4)
        let inflater = try Inflater()
        _ = try inflater.feed(data) { output.append($0) }
        try inflater.finish()
        return output
    }
}

/// A zlib stream fed piece by piece, inflating into 256 KB buffers.
private final class Inflater {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var ended = false

    init() throws {
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TACTError.malformed("zlib stream")
        }
    }

    deinit { inflateEnd(&stream) }

    /// Inflates `input`, handing the output to `emit`. Returns its size.
    func feed(_ input: Data, emit: (Data) throws -> Void) throws -> Int {
        guard !ended else { return 0 }
        var total = 0
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            repeat {
                let (status, produced) = buffer.withUnsafeMutableBufferPointer { out -> (Int32, Int) in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return (status, out.count - Int(stream.avail_out))
                }
                if produced > 0 {
                    total += produced
                    try emit(Data(buffer[0..<produced]))
                }
                if status == Z_STREAM_END { ended = true; return }
                // Out of input with the output not full: wait for the next piece.
                guard status == Z_OK || status == Z_BUF_ERROR else { throw TACTError.malformed("zlib data (status \(status))") }
                if status == Z_BUF_ERROR || (stream.avail_in == 0 && produced < buffer.count) { return }
            } while true
        }
        return total
    }

    func finish() throws {
        guard ended else { throw TACTError.malformed("zlib data (truncated)") }
    }
}

private protocol BLTESource {
    mutating func read(_ count: Int) throws -> Data
    /// Up to `count` bytes; empty at the end.
    mutating func readPiece(_ count: Int) throws -> Data
}

private struct DataSource: BLTESource {
    let data: Data
    var offset = 0

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw TACTError.malformed("BLTE (unexpected end)") }
        defer { offset += count }
        let start = data.startIndex + offset
        return Data(data[start..<start + count])
    }

    mutating func readPiece(_ count: Int) throws -> Data {
        try read(min(count, data.count - offset))
    }
}

private struct FileSource: BLTESource {
    let handle: FileHandle

    mutating func read(_ count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw TACTError.malformed("BLTE (unexpected end of file)") }
        return data
    }

    mutating func readPiece(_ count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }
}
