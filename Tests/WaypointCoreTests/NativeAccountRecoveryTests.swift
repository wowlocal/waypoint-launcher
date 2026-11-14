import Foundation
import Testing
@testable import WaypointCore

@MainActor
private final class AccountTestTransport: NativeAccountTransport {
    var input: Data
    var cancelled = false
    var pending: CheckedContinuation<Data, Error>?
    var connectFails = false
    var sendFailsAt: Int?
    var sends = 0
    var sentPackets: [Data] = []
    var stall: Bool
    init(_ input: Data = Data(), stall: Bool = false) { self.input = input; self.stall = stall }
    func connect() async throws { if connectFails { throw NativeGameAccounts.Failure.unavailable } }
    func send(_ data: Data) async throws {
        sends += 1
        sentPackets.append(data)
        if cancelled { throw CancellationError() }
        if sends == sendFailsAt { throw NativeGameAccounts.Failure.unavailable }
    }
    func read(maximum: Int) async throws -> Data {
        if cancelled { throw CancellationError() }
        if input.isEmpty {
            if stall { return try await withCheckedThrowingContinuation { pending = $0 } }
            throw NativeGameAccounts.Failure.unavailable
        }
        // Exercise fragmentation independently of message boundaries.
        let chunk = Data(input.prefix(min(maximum, 3))); input.removeFirst(chunk.count); return chunk
    }
    func cancel() { cancelled = true; pending?.resume(throwing: CancellationError()); pending = nil }
}
private func accountFrame(token: UInt64, body: Data = Data(), service: UInt64 = 254, method: UInt64? = nil, hash: UInt32? = nil) -> Data {
    var h = BGSWire.number(1, service) + BGSWire.number(3, token) + BGSWire.number(5, UInt64(body.count))
    if let method { h += BGSWire.number(2, method) }
    if let hash { h += BGSWire.fixed32(11, hash) }
    return Data([UInt8(h.count >> 8), UInt8(h.count & 255)]) + h + body
}
private func accountReplies(owner: UInt64 = 123) -> [Data] {
    let handle = BGSWire.number(1, 456) + BGSWire.number(2, 5730135) + BGSWire.number(3, 1)
    return [accountFrame(token: 0), accountFrame(token: 1),
            accountFrame(token: 99, body: BGSWire.bytes(2, BGSWire.number(1, owner)), service: 0, method: 1, hash: 0x9da8116b),
            accountFrame(token: 2, body: BGSWire.bytes(1, BGSWire.bytes(1, handle))),
            accountFrame(token: 3, body: BGSWire.bytes(1, BGSWire.number(1, owner) + BGSWire.text(2, "Test licence")))]
}
private let accountTestToken = LoginToken("US-0123456789abcdef0123456789abcdef-123")!

