import Foundation
import Testing
@testable import WaypointCore

// Everything here is made up: the server is a script of bytes, and the
// ticket, ids and names belong to nobody. The frames are spelled out with
// the small encoder below instead of the code under test, so a mistake in
// one doesn't hide in the other.

private func varint(_ value: UInt64) -> Data {
    var value = value, out = Data()
    while value >= 0x80 { out.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
    out.append(UInt8(value))
    return out
}
private func number(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
private func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
private func text(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
private func fixed32(_ field: Int, _ value: UInt32) -> Data {
    varint(UInt64(field << 3 | 5)) + Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
private func framed(_ header: Data, _ body: Data = Data()) -> Data {
    Data([UInt8(header.count >> 8), UInt8(header.count & 0xff)]) + header + body
}

private let wow: UInt64 = 5_730_135
private let authentication: UInt32 = 0xc02f_8216
private let authenticationListener: UInt32 = 0x9da8_116b
private let authenticationListenerNameHash: UInt32 = 0xecb8_b826
private let accountService: UInt32 = 0x22dc_2464
private let owner: UInt64 = 123
private let ticket = LoginToken("US-0123456789abcdef0123456789abcdef-123")!

/// A reply to the request with `token`.
private func reply(_ token: UInt64, status: UInt64 = 0, _ body: Data = Data()) -> Data {
    var header = number(1, 254) + number(3, token) + number(5, UInt64(body.count))
    if status != 0 { header += number(6, status) }
    return framed(header, body)
}
/// Something the server says unasked.
private func notice(_ hash: UInt32, method: UInt64, _ body: Data = Data()) -> Data {
    framed(number(1, 0) + number(2, method) + number(3, 99) + number(5, UInt64(body.count)) + fixed32(11, hash), body)
}
private func logonComplete(owner: UInt64 = owner, status: UInt64 = 0) -> Data {
    notice(authenticationListener, method: 1,
           (status == 0 ? Data() : number(1, status)) + bytes(2, number(1, owner)))
}
private func handle(_ id: UInt64, program: UInt64 = wow, region: UInt64 = 1) -> Data {
    number(1, id) + number(2, program) + number(3, region)
}
private func accountList(_ token: UInt64, _ handles: [Data]) -> Data {
    reply(token, bytes(1, handles.map { bytes(1, $0) }.reduce(Data(), +)))
}
private func details(_ token: UInt64, owner: UInt64 = owner, name: Data) -> Data {
    reply(token, bytes(1, number(1, owner) + bytes(2, name)))
}
private func details(_ token: UInt64, owner: UInt64 = owner, _ name: String) -> Data {
    details(token, owner: owner, name: Data(name.utf8))
}

/// Connect and logon, up to the point the account list is asked for.
private let signedIn = [reply(0), reply(1), logonComplete()]
/// A whole conversation for an account with one WoW licence.
private let oneAccount = signedIn + [accountList(2, [handle(456)]), details(3, "WoW1")]

/// Plays the server: hands out `input` a few bytes at a time and keeps what
/// was sent. Out of input, it hangs up, or waits forever if told to stall.
@MainActor
private final class ScriptedServer: WoWAccountTransport {
    var input: Data
    var stalls = false
    var chunk = 3
    var failsConnect = false
    var failsSend: Int?
    var onConnect: () -> Void = {}
    private(set) var connects = 0
    private(set) var sent: [Data] = []
    private(set) var cancelled = false
    private(set) var pending: CheckedContinuation<Data, any Error>?

    struct HungUp: Error {}

    init(_ frames: [Data] = []) { input = frames.reduce(Data(), +) }

    func connect() async throws {
        connects += 1
        onConnect()
        if cancelled { throw CancellationError() }
        if failsConnect { throw HungUp() }
    }
    func send(_ data: Data) async throws {
        if cancelled { throw CancellationError() }
        sent.append(data)
        if sent.count == failsSend { throw HungUp() }
    }
    func read(maximum: Int) async throws -> Data {
        if cancelled { throw CancellationError() }
        if input.isEmpty {
            guard stalls else { throw HungUp() }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        // Chunks ignore where frames begin and end.
        let part = Data(input.prefix(min(maximum, chunk)))
        input.removeFirst(part.count)
        return part
    }
    func cancel() {
        cancelled = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}

@MainActor
private func discovery(_ server: ScriptedServer, timeout: Duration = .seconds(30)) -> WoWAccountDiscovery {
    WoWAccountDiscovery(timeout: timeout, transport: { _ in server })
}
@MainActor
private func discover(_ frames: [Data]) async throws -> [WoWGameAccount] {
    try await discovery(ScriptedServer(frames)).discover(token: ticket, build: 70938, region: .us)
}
/// The failure a conversation ends in, and the server it was held with.
@MainActor
private func failure(_ frames: [Data]) async -> (WoWAccountDiscovery.Failure?, ScriptedServer) {
    let server = ScriptedServer(frames)
    do {
        let accounts = try await discovery(server).discover(token: ticket, build: 70938, region: .us)
        Issue.record("Discovery returned \(accounts.count) accounts")
        return (nil, server)
    } catch {
        #expect(server.cancelled)
        return (error as? WoWAccountDiscovery.Failure, server)
    }
}

// MARK: The conversation

@Test @MainActor func bothV2AuthenticationListenerHashesAreAccepted() async throws {
    for hash in [authenticationListener, authenticationListenerNameHash] {
        let messages = [reply(0), reply(1), notice(hash, method: 1, bytes(2, number(1, owner))),
                        accountList(2, [handle(456)]), details(3, "WoW1")]
        #expect(try await discover(messages) == [WoWGameAccount(id: "456", name: "WoW1")])
    }
}

@Test @MainActor func discoveryListsTheRegionsWoWAccountsByName() async throws {
    let server = ScriptedServer(signedIn + [
        accountList(2, [handle(30), handle(7, program: 0x4865726f), handle(8, region: 2), handle(10), handle(20)]),
        // Session state may arrive at any time and isn't answered.
        notice(authenticationListener, method: 2, bytes(1, number(1, 5))),
        details(3, "WoW10"), notice(authenticationListenerNameHash, method: 3), details(4, "WoW2"), details(5, "WoW10"),
    ])
    let accounts = try await discovery(server).discover(token: ticket, build: 70938, region: .us)
    // Other games and regions are left out; equal names keep a fixed order.
    #expect(accounts == [WoWGameAccount(id: "10", name: "WoW2"), WoWGameAccount(id: "20", name: "WoW10"),
                         WoWGameAccount(id: "30", name: "WoW10")])
    #expect(server.cancelled)
    #expect(server.connects == 1)

    // Connect, logon, the list, then one request per WoW account: nothing else.
    #expect(server.sent.count == 6)
    #expect(server.sent[0] == Data([0, 8, 0x08, 0, 0x10, 1, 0x18, 0, 0x28, 2, 0x18, 1]))
    let logon = number(1, wow) + text(2, "Mc64") + text(3, "enUS") + number(4, 70938) + bytes(10, text(1, ticket.value))
    #expect(server.sent[1] == framed(number(1, 0) + number(2, 1) + number(3, 1) + number(5, UInt64(logon.count))
                                     + fixed32(11, authentication), logon))
    #expect(server.sent[2] == framed(number(1, 0) + number(2, 108) + number(3, 2) + number(5, 0) + fixed32(11, accountService)))
    for (index, id) in [UInt64(30), 10, 20].enumerated() {
        let request = bytes(1, handle(id))
        #expect(server.sent[3 + index] == framed(number(1, 0) + number(2, 201) + number(3, UInt64(3 + index))
                                                 + number(5, UInt64(request.count)) + fixed32(11, accountService), request))
    }
    // The ticket goes out once, in the logon.
    #expect(server.sent.filter { $0.range(of: Data(ticket.value.utf8)) != nil }.count == 1)
}

