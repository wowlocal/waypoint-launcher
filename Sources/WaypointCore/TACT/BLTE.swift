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
            output.write(chunk)
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
        guard headerSize <= blob.count,
              Data(Insecure.MD5.hash(data: blob.subdata(in: blob.startIndex..<blob.startIndex + headerSize))) == key
        else { throw TACTError.checksumMismatch(key.hex) }
        _ = try r.u8() // flags
        let chunkCount = Int(try r.uintBE(3))
        var offset = headerSize
        for index in 0..<chunkCount {
            let compressed = Int(try r.uintBE(4))
            _ = try r.uintBE(4)
            let md5 = try r.bytes(16)
            guard offset + compressed <= blob.count else { throw TACTError.malformed("BLTE chunk \(index) of \(key.hex)") }
            let chunk = blob.subdata(in: blob.startIndex + offset..<blob.startIndex + offset + compressed)
            guard Data(Insecure.MD5.hash(data: chunk)) == md5 else { throw TACTError.checksumMismatch("\(key.hex) chunk \(index)") }
            offset += compressed
        }
        guard offset == blob.count else { throw TACTError.malformed("BLTE length of \(key.hex)") }
    }

    private static func decode<S: BLTESource>(_ source: inout S, emit: (Data) throws -> Void) throws {
        var header = ByteReader(try source.read(8))
        guard try header.bytes(4) == Data("BLTE".utf8) else { throw TACTError.malformed("BLTE magic") }
        let headerSize = Int(try header.uintBE(4))

        guard headerSize > 0 else {
            // No chunk table: the rest of the file is a single chunk.
            try emit(decodeChunk(try source.readToEnd(), expectedSize: nil))
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
            let data = try source.read(chunk.compressed)
            guard Data(Insecure.MD5.hash(data: data)) == chunk.md5 else {
                throw TACTError.checksumMismatch("BLTE chunk \(index)")
            }
            let decoded = try decodeChunk(data, expectedSize: chunk.decompressed)
            guard decoded.count == chunk.decompressed else { throw TACTError.malformed("BLTE chunk \(index) size") }
            try emit(decoded)
        }
    }

    private static func decodeChunk(_ chunk: Data, expectedSize: Int?) throws -> Data {
        guard let mode = chunk.first else { return Data() }
        let body = chunk.dropFirst()
        switch mode {
        case UInt8(ascii: "N"):
            return Data(body)
        case UInt8(ascii: "Z"):
            return try inflate(Data(body), sizeHint: expectedSize)
        case UInt8(ascii: "F"):
            return try decode(Data(body))
        case UInt8(ascii: "E"):
            throw TACTError.unsupported("encrypted content")
        default:
            throw TACTError.unsupported("BLTE chunk mode \(mode)")
        }
    }

    static func inflate(_ data: Data, sizeHint: Int?) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TACTError.malformed("zlib stream")
        }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: sizeHint ?? data.count * 4)
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                    return status
                }
                if status == Z_STREAM_END { return }
                guard status == Z_OK else { throw TACTError.malformed("zlib data (status \(status))") }
            }
        }
        return output
    }
}

private protocol BLTESource {
    mutating func read(_ count: Int) throws -> Data
    mutating func readToEnd() throws -> Data
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

    mutating func readToEnd() throws -> Data {
        try read(data.count - offset)
    }
}

private struct FileSource: BLTESource {
    let handle: FileHandle

    mutating func read(_ count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw TACTError.malformed("BLTE (unexpected end of file)") }
        return data
    }

    mutating func readToEnd() throws -> Data {
        try handle.readToEnd() ?? Data()
    }
}
