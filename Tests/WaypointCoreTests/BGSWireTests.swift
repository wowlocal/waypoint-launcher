import Foundation
import Testing
@testable import WaypointCore

@Test func bgsWirePreservesUInt64AndRepeatedFields() throws {
    let body = BGSWire.number(1, UInt64.max) + BGSWire.text(2, "first") + BGSWire.text(2, "second")
    let fields = try BGSWire.decode(body)
    #expect(try BGSWire.uint(fields, 1) == UInt64.max)
    #expect(fields[2] == [.bytes(Data("first".utf8)), .bytes(Data("second".utf8))])
    #expect(throws: (any Error).self) { try BGSWire.data(fields, 2) }
}
@Test func bgsWireRejectsMalformedFrames() throws {
    let invalid: [[UInt8]] = [[0], [8] + Array(repeating: 255, count: 9) + [2], [18, 5, 97], [13, 0], [11]]
    for input in invalid { #expect(throws: (any Error).self) { try BGSWire.decode(Data(input)) } }
    #expect(throws: (any Error).self) { try BGSWire.decode(Data(repeating: 0, count: 1_048_577)) }
}
@Test func bgsWireRequiresTypedSingletons() throws {
    let fields = try BGSWire.decode(BGSWire.text(1, "not a status"))
    #expect(throws: (any Error).self) { try BGSWire.uint(fields, 1) }
    #expect(throws: (any Error).self) { try BGSWire.uint(fields, 2) }
    #expect(try BGSWire.uint(fields, 2, default: 0) == 0)
    #expect(throws: (any Error).self) { try BGSWire.uint(BGSWire.decode(BGSWire.number(1, 0) + BGSWire.number(1, 0)), 1) }
}
@Test func bgsWireDecodesOriginalServiceHash() throws {
    let fields = try BGSWire.decode(BGSWire.fixed32(11, 0xc02f8216))
    #expect(try BGSWire.uint(fields, 11) == 0xc02f8216)
}