@Test @MainActor func discoveryOfAnAccountWithoutWoWIsEmptyNotAFailure() async throws {
    #expect(try await discover(signedIn + [accountList(2, [handle(7, program: 0x4865726f)])]).isEmpty)
}

@Test @MainActor func discoveryIsOnlyOfferedWhereItWasSeenWorking() async {
    #expect(WoWAccountDiscovery.supports(.us))
    for region in Region.allCases where region != .us {
        #expect(!WoWAccountDiscovery.supports(region))
        var connections = 0
        let discovery = WoWAccountDiscovery(transport: { _ in connections += 1; return ScriptedServer(oneAccount) })
        await #expect(throws: WoWAccountDiscovery.Failure.unsupported) {
            try await discovery.discover(token: ticket, build: 70938, region: region)
        }
        #expect(connections == 0)
    }
    #expect(WoWAccountDiscovery.endpoint(for: .us)
            == WoWAccountDiscovery.Endpoint(host: "us.actual.battle.net", port: 1119, regionID: 1))
}

// MARK: A running game

@MainActor
private final class Game {
    var running: Bool
    init(running: Bool) { self.running = running }
}

@Test func anyWoWClientCountsAsRunning() {
    func running(_ path: String) -> Bool { WoWAccountDiscovery.isWoWRunning(in: [(1, "/sbin/launchd"), (500, path)]) }
    #expect(running("/Applications/World of Warcraft/_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft"))
    #expect(running("/Volumes/Games/Elsewhere/_classic_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic"))
    #expect(!running("/Applications/World of Warcraft/_retail_/Utils/Helper"))
    #expect(!running("/Applications/Overwatch.app/Contents/MacOS/Overwatch"))
    #expect(!WoWAccountDiscovery.isWoWRunning(in: []))
}

