import Foundation
import Testing
@testable import WaypointCore

private let browserTicket="US-0123456789abcdef0123456789abcdef-123"
@Test func browserReturnAcceptsOnlyExactLocalGameReturn() {
    #expect(BrowserLoginReturn.parse("http://localhost:0/?ST=\(browserTicket)&flowTrackingId=")?.value == browserTicket)
    for url in ["https://localhost:0/?ST=\(browserTicket)", "http://example.invalid:0/?ST=\(browserTicket)",
                "http://localhost:43871/?ST=\(browserTicket)", "http://localhost:0/other?ST=\(browserTicket)",
                "http://user@localhost:0/?ST=\(browserTicket)", "http://localhost:0/?ST=\(browserTicket)#fragment",
                "http://localhost:0/?ST=\(browserTicket)&ST=\(browserTicket)", "http://localhost:0/?ST=invalid"] {
        #expect(BrowserLoginReturn.parse(url) == nil)
    }
    #expect(BrowserLoginReturn.parse(String(repeating:"a",count:8193)) == nil)
}
@Test func browserReturnPreservesOwnerBindingAndNumericBounds() {
    let url="http://localhost:0/?ST=\(browserTicket)"
    #expect(BrowserLoginReturn.parse(url,expectedOwner:"123") != nil)
    #expect(BrowserLoginReturn.parse(url,expectedOwner:"456") == nil)
    #expect(BrowserLoginReturn.parse(url.replacingOccurrences(of:"-123",with:"-0")) == nil)
    #expect(BrowserLoginReturn.parse(url.replacingOccurrences(of:"-123",with:"-18446744073709551616")) == nil)
}
