import Foundation
import Testing
@testable import WaypointCore

private let fourScore = Array("Four score and seven years ago".utf8)

/// Reference values from driver5() in Bob Jenkins' lookup3.c.
@Test func lookup3MatchesReferenceVectors() {
    #expect(Lookup3.hashlittle2([], 0, 0) == (0xdeadbeef, 0xdeadbeef))
    #expect(Lookup3.hashlittle2([], 0, 0xdeadbeef) == (0xbd5b7dde, 0xdeadbeef))
    #expect(Lookup3.hashlittle2([], 0xdeadbeef, 0xdeadbeef) == (0x9c093ccd, 0xbd5b7dde))
    #expect(Lookup3.hashlittle2(fourScore, 0, 0) == (0x17770551, 0xce7226e6))
    // driver5 prints (c, b) after seeding c=1,b=0 and then c=0,b=1.
    #expect(Lookup3.hashlittle2(fourScore, 1, 0) == (0xcd628161, 0x6cbea4b3))
    #expect(Lookup3.hashlittle2(fourScore, 0, 1) == (0xe3607cae, 0xbd371de4))
    #expect(Lookup3.hashlittle(fourScore, 0) == 0x17770551)
    #expect(Lookup3.hashlittle(fourScore, 1) == 0xcd628161)
}

private func be(_ value: UInt64, _ size: Int) -> Data {
    Data((0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
}

@Test func parsesDownloadManifestAndSelectsByTags() throws {
    func manifest(version: UInt8) -> Data {
        var d = Data("DL".utf8) + Data([version, 16, 1]) + be(3, 4) + be(2, 2)
        if version >= 2 { d += Data([1]) }
        if version >= 3 { d += Data([0, 0, 0, 0]) }
        for i: UInt8 in 1...3 {
            d += Data(repeating: i, count: 16) + be(UInt64(i) * 100, 5) + Data([i - 1]) + be(0xABCD, 4)
            if version >= 2 { d += Data([0]) }
        }
        d += Data("OSX".utf8) + Data([0]) + be(1, 2) + Data([0b1010_0000])      // entries 0, 2
        d += Data("enUS".utf8) + Data([0]) + be(3, 2) + Data([0b0110_0000])     // entries 1, 2
        return d
    }
    for version: UInt8 in 1...3 {
        let m = try DownloadManifest(manifest(version: version))
        #expect(m.entries.count == 3)
        #expect(m.entries[1] == .init(encodedKey: Data(repeating: 2, count: 16), size: 200, priority: 1))
        #expect(m.select(tagString: "OSX enUS speech?").map(\.size) == [300])
        #expect(m.select(tagString: "OSX").map(\.size) == [100, 300])
    }
}