@Test @MainActor func nativeDiscoveryDisconnectsFailClosedAndFreshRetrySucceeds() async throws {
    let replies = accountReplies(), complete = replies.reduce(Data(), +)
    // Before connect response, during logon, before links, and mid-info reply.
    for cut in [0, replies[0].count + 1, replies.prefix(3).reduce(0) { $0 + $1.count }, complete.count - 1] {
        let broken = AccountTestTransport(Data(complete.prefix(cut)))
        do {
            _ = try await NativeGameAccounts(transport: broken).discover(token: accountTestToken, build: 70938, region: .us)
            Issue.record("Disconnected discovery returned a catalogue")
        } catch { #expect(broken.cancelled) }
    }
    let restored = AccountTestTransport(complete)
    let accounts = try await NativeGameAccounts(transport: restored).discover(token: accountTestToken, build: 70938, region: .us)
    #expect(accounts.map(\.name) == ["Test licence"])
    #expect(restored.cancelled)
}
@Test @MainActor func nativeDiscoveryRejectsWrongOwner() async {
    let transport = AccountTestTransport(accountReplies(owner: 999).reduce(Data(), +))
    do {
        _ = try await NativeGameAccounts(transport: transport).discover(token: accountTestToken, build: 70938, region: .us)
        Issue.record("Wrong-owner discovery succeeded")
    } catch NativeGameAccounts.Failure.owner { #expect(transport.cancelled) }
    catch { Issue.record("Wrong-owner discovery did not report identity mismatch") }
}
@Test @MainActor func nativeDiscoveryDeadlineClosesStalledConnection() async {
    let transport = AccountTestTransport(stall: true)
    do {
        _ = try await NativeGameAccounts(transport: transport, timeout: .milliseconds(20)).discover(token: accountTestToken, build: 70938, region: .us)
        Issue.record("Stalled connection succeeded")
    } catch { #expect(transport.cancelled); #expect(transport.pending == nil) }
}
@Test @MainActor func nativeDiscoveryCancellationClosesPendingRead() async {
    let transport = AccountTestTransport(stall: true)
    let task = Task { try await NativeGameAccounts(transport: transport).discover(token: accountTestToken, build: 70938, region: .us) }
    while transport.pending == nil { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled discovery succeeded") }
    catch { #expect(transport.cancelled); #expect(transport.pending == nil) }
}

@Test @MainActor func nativeDiscoveryConnectAndSendFailuresCloseTransport() async {
    for failConnect in [true, false] {
        let transport = AccountTestTransport(accountReplies().reduce(Data(), +))
        transport.connectFails = failConnect; transport.sendFailsAt = 2
        do {
            _ = try await NativeGameAccounts(transport: transport).discover(token: accountTestToken, build: 70938, region: .us)
            Issue.record("Failed transport returned a catalogue")
        } catch { #expect(transport.cancelled) }
    }
}
@Test @MainActor func nativeDiscoveryChecksOwnerAgainWhenResolvingNames() async {
    var replies = accountReplies()
    replies[4] = accountFrame(token: 3, body: BGSWire.bytes(1, BGSWire.number(1, 999) + BGSWire.text(2, "Other licence")))
    let transport = AccountTestTransport(replies.reduce(Data(), +))
    do {
        _ = try await NativeGameAccounts(transport: transport).discover(token: accountTestToken, build: 70938, region: .us)
        Issue.record("Wrong-owner account info returned a catalogue")
    } catch NativeGameAccounts.Failure.owner { #expect(transport.cancelled) }
    catch { Issue.record("Account-info owner mismatch was not recognized") }
}


private func nativeProfileReplies(tag: String? = "Example#1234", owner: UInt64 = 123) -> [Data] {
    var record = BGSWire.number(1, owner)
    if let tag { record += BGSWire.text(3, tag) }
    // The optional game-account field is repeated and is not read as a scalar.
    record += BGSWire.bytes(2, BGSWire.number(1, 456)) + BGSWire.bytes(2, BGSWire.number(1, 457))
    return [accountFrame(token: 0), accountFrame(token: 1),
        accountFrame(token: 99, body: BGSWire.bytes(2, record), service: 0, method: 1, hash: 0x9da8116b)]
}
@Test @MainActor func nativeProfileReturnsOwnerVerifiedBattleTagWithoutExtraRPCs() async throws {
    let transport = AccountTestTransport(nativeProfileReplies().reduce(Data(), +))
    let client = NativeGameAccounts(transport: transport)
    let profile = try await client.fetchProfile(token: accountTestToken, build: 70938, region: .us)
    #expect(profile.accountID == "123"); #expect(profile.battleTag == "Example#1234")
    #expect(client.authenticatedProfile == profile); #expect(transport.sends == 2); #expect(transport.cancelled)
}
@Test @MainActor func nativeProfileRejectsWrongOwnerBeforeReturningMetadata() async {
    let transport = AccountTestTransport(nativeProfileReplies(owner: 999).reduce(Data(), +))
    let client = NativeGameAccounts(transport: transport)
    do {
        _ = try await client.fetchProfile(token: accountTestToken, build: 70938, region: .us)
        Issue.record("Wrong-owner BattleTag was accepted")
    } catch NativeGameAccounts.Failure.owner { #expect(client.authenticatedProfile == nil); #expect(transport.cancelled) }
    catch { Issue.record("Expected account identity mismatch") }
}
@Test @MainActor func nativeProfileMissingBattleTagDoesNotRejectValidLogin() async throws {
    let transport = AccountTestTransport(nativeProfileReplies(tag: nil).reduce(Data(), +))
    let profile = try await NativeGameAccounts(transport: transport).fetchProfile(token: accountTestToken, build: 70938, region: .us)
    #expect(profile.accountID == "123"); #expect(profile.battleTag == nil); #expect(transport.cancelled)
}
@Test @MainActor func nativeDiscoveryAlsoCapturesVerifiedProfile() async throws {
    let replies = nativeProfileReplies() + Array(accountReplies().dropFirst(3))
    let transport = AccountTestTransport(replies.reduce(Data(), +)), client = NativeGameAccounts(transport: transport)
    let licences = try await client.discover(token: accountTestToken, build: 70938, region: .us)
    #expect(licences.count == 1); #expect(client.authenticatedProfile?.battleTag == "Example#1234")
    #expect(transport.sends == 4); #expect(transport.cancelled)
}
@Test func nativeProfileFiltersOptionalMetadataWithoutTrustingArbitraryStrings() {
    for tag in ["", "Example", "#1234", "Example#", "Example#abcd", "Example#12#34", "Example\n#1234", String(repeating: "x", count: 257)] {
        let record = try! BGSWire.decode(BGSWire.text(3, tag))
        #expect(NativeAccountProfile(accountID: "123", record: record).battleTag == nil)
    }
    #expect(NativeAccountProfile(accountID: "123", record: [3: [.number(123)]]).battleTag == nil)
    #expect(NativeAccountProfile(accountID: "123", record: [3: [.bytes(Data([255]))]]).battleTag == nil)
    let valid = NativeAccountProfile(accountID: "123", record: [3: [.bytes(Data("Ünicode#1234".utf8))]])
    #expect(valid.battleTag == "Ünicode#1234")
}
@Test func nativeProfileApplicationIsOwnerScopedAndKeepsEmailAndKnownNames() throws {
    var list = AccountList(); list.signedIn("123", session: .shared); list.signedIn("456", session: .fresh())
    list.setProfile("123", battleTag: nil, email: "private@example.invalid")
    let profile = NativeAccountProfile(accountID: "123", record: try BGSWire.decode(BGSWire.text(3, "Example#1234")))
    let wrongOwner = list.setNativeProfile(profile, for: "456"); #expect(!wrongOwner); #expect(list["456"]?.battleTag == nil)
    let applied = list.setNativeProfile(profile, for: "123"); #expect(applied); #expect(list["123"]?.displayName == "Example#1234")
    #expect(list["123"]?.email == "private@example.invalid")
    let missing = list.setNativeProfile(NativeAccountProfile(accountID: "123", record: [:]), for: "123"); #expect(!missing)
    #expect(list["123"]?.battleTag == "Example#1234")
    _ = list.remove("123"); let removed = list.setNativeProfile(profile, for: "123"); #expect(!removed)
}

@Test @MainActor func nativeTargetCredentialRequiresMatchingOwnerAndNeverSavesIt() async throws {
    for owner in ["123", "999"] {
        let issued = "US-fedcba9876543210fedcba9876543210-\(owner)"
        let replies = nativeProfileReplies() + [accountFrame(token: 2, body: BGSWire.text(1, issued))]
        let transport = AccountTestTransport(replies.reduce(Data(), +))
        do {
            let result = try await NativeGameAccounts(transport: transport).requestCredential(token: accountTestToken, build: 70938, region: .us)
            #expect(owner == "123"); #expect(result.accountID == "123")
        } catch NativeGameAccounts.Failure.owner { #expect(owner == "999") }
        #expect(transport.sends == 3); #expect(transport.cancelled)
        let packet = try #require(transport.sentPackets.last)
        let headerSize = Int(packet[0]) * 256 + Int(packet[1])
        let header = try BGSWire.decode(Data(packet[2..<(2 + headerSize)]))
        let body = try BGSWire.decode(Data(packet.dropFirst(2 + headerSize)))
        #expect(try BGSWire.uint(header, 2) == 3)
        #expect(try BGSWire.uint(body, 1) == 0x46656e)
    }
}
@Test @MainActor func nativeTargetCredentialRejectsWrongSourceBeforeIssuingRequest() async {
    let transport = AccountTestTransport(nativeProfileReplies(owner: 999).reduce(Data(), +))
    do {
        _ = try await NativeGameAccounts(transport: transport).requestCredential(token: accountTestToken, build: 70938, region: .us)
        Issue.record("Wrong source owner accepted")
    } catch NativeGameAccounts.Failure.owner { #expect(transport.sends == 2) }
    catch { Issue.record("Unexpected error") }
    #expect(transport.cancelled)
}

@Test @MainActor func nativeTargetValidationUsesTargetTitleAndWindowsPlatform() async throws {
    let transport = AccountTestTransport(nativeProfileReplies().reduce(Data(), +))
    try await NativeGameAccounts(transport: transport).validateCredential(token: accountTestToken, build: 123456, region: .us, target: .diabloIV)
    let packet = transport.sentPackets[1]
    let size = Int(packet[0]) * 256 + Int(packet[1])
    let body = try BGSWire.decode(Data(packet.dropFirst(2 + size)))
    #expect(try BGSWire.uint(body, 1) == 0x46656e)
    #expect(try BGSWire.data(body, 2) == Data("Wn64".utf8))
    #expect(try BGSWire.uint(body, 4) == 123456)
    #expect(transport.sends == 2); #expect(transport.cancelled)
}

@Test @MainActor func nativeHearthstoneExchangeAndValidationUseDistinctTitleAndMacPlatform() async throws {
    let issued = "US-fedcba9876543210fedcba9876543210-123"
    let exchange = AccountTestTransport((nativeProfileReplies() + [accountFrame(token: 2, body: BGSWire.text(1, issued))]).reduce(Data(), +))
    let token = try await NativeGameAccounts(transport: exchange).requestCredential(token: accountTestToken, build: 70938, region: .us, target: .hearthstone)
    let packet = try #require(exchange.sentPackets.last)
    let headerSize = Int(packet[0]) * 256 + Int(packet[1])
    #expect(try BGSWire.uint(BGSWire.decode(Data(packet.dropFirst(2 + headerSize))), 1) == 0x57544347)
    let validation = AccountTestTransport(nativeProfileReplies().reduce(Data(), +))
    try await NativeGameAccounts(transport: validation).validateCredential(token: token, build: 98765, region: .us, target: .hearthstone)
    let logon = validation.sentPackets[1], size = Int(logon[0]) * 256 + Int(logon[1])
    let body = try BGSWire.decode(Data(logon.dropFirst(2 + size)))
    #expect(try BGSWire.uint(body, 1) == 0x57544347)
    #expect(try BGSWire.data(body, 2) == Data("Mc64".utf8))
    #expect(validation.sends == 2); #expect(validation.cancelled); #expect(exchange.cancelled)
}
@Test func sharedSignInOnlyRoutesExplicitlySupportedCrossGameTargets() {
    #expect(NativeGameAccounts.CredentialTarget(sharedCodename: "WTCG") == .hearthstone)
    #expect(NativeGameAccounts.CredentialTarget(sharedCodename: "Fen") == .diabloIV)
    #expect(NativeGameAccounts.CredentialTarget(sharedCodename: "WoW") == nil)
    #expect(NativeGameAccounts.CredentialTarget(sharedCodename: "Pro") == nil)
    #expect(NativeGameAccounts.CredentialTarget.hearthstone.productCode == "hsb")
}
