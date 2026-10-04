/// Bob Jenkins' lookup3 (`hashlittle` / `hashlittle2`), which CASC uses to
/// check its local index files. Port of the byte-at-a-time path of
/// lookup3.c, which gives the same result as the aligned fast paths.
public enum Lookup3 {
    /// `hashlittle2`: returns (primary, secondary), seeded with (pc, pb).
    public static func hashlittle2(_ bytes: [UInt8], _ pc: UInt32 = 0, _ pb: UInt32 = 0) -> (c: UInt32, b: UInt32) {
        var a: UInt32 = 0xdeadbeef &+ UInt32(truncatingIfNeeded: bytes.count) &+ pc
        var b = a
        var c = a &+ pb

        var k = 0
        var length = bytes.count
        func word(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }

        while length > 12 {
            a = a &+ word(k)
            b = b &+ word(k + 4)
            c = c &+ word(k + 8)
            mix(&a, &b, &c)
            length -= 12
            k += 12
        }

        // The last block: 0...12 bytes, zero-padded.
        if length == 0 { return (c, b) }
        var tail = [UInt8](repeating: 0, count: 12)
        for i in 0..<length { tail[i] = bytes[k + i] }
        func t(_ i: Int) -> UInt32 {
            UInt32(tail[i]) | UInt32(tail[i + 1]) << 8 | UInt32(tail[i + 2]) << 16 | UInt32(tail[i + 3]) << 24
        }
        a = a &+ t(0)
        b = b &+ t(4)
        c = c &+ t(8)
        final(&a, &b, &c)
        return (c, b)
    }

    public static func hashlittle(_ bytes: [UInt8], _ seed: UInt32 = 0) -> UInt32 {
        hashlittle2(bytes, seed, 0).c
    }

    @inline(__always) private static func rot(_ x: UInt32, _ k: UInt32) -> UInt32 { (x << k) | (x >> (32 - k)) }

    @inline(__always) private static func mix(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32) {
        a = a &- c; a ^= rot(c, 4); c = c &+ b
        b = b &- a; b ^= rot(a, 6); a = a &+ c
        c = c &- b; c ^= rot(b, 8); b = b &+ a
        a = a &- c; a ^= rot(c, 16); c = c &+ b
        b = b &- a; b ^= rot(a, 19); a = a &+ c
        c = c &- b; c ^= rot(b, 4); b = b &+ a
    }

    @inline(__always) private static func final(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32) {
        c ^= b; c = c &- rot(b, 14)
        a ^= c; a = a &- rot(c, 11)
        b ^= a; b = b &- rot(a, 25)
        c ^= b; c = c &- rot(b, 16)
        a ^= c; a = a &- rot(c, 4)
        b ^= a; b = b &- rot(a, 14)
        c ^= b; c = c &- rot(b, 24)
    }
}
