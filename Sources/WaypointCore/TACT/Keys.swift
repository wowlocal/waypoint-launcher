import Foundation

/// A 16-byte content or encoded key held as two integers. Install plans
/// carry millions of keys (WoW lists about 3 million files), and as `Data`
/// every one would be its own heap allocation.
public struct Key16: Hashable, Comparable, Sendable {
    public var hi: UInt64
    public var lo: UInt64

    public init(hi: UInt64, lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    /// The 16 bytes at `pointer`, read big-endian so ordering matches the bytes.
    @inline(__always)
    init(_ pointer: UnsafeRawPointer) {
        hi = UInt64(bigEndian: pointer.loadUnaligned(as: UInt64.self))
        lo = UInt64(bigEndian: pointer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
    }

    /// Nil unless `data` holds at least 16 bytes.
    public init?(_ data: Data) {
        guard data.count >= 16 else { return nil }
        self = data.withUnsafeBytes { Key16($0.baseAddress!) }
    }

    public var data: Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: hi >> (56 - 8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> (56 - 8 * UInt64(i)))
        }
        return Data(bytes)
    }

    public var hex: String { String(format: "%016llx%016llx", hi, lo) }

    /// The first 9 bytes, which local storage indexes files by.
    public var prefix9: Key9 { Key9(hi: hi, lo: UInt8(truncatingIfNeeded: lo >> 56)) }

    public static func < (a: Key16, b: Key16) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }
}

/// The 9-byte key prefix of local storage's index files.
public struct Key9: Hashable, Comparable, Sendable {
    public var hi: UInt64
    public var lo: UInt8

    public init(hi: UInt64, lo: UInt8) {
        self.hi = hi
        self.lo = lo
    }

    @inline(__always)
    init(_ pointer: UnsafeRawPointer) {
        hi = UInt64(bigEndian: pointer.loadUnaligned(as: UInt64.self))
        lo = pointer.load(fromByteOffset: 8, as: UInt8.self)
    }

    /// Nil unless `data` holds at least 9 bytes.
    public init?(_ data: Data) {
        guard data.count >= 9 else { return nil }
        self = data.withUnsafeBytes { Key9($0.baseAddress!) }
    }

    public var data: Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: hi >> (56 - 8 * UInt64($0))) } + [lo])
    }

    /// Which of the 16 index files the key goes in (XOR of the bytes, nibbles folded).
    public var bucket: Int {
        var x = UInt8(truncatingIfNeeded: hi) ^ lo
        var h = hi >> 8
        for _ in 0..<7 {
            x ^= UInt8(truncatingIfNeeded: h)
            h >>= 8
        }
        return Int((x >> 4) ^ (x & 0x0F))
    }

    public static func < (a: Key9, b: Key9) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }
}

extension Array where Element: Comparable {
    /// Binary search in a sorted array.
    func sortedContains(_ value: Element) -> Bool {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low < count && self[low] == value
    }
}