@Test @MainActor func discoveryDoesNotConnectWhileWoWRuns() async throws {
    let game = Game(running: true)
    var connections = 0
    let server = ScriptedServer(oneAccount)
    let discovery = WoWAccountDiscovery(isWoWRunning: { game.running }, transport: { _ in connections += 1; return server })
    await #expect(throws: WoWAccountDiscovery.Failure.gameRunning) {
        try await discovery.discover(token: ticket, build: 70938, region: .us)
    }
    #expect(connections == 0)
    // The check is made again for each attempt.
    game.running = false
    #expect(try await discovery.discover(token: ticket, build: 70938, region: .us).map(\.name) == ["WoW1"])
    #expect(connections == 1)
}

@Test @MainActor func discoverySendsNothingWhenWoWStartsWhileConnecting() async {
    let game = Game(running: false)
    let server = ScriptedServer(oneAccount)
    server.onConnect = { game.running = true }
    let discovery = WoWAccountDiscovery(isWoWRunning: { game.running }, transport: { _ in server })
    await #expect(throws: WoWAccountDiscovery.Failure.gameRunning) {
        try await discovery.discover(token: ticket, build: 70938, region: .us)
    }
    #expect(server.sent.isEmpty)
    #expect(server.cancelled)
}

// MARK: Connections that fail

@Test @MainActor func aConnectionLostAnywhereGivesNoListAndARetryStartsAfresh() async throws {
    let frames = signedIn + [accountList(2, [handle(456), handle(457)]), details(3, "WoW1"), details(4, "WoW2")]
    let complete = frames.reduce(Data(), +)
    var servers: [ScriptedServer] = []
    let discovery = WoWAccountDiscovery(transport: { _ in servers.removeFirst() })
    // Hang up after every possible number of bytes, the last one included.
    for cut in 0..<complete.count {
        let server = ScriptedServer([complete.prefix(cut)])
        server.chunk = 1 + cut % 5
        servers = [server]
        await #expect(throws: WoWAccountDiscovery.Failure.unavailable) {
            try await discovery.discover(token: ticket, build: 70938, region: .us)
        }
        #expect(server.cancelled)
    }
    servers = [ScriptedServer(frames)]
    #expect(try await discovery.discover(token: ticket, build: 70938, region: .us).map(\.name) == ["WoW1", "WoW2"])
}

@Test @MainActor func failedConnectsAndSendsCloseTheConnection() async {
    let refused = ScriptedServer(oneAccount)
    refused.failsConnect = true
    await #expect(throws: WoWAccountDiscovery.Failure.unavailable) {
        try await discovery(refused).discover(token: ticket, build: 70938, region: .us)
    }
    #expect(refused.cancelled && refused.sent.isEmpty)

    for send in 1...4 {
        let server = ScriptedServer(oneAccount)
        server.failsSend = send
        await #expect(throws: WoWAccountDiscovery.Failure.unavailable) {
            try await discovery(server).discover(token: ticket, build: 70938, region: .us)
        }
        #expect(server.cancelled && server.sent.count == send)
    }
}

