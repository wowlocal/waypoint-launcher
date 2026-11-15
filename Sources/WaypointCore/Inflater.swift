import Foundation
import zlib

/// A zlib stream fed piece by piece, inflating into 256 KB buffers.
final class Inflater {
    private var stream = z_stream()
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var ended = false

    /// `raw`: bare deflate data with no zlib header, as in zip files.
    init(raw: Bool = false) throws {
        let status = raw ? inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                         : inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
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
