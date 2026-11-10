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
        case overflowingVarint
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
            guard let length = Int(exactly: try readVarint()), length <= data.endIndex - offset else {
                throw Error.truncated
            }
            let end = offset + length
            let bytes = data[offset..<end]
            offset = end
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

    /// Transform a length-delimited field while retaining every other wire
    /// byte, including unknown fields and their original ordering.
    func mappingBytes(_ field: Int, _ transform: (Data) throws -> Data) throws -> Data {
        var reader = self
        var result = Data()
        while !reader.isAtEnd {
            let start = reader.offset
            guard let entry = try reader.next() else { break }
            if entry.field == field {
                guard case .bytes(let bytes) = entry.value else { throw TACTError.malformed("protobuf field \(field)") }
                let updated = try transform(bytes)
                if updated == bytes { result.append(data[start..<reader.offset]) }
                else {
                    var writer = ProtoWriter()
                    writer.bytes(field, updated)
                    result.append(writer.data)
                }
            } else { result.append(data[start..<reader.offset]) }
        }
        return result
    }

    func replacingBytes(_ field: Int, with bytes: Data) throws -> Data {
        var found = false
        var result = try mappingBytes(field) { _ in found = true; return bytes }
        if !found {
            var writer = ProtoWriter()
            writer.bytes(field, bytes)
            result.append(writer.data)
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
            // A UInt64 has only one bit left in the tenth byte. Check before
            // shifting, which would otherwise silently discard overflowing bits.
            guard shift != 63 || byte <= 1 else { throw Error.overflowingVarint }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readFixed(_ size: Int) throws -> UInt64 {
        guard size <= data.endIndex - offset else { throw Error.truncated }
        var result: UInt64 = 0
        for i in 0..<size {
            result |= UInt64(data[offset + i]) << (8 * UInt64(i))
        }
        offset += size
        return result
    }
}

/// Minimal protobuf writer for install records and test fixtures.
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

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        writeVarint(UInt64(field << 3 | 1))
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
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