@Test @MainActor func aStalledServerRunsIntoTheDeadline() async throws {
    // Stalled before the first reply, and in the middle of the last one.
    for frames in [[], [oneAccount.reduce(Data(), +).dropLast(1)]] {
        let server = ScriptedServer(frames)
        server.stalls = true
        let discovery = discovery(server, timeout: .milliseconds(30))
        await #expect(throws: WoWAccountDiscovery.Failure.timedOut) {
            try await discovery.discover(token: ticket, build: 70938, region: .us)
        }
        #expect(server.cancelled && server.pending == nil)
    }
}

@Test @MainActor func cancellingClosesTheConnectionAndTheNextAttemptWorks() async throws {
    for byTask in [true, false] {
        var servers = [ScriptedServer(signedIn), ScriptedServer(oneAccount)]
        let stalled = servers[0]
        stalled.stalls = true
        let discovery = WoWAccountDiscovery(transport: { _ in servers.removeFirst() })
        let task = Task { try await discovery.discover(token: ticket, build: 70938, region: .us) }
        while stalled.pending == nil { await Task.yield() }

        // One attempt at a time, and the second doesn't disturb the first.
        await #expect(throws: WoWAccountDiscovery.Failure.busy) {
            try await discovery.discover(token: ticket, build: 70938, region: .us)
        }
        #expect(!stalled.cancelled && servers.count == 1)

        if byTask { task.cancel() } else { discovery.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stalled.cancelled && stalled.pending == nil)
        // Signed in but never asked for details: nothing came back half-done.
        #expect(stalled.sent.count == 3)

        #expect(try await discovery.discover(token: ticket, build: 70938, region: .us).map(\.name) == ["WoW1"])
        // Cancelling with nothing in progress does nothing.
        discovery.cancel()
    }
}

@Test @MainActor func aTaskCancelledBeforehandNeverConnects() async {
    var connections = 0
    let discovery = WoWAccountDiscovery(transport: { _ in connections += 1; return ScriptedServer(oneAccount) })
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await discovery.discover(token: ticket, build: 70938, region: .us)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connections == 0)
}

// MARK: Whose accounts

@Test @MainActor func aSessionForAnotherBattleNetAccountIsRefused() async {
    let (error, server) = await failure([reply(0), reply(1), logonComplete(owner: 999),
                                         accountList(2, [handle(456)]), details(3, owner: 999, "Theirs")])
    #expect(error == .identityMismatch)
    // Nothing was asked of the other account's session.
    #expect(server.sent.count == 2)
}

@Test @MainActor func everyAccountsOwnerIsCheckedNotJustTheSessions() async {
    let (error, _) = await failure(signedIn + [accountList(2, [handle(456), handle(457)]),
                                               details(3, "WoW1"), details(4, owner: 999, "Theirs")])
    #expect(error == .identityMismatch)
}

@Test @MainActor func aTicketWithoutAnOwnerIsNotUsed() async {
    var connections = 0
    let discovery = WoWAccountDiscovery(transport: { _ in connections += 1; return ScriptedServer(oneAccount) })
    for value in ["US-0123456789abcdef0123456789abcdef-0", "US-0123456789abcdef0123456789abcdef-99999999999999999999999"] {
        await #expect(throws: WoWAccountDiscovery.Failure.identityMismatch) {
            try await discovery.discover(token: LoginToken(value)!, build: 70938, region: .us)
        }
    }
    await #expect(throws: WoWAccountDiscovery.Failure.unavailable) {
        try await discovery.discover(token: ticket, build: 0, region: .us)
    }
    #expect(connections == 0)
}

// MARK: Refusals

@Test @MainActor func anErrorStatusEndsTheAttemptAtItsStage() async {
    let list = accountList(2, [handle(456), handle(457)])
    let cases: [([Data], WoWAccountDiscovery.Failure, sent: Int)] = [
        ([reply(0, status: 3)] + oneAccount.dropFirst(), .rejected(.connect, status: 3), 1),
        ([reply(0), reply(1, status: 5)] + oneAccount.dropFirst(2), .rejected(.logon, status: 5), 2),
        ([reply(0), reply(1), logonComplete(status: 12)] + oneAccount.dropFirst(3), .rejected(.logon, status: 12), 2),
        (signedIn + [reply(2, status: 7)], .rejected(.accountList, status: 7), 3),
        // The first account resolved; the second being refused still means no list.
        (signedIn + [list, details(3, "WoW1"), reply(4, status: 9)], .rejected(.accountDetails, status: 9), 5),
    ]
    for (frames, expected, sent) in cases {
        let (error, server) = await failure(frames)
        #expect(error == expected)
        #expect(server.sent.count == sent)
    }
}

