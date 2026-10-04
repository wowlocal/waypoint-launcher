import Foundation

/// Minimal protobuf wire-format reader. Enough to walk Battle.net's product.db
/// without pulling in SwiftProtobuf or a .proto definition.
struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)

        var string: String? {
            if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }
            return nil
        }

        var message: ProtoReader? {
            if case .bytes(let d) = self { return ProtoReader(d) }
            return nil
        }

        var uint: UInt64? {
            if case .varint(let v) = self { return v }
            return nil
        }
    }

    enum Error: Swift.Error {
        case truncated
        case unsupportedWireType(Int)
    }

    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        // Re-base so indices start at 0 regardless of the slice we were given.
        self.data = Data(data)
        self.offset = self.data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func next() throws -> (field: Int, value: Value)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch Int(key & 7) {
        case 0:
            return (field, .varint(try readVarint()))
        case 1:
            return (field, .fixed64(try readFixed(8)))
        case 2:
            let length = Int(try readVarint())
            guard length >= 0, offset + length <= data.endIndex else { throw Error.truncated }
            let bytes = data[offset..<offset + length]
            offset += length
            return (field, .bytes(Data(bytes)))
        case 5:
            return (field, .fixed32(UInt32(try readFixed(4))))
        case let wireType:
            throw Error.unsupportedWireType(wireType)
        }
    }

    /// Collects all fields of the message, keyed by field number. Repeated
    /// fields keep every occurrence in order.
    func fields() throws -> [Int: [Value]] {
        var copy = self
        var result: [Int: [Value]] = [:]
        while let (field, value) = try copy.next() {
            result[field, default: []].append(value)
        }
        return result
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex, shift < 64 else { throw Error.truncated }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readFixed(_ size: Int) throws -> UInt64 {
        guard offset + size <= data.endIndex else { throw Error.truncated }
        var result: UInt64 = 0
        for i in 0..<size {
            result |= UInt64(data[offset + i]) << (8 * UInt64(i))
        }
        offset += size
        return result
    }
}

/// Tiny protobuf writer, used by tests to build fixtures.
struct ProtoWriter {
    private(set) var data = Data()

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var sub = ProtoWriter()
        build(&sub)
        bytes(field, sub.data)
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        writeVarint(UInt64(field << 3))
        writeVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        writeVarint(UInt64(field << 3 | 2))
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }
}
