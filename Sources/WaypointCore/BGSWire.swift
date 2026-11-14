import Foundation

/// Small, bounded protobuf codec for the independently implemented account probe.
/// Unknown fields are retained; required fields are checked by the caller.
public enum BGSWire {
    public enum Failure: Error { case malformed, oversized }
    public enum Value: Equatable, Sendable { case number(UInt64), bytes(Data) }
    public typealias Message = [Int: [Value]]
    public static func varint(_ value: UInt64) -> Data {
        var n = value, out = Data()
        while n >= 128 { out.append(UInt8(n & 127) | 128); n >>= 7 }
        out.append(UInt8(n)); return out
    }
    public static func number(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    public static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    public static func text(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    public static func fixed32(_ field: Int, _ value: UInt32) -> Data {
        varint(UInt64(field << 3 | 5)) + Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    public static func decode(_ data: Data) throws -> Message {
        guard data.count <= 1_048_576 else { throw Failure.oversized }
        let input = Array(data); var index = 0; var result: Message = [:]
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < input.count else { throw Failure.malformed }
                let byte = input[index]; index += 1
                guard shift != 63 || byte <= 1 else { throw Failure.malformed }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw Failure.malformed
        }
        while index < input.count {
            let tag = try read(), field = Int(tag >> 3), wire = tag & 7
            guard field > 0, field <= 536_870_911 else { throw Failure.malformed }
            let value: Value
            switch wire {
            case 0: value = .number(try read())
            case 1, 5:
                let count = wire == 1 ? 8 : 4
                guard input.count - index >= count else { throw Failure.malformed }
                var n: UInt64 = 0
                for offset in 0..<count { n |= UInt64(input[index + offset]) << (offset * 8) }
                index += count; value = .number(n)
            case 2:
                let count = try read()
                guard count <= UInt64(input.count - index) else { throw Failure.malformed }
                value = .bytes(Data(input[index..<(index + Int(count))])); index += Int(count)
            default: throw Failure.malformed
            }
            result[field, default: []].append(value)
        }
        return result
    }
    public static func uint(_ message: Message, _ field: Int, default fallback: UInt64? = nil) throws -> UInt64 {
        if message[field] == nil, let fallback { return fallback }
        guard let values = message[field], values.count == 1, case .number(let n) = values[0] else { throw Failure.malformed }
        return n
    }
    public static func data(_ message: Message, _ field: Int) throws -> Data {
        guard let values = message[field], values.count == 1, case .bytes(let data) = values[0] else { throw Failure.malformed }
        return data
    }
}