@Test @MainActor func aChallengeOrAnythingElseUnexpectedIsNeverAnswered() async {
    let unexpected = [
        notice(authenticationListenerNameHash, method: 4, text(1, "prove it")), // a method that wants an answer
        notice(0x1234_5678, method: 1, bytes(2, number(1, owner))), // a service that was never asked
        framed(number(1, 0) + number(2, 1) + number(3, 9) + number(5, 0)), // no service at all
        notice(authenticationListenerNameHash, method: 3, number(1, 1)),
        notice(authenticationListener, method: 2, bytes(1, text(1, "not a number"))),
        reply(7), // a reply to a request that wasn't made
    ]
    for frame in unexpected {
        // While waiting for the logon's outcome, and while waiting for a reply.
        for frames in [[reply(0), reply(1), frame, logonComplete()] + oneAccount.dropFirst(3),
                       signedIn + [frame] + oneAccount.dropFirst(3)] {
            let (error, server) = await failure(frames)
            #expect(error == .malformed)
            #expect(server.sent.count <= 3)
        }
    }
}

// MARK: Bounds

@Test @MainActor func oversizedAndMalformedFramesEndTheAttempt() async {
    let bad: [Data] = [
        Data([0, 0]), // no header
        Data([0x20, 0x01]) + Data(repeating: 0, count: 8193), // header over 8 KB
        framed(number(1, 254) + number(3, 2) + number(5, 1_048_577)), // body over 1 MB
        framed(number(1, 254) + number(1, 254) + number(3, 2) + number(5, 0)), // a field twice
        framed(number(3, 2) + number(5, 0)), // no service
        framed(text(1, "254") + number(3, 2) + number(5, 0)), // wrong type
        framed(Data([0x08])), // truncated
        framed(number(1, 254) + number(3, 2) + number(5, 0) + number(0, 1)), // field 0
        reply(2, Data([0x0a, 0x05, 0x01])), // list cut short inside
        reply(2), // no list at all
        reply(2, bytes(1, number(1, 456))), // links that aren't handles
        reply(2, bytes(1, bytes(1, number(1, 456) + number(2, wow)))), // handle without a region
        reply(2, bytes(1, bytes(1, handle(0)))),
        reply(2, bytes(1, bytes(1, handle(456, region: 1 << 32)))),
    ]
    for frame in bad {
        let (error, _) = await failure(signedIn + [frame])
        #expect(error == .malformed)
    }
}

@Test @MainActor func countsAreBounded() async {
    // Notifications without end.
    let chatter = Array(repeating: notice(authenticationListener, method: 2, bytes(1, number(1, 1))), count: 200)
    #expect(await failure([reply(0), reply(1)] + chatter + [logonComplete()]).0 == .malformed)
    #expect(await failure(signedIn + chatter).0 == .malformed)

    // 100 links are read; 101 aren't.
    let others = (1...100).map { handle(UInt64($0), program: 0x4865726f) }
    #expect(await failure(signedIn + [accountList(2, others + [handle(456)])]).0 == .malformed)
    #expect((try? await discover(signedIn + [accountList(2, others)]))?.isEmpty == true)

    // 20 WoW accounts are resolved; with 21 not one is asked about.
    let twenty = (1...20).map { handle(UInt64($0)) }
    let names = (1...20).map { details(UInt64(2 + $0), "WoW\($0)") }
    #expect((try? await discover(signedIn + [accountList(2, twenty)] + names))?.count == 20)
    let (error, server) = await failure(signedIn + [accountList(2, twenty + [handle(21)])] + names)
    #expect(error == .malformed)
    #expect(server.sent.count == 3)

    // The same licence twice.
    #expect(await failure(signedIn + [accountList(2, [handle(456), handle(456)])]).0 == .malformed)

    // Many large frames in all.
    let large = notice(authenticationListener, method: 2, bytes(1, Data()) + bytes(15, Data(count: 1_000_000)))
    let server2 = ScriptedServer(signedIn + Array(repeating: large, count: 5))
    server2.chunk = 65536
    await #expect(throws: WoWAccountDiscovery.Failure.malformed) {
        try await discovery(server2).discover(token: ticket, build: 70938, region: .us)
    }
}

@Test @MainActor func accountNamesMustBeOneShortPrintableLine() async throws {
    let bad: [Data] = [
        Data(), Data("   ".utf8), Data(" WoW1".utf8), Data("WoW1 ".utf8),
        Data(ticket.value.utf8), Data("WoW\n1".utf8), Data("WoW\u{0}1".utf8), Data("WoW\u{1b}[2J".utf8),
        Data("WoW\u{202e}1".utf8), // right-to-left override
        Data("WoW\u{2028}1".utf8), // line separator
        Data([0x57, 0x6f, 0xff]), // not UTF-8
        Data(String(repeating: "W", count: 65).utf8),
    ]
    for name in bad {
        let (error, _) = await failure(signedIn + [accountList(2, [handle(456)]), details(3, name: name)])
        #expect(error == .malformed)
    }
    // A missing name, and a name sent twice.
    #expect(await failure(signedIn + [accountList(2, [handle(456)]), reply(3, bytes(1, number(1, owner)))]).0 == .malformed)
    #expect(await failure(signedIn + [accountList(2, [handle(456)]),
                                      reply(3, bytes(1, number(1, owner) + text(2, "WoW1") + text(2, "WoW2")))]).0 == .malformed)

    let longest = String(repeating: "W", count: 64)
    #expect(try await discover(signedIn + [accountList(2, [handle(456)]), details(3, longest)]).map(\.name) == [longest])
    #expect(try await discover(signedIn + [accountList(2, [handle(456)]), details(3, "Ёжик 2")]).map(\.name) == ["Ёжик 2"])
}

// MARK: The wire

@Test func wireMessagesWantEachFieldOnceWithItsType() throws {
    let message = try WoWAccountWire.Message(number(1, .max) + text(2, "first") + text(2, "second") + fixed32(11, authentication))
    #expect(try message.uint(1) == .max)
    #expect(try message.uint(11) == UInt64(authentication))
    #expect(try message.repeatedBytes(2) == [Data("first".utf8), Data("second".utf8)])
    #expect(try message.repeatedBytes(9).isEmpty)
    #expect(try message.uint(9, default: 0) == 0)
    #expect(throws: WoWAccountWire.Failure.malformed) { try message.bytes(2) }
    #expect(throws: WoWAccountWire.Failure.malformed) { try message.uint(2) }
    #expect(throws: WoWAccountWire.Failure.malformed) { try message.uint(9) }
    #expect(throws: WoWAccountWire.Failure.malformed) { try message.bytes(1) }
    #expect(throws: WoWAccountWire.Failure.malformed) { try message.repeatedBytes(1) }

    let invalid: [[UInt8]] = [[0], [8] + Array(repeating: 255, count: 9) + [2], [18, 5, 97], [13, 0], [11]]
    for input in invalid {
        #expect(throws: WoWAccountWire.Failure.malformed) { try WoWAccountWire.Message(Data(input)) }
    }
    #expect(throws: WoWAccountWire.Failure.oversized) { try WoWAccountWire.Message(Data(count: 1_048_577)) }
}

@Test func wireFramesAreBounded() throws {
    #expect(try WoWAccountWire.headerLength(Data([0x20, 0x00])) == 8192)
    #expect(throws: WoWAccountWire.Failure.oversized) { try WoWAccountWire.headerLength(Data([0x20, 0x01])) }
    #expect(throws: WoWAccountWire.Failure.malformed) { try WoWAccountWire.headerLength(Data([0, 0])) }
    #expect(throws: WoWAccountWire.Failure.oversized) {
        try WoWAccountWire.frame(method: 1, token: 1, body: Data(count: 1_048_577))
    }
    // A service hash is 32 bits, however it is spelled.
    #expect(throws: WoWAccountWire.Failure.malformed) {
        try WoWAccountWire.Header(number(1, 0) + number(3, 1) + number(11, 1 << 32))
    }
    let header = try WoWAccountWire.Header(number(1, 0) + number(2, 1) + number(3, 4) + fixed32(11, accountService) + text(40, "later addition"))
    #expect(header.serviceHash == accountService && header.token == 4 && header.size == 0 && !header.isResponse)
}
