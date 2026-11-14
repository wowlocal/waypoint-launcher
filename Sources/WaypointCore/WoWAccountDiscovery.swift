import Foundation
import Network

/// Asks the game service which WoW accounts (licences) a Battle.net account
/// has, by signing in the way the game does with the web login's ticket.
/// The same sign-in also tells whose ticket it is (`profile`) and can issue
/// a ticket for another game (`ticket(for:…)`).
///
/// Listing accounts is only for the explicit "refresh accounts" action.
/// Playing never needs it: a launch without a chosen account lets the game
/// pick as it always has.
///
/// The sign-in is a game session of its own, so it isn't made while a WoW
/// client runs. Each call is one bounded attempt on a fresh connection, and
/// it returns every WoW account of the region or throws: never a partial
/// list. Nothing is stored or logged here, and a failure says nothing about
/// the saved login, which callers should leave as it is.
@MainActor
public final class WoWAccountDiscovery {
    public enum Failure: Error, LocalizedError, Equatable {
        /// Where the service turned a request down.
        public enum Stage: Sendable { case connect, logon, accountList, accountDetails, authToken }

        /// The region has no verified endpoint; see `supports`.
        case unsupported
        /// A WoW client is running. Nothing was sent.
        case gameRunning
        /// This object is already discovering.
        case busy
        /// The connection couldn't be made or dropped part-way.
        case unavailable
        case timedOut
        /// The service answered with something this code doesn't understand.
        case malformed
        /// The service answered a request with an error status.
        case rejected(Stage, status: UInt64)
        /// The session or one of its accounts belongs to another Battle.net account.
        case identityMismatch

        public var errorDescription: String? {
            switch self {
            case .unsupported: "Retrieving WoW accounts isn’t available for this region yet."
            case .gameRunning: "Close World of Warcraft before retrieving your WoW accounts, then try again."
            case .busy: "Waypoint is already retrieving your WoW accounts."
            case .unavailable: "Couldn’t reach Blizzard to retrieve your WoW accounts. Check your connection and try again."
            case .timedOut: "Blizzard took too long to return your WoW accounts. Try again."
            case .malformed: "Blizzard returned WoW account information Waypoint doesn’t understand."
            case .rejected: "Blizzard didn’t allow Waypoint to retrieve your WoW accounts."
            case .identityMismatch: "Blizzard returned WoW accounts for a different Battle.net account."
            }
        }
    }

    /// Where a region's accounts are asked for. `regionID` is how the
    /// service numbers the region in an account's handle.
    struct Endpoint: Equatable, Sendable {
        var host: String
        var port: UInt16
        var regionID: UInt64
    }

    /// Only regions whose endpoint and region number were seen working.
    nonisolated static func endpoint(for region: Region) -> Endpoint? {
        switch region {
        case .us: Endpoint(host: "us.actual.battle.net", port: 1119, regionID: 1)
        case .eu, .kr, .cn: nil
        }
    }

    public nonisolated static func supports(_ region: Region) -> Bool { endpoint(for: region) != nil }

    /// Whether any WoW client runs, from any installation: the ones in the
    /// library and copies Waypoint doesn't know about alike.
    nonisolated static func isWoWRunning(in processes: [(pid: pid_t, path: String)]) -> Bool {
        processes.contains { process in
            (process.path as NSString).lastPathComponent.hasPrefix("World of Warcraft")
        }
    }

    static let maximumLinks = 100
    static let maximumAccounts = 20
    static let maximumNameLength = 64

    private let timeout: Duration
    private let isWoWRunning: @MainActor () -> Bool
    private let makeTransport: @MainActor (Endpoint) -> any WoWAccountTransport
    private var session: Session?

    public convenience init() { self.init(timeout: .seconds(35)) }

    /// `timeout`: how long one call may take in all, connecting included.
    public convenience init(timeout: Duration) {
        self.init(timeout: timeout,
                  isWoWRunning: { Self.isWoWRunning(in: RunningProcesses.executables()) },
                  transport: { TLSTransport($0) })
    }

    /// For tests: a made-up connection, deadline and process list.
    init(timeout: Duration = .seconds(35), isWoWRunning: @escaping @MainActor () -> Bool = { false },
         transport: @escaping @MainActor (Endpoint) -> any WoWAccountTransport) {
        self.timeout = timeout
        self.isWoWRunning = isWoWRunning
        self.makeTransport = transport
    }

    /// The region's WoW accounts, sorted by name. `build` is the installed
    /// game's build number. Throws `CancellationError` when cancelled, by
    /// `cancel()` or by the task.
    public func discover(token: LoginToken, build: UInt64, region: Region) async throws -> [WoWGameAccount] {
        try await withSession(token: token, build: build, region: region) { try await $0.accounts() }
    }

    /// Whose ticket `token` is, as the game service says once it signed in
    /// with it: proof that the ticket works, without asking for anything else.
    public func profile(token: LoginToken, build: UInt64, region: Region) async throws -> NativeAccountProfile {
        try await withSession(token: token, build: build, region: region) { session in
            guard let profile = session.profile else { throw Failure.malformed }
            return profile
        }
    }

    /// A ticket for `game`, issued for the WoW ticket's own account, so the
    /// game needs no sign-in of its own. `token` is a WoW ticket.
    public func ticket(for game: SharedSignIn, token: LoginToken, build: UInt64, region: Region) async throws -> LoginToken {
        try await withSession(token: token, build: build, region: region) { try await $0.authToken(for: game.program) }
    }

    /// A ticket for `game` from the account's saved WoW ticket, or nil
    /// whenever that can't be had: no WoW ticket of that account's, a region
    /// not tried, WoW running, or any failure on the way. Nothing is asked of
    /// the network in the first three cases. The caller then signs in the
    /// usual way, so nil needs no explaining to anyone.
    /// `build`: the WoW build to sign in with; by default the live one, asked
    /// for within 5 s, as Play waits for all this before the usual sign-in.
    public func sharedTicket(for game: SharedSignIn, from wowToken: LoginToken?, account: String, region: Region,
                             build: @MainActor (Region) async throws -> UInt64 = { try await liveBuild(region: $0, timeout: 5) })
        async -> LoginToken? {
        func skip(_ reason: String, _ error: (any Error)? = nil) -> LoginToken? {
            var fields: [String: Any] = ["codename": game.codename, "reason": reason]
            if let error { fields["error"] = error }
            Log.info(.auth, "shared_sign_in_skipped", nil, fields)
            return nil
        }
        guard let wowToken, wowToken.accountID == account else { return skip("no_wow_login") }
        guard Self.supports(region) else { return skip("region") }
        guard !isWoWRunning() else { return skip("wow_running") }
        do {
            let issued = try await ticket(for: game, token: wowToken, build: build(region), region: region)
            guard issued.accountID == account else { return skip("other_account") }
            return issued
        } catch {
            return skip(error is CancellationError ? "cancelled" : "failed", error)
        }
    }

    /// Signs in on a fresh connection, runs `operation` on it, and closes it.
    private func withSession<T>(token: LoginToken, build: UInt64, region: Region,
                                _ operation: @MainActor (Session) async throws -> T) async throws -> T {
        guard let endpoint = Self.endpoint(for: region) else { throw Failure.unsupported }
        guard let owner = UInt64(token.accountID), owner > 0 else { throw Failure.identityMismatch }
        guard build > 0 else { throw Failure.unavailable }
        guard session == nil else { throw Failure.busy }
        try Task.checkCancellation()
        guard !isWoWRunning() else { throw Failure.gameRunning }

        let session = Session(transport: makeTransport(endpoint), owner: owner, regionID: endpoint.regionID)
        self.session = session
        let deadline = Task { [timeout] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            session.end(.timedOut)
        }
        defer {
            deadline.cancel()
            session.end(.finished)
            self.session = nil
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await session.signIn(token: token, build: build, isWoWRunning: isWoWRunning)
                return try await operation(session)
            } onCancel: {
                Task { @MainActor in session.end(.cancelled) }
            }
            // Cancelled or timed out just as the last reply came in.
            try Task.checkCancellation()
            if session.ending != nil { throw CancellationError() }
            return result
        } catch {
            throw session.failure(for: error)
        }
    }

    /// Stops the discovery in progress, if any; it throws `CancellationError`.
    public func cancel() { session?.end(.cancelled) }
}

/// The connection under a discovery, so tests can play the server.
/// `cancel` must make a waiting `connect`, `send` or `read` throw.
@MainActor
protocol WoWAccountTransport: AnyObject {
    func connect() async throws
    func send(_ data: Data) async throws
    /// At least one byte and at most `maximum`.
    func read(maximum: Int) async throws -> Data
    func cancel()
}

// MARK: - One attempt

/// One connection's conversation: connect and sign in, then one request.
@MainActor
private final class Session {
    typealias Failure = WoWAccountDiscovery.Failure
    typealias Wire = WoWAccountWire
    enum Ending { case finished, cancelled, timedOut }

    static let maximumFrames = 100
    static let maximumBytes = 4 * 1_048_576

    private let transport: any WoWAccountTransport
    private let owner: UInt64
    private let regionID: UInt64
    private var nextToken: UInt64 = 1
    private var frames = 0
    private var bytes = 0
    private var loggedOn = false
    /// Whose session this is, from the logon's outcome.
    private(set) var profile: NativeAccountProfile?
    /// Why the connection was closed, once it was. The first reason stays.
    private(set) var ending: Ending?

    init(transport: any WoWAccountTransport, owner: UInt64, regionID: UInt64) {
        self.transport = transport
        self.owner = owner
        self.regionID = regionID
    }

    func end(_ reason: Ending) {
        guard ending == nil else { return }
        ending = reason
        transport.cancel()
    }

    /// The error to report for one thrown while running: closing the
    /// connection makes whatever was waiting fail in its own way.
    func failure(for error: any Error) -> any Error {
        switch ending {
        case .timedOut: return Failure.timedOut
        case .cancelled: return CancellationError()
        case .finished, nil: break
        }
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let failure = error as? Failure { return failure }
        if error is Wire.Failure { return Failure.malformed }
        return Failure.unavailable
    }

    func signIn(token: LoginToken, build: UInt64, isWoWRunning: @MainActor () -> Bool) async throws {
        try await transport.connect()
        // Connecting takes a while; the game may have been started meanwhile.
        guard !isWoWRunning() else { throw Failure.gameRunning }

        try await send(Wire.frame(method: 1, token: 0, body: Wire.connectRequest))
        let (connected, _) = try await receive()
        guard connected.isResponse, connected.token == 0 else { throw Failure.malformed }
        guard connected.status == 0 else { throw Failure.rejected(.connect, status: connected.status) }

        _ = try await call(.logon, Wire.Service.authentication, method: 1,
                           body: Wire.logonRequest(token: token, build: build))
        // The request's own reply only acknowledges it. The outcome, and
        // whose session this is, comes as a notification.
        while !loggedOn {
            let (header, body) = try await receive()
            try notification(header, body)
        }
    }

    /// The signed-in account's WoW accounts in the session's region.
    func accounts() async throws -> [WoWGameAccount] {
        let list = try await call(.accountList, Wire.Service.account, method: 108)
        var seen = Set<[UInt64]>()
        var handles: [Wire.Handle] = []
        for handle in try Wire.handles(inAccountList: list, maximum: WoWAccountDiscovery.maximumLinks) {
            guard seen.insert([handle.id, handle.program, handle.region]).inserted else { throw Failure.malformed }
            if handle.program == Wire.program, handle.region == regionID { handles.append(handle) }
        }
        guard handles.count <= WoWAccountDiscovery.maximumAccounts else { throw Failure.malformed }

        var accounts: [(id: UInt64, name: String)] = []
        for handle in handles {
            let reply = try await call(.accountDetails, Wire.Service.account, method: 201,
                                       body: Wire.accountDetailsRequest(handle: handle.raw))
            let details = try Wire.accountDetails(reply)
            // The list came from this session, but check each account anyway.
            guard details.owner == owner else { throw Failure.identityMismatch }
            accounts.append((handle.id, try Self.name(details.name)))
        }
        return accounts
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            .map { WoWGameAccount(id: String($0.id), name: $0.name) }
    }

    /// A ticket to `program` for the signed-in account, and no one else's.
    func authToken(for program: UInt64) async throws -> LoginToken {
        let reply = try await call(.authToken, Wire.Service.authentication, method: 3,
                                   body: Wire.authTokenRequest(program: program))
        let issued = try Wire.authToken(reply)
        guard issued.accountID == String(owner) else { throw Failure.identityMismatch }
        return issued
    }

    /// An account's name as text fit to show and to hand to the game: one
    /// short line with no control or invisible formatting characters.
    private static func name(_ data: Data) throws -> String {
        guard data.count <= 4 * WoWAccountDiscovery.maximumNameLength,
              let text = String(data: data, encoding: .utf8) else { throw Failure.malformed }
        // This is a launch identifier, so don't normalize it into another name.
        guard WoWGameAccount.isValidName(text),
              !text.unicodeScalars.contains(where: CharacterSet.illegalCharacters.contains) else { throw Failure.malformed }
        return text
    }

    // MARK: Frames

    private func send(_ frame: Data) async throws {
        try Task.checkCancellation()
        guard ending == nil else { throw CancellationError() }
        try await transport.send(frame)
    }

    private func exact(_ count: Int) async throws -> Data {
        bytes += count
        guard bytes <= Self.maximumBytes else { throw Wire.Failure.oversized }
        var result = Data(capacity: count)
        while result.count < count {
            try Task.checkCancellation()
            guard ending == nil else { throw CancellationError() }
            let chunk = try await transport.read(maximum: count - result.count)
            // An empty read is the server closing the connection.
            guard !chunk.isEmpty, chunk.count <= count - result.count else { throw Failure.unavailable }
            result += chunk
        }
        return result
    }

    private func receive() async throws -> (Wire.Header, Data) {
        frames += 1
        guard frames <= Self.maximumFrames else { throw Wire.Failure.oversized }
        let length = try Wire.headerLength(await exact(2))
        let header = try Wire.Header(await exact(length))
        return (header, try await exact(header.size))
    }

    /// Sends a request and waits for its reply, taking the notifications
    /// that arrive in between.
    private func call(_ stage: Failure.Stage, _ service: UInt32, method: UInt64, body: Data = Data()) async throws -> Data {
        let token = nextToken
        nextToken += 1
        try await send(Wire.frame(method: method, token: token, hash: service, body: body))
        while true {
            let (header, reply) = try await receive()
            guard header.isResponse else {
                try notification(header, reply)
                continue
            }
            // Requests go one at a time, so any other reply is out of place.
            guard header.token == token else { throw Failure.malformed }
            guard header.status == 0 else { throw Failure.rejected(stage, status: header.status) }
            return reply
        }
    }

    /// What the service tells us unasked. None of these wants an answer, and
    /// nothing is ever sent back; anything else, such as a challenge to
    /// answer, ends the attempt.
    private func notification(_ header: Wire.Header, _ body: Data) throws {
        guard let hash = header.serviceHash,
              hash == Wire.Service.authenticationListener || hash == Wire.Service.authenticationListenerNameHash
        else { throw Failure.malformed }
        switch header.method & 0x3fff_ffff {
        case 1: // The logon's outcome.
            let result = try Wire.Message(body)
            let status = try result.uint(1, default: 0)
            guard status == 0 else { throw Failure.rejected(.logon, status: status) }
            let record = try result.message(2)
            guard try record.uint(1) == owner else { throw Failure.identityMismatch }
            profile = NativeAccountProfile(accountID: String(owner), record: record)
            loggedOn = true
        case 2: // Session state. Nothing in it is used, so whatever it holds
            // is skipped, as long as it is well-formed and within bounds.
            _ = try Wire.Message(body)
        case 3:
            guard body.isEmpty else { throw Failure.malformed }
        default:
            throw Failure.malformed
        }
    }
}

// MARK: - TLS

/// The real connection: TLS with the system's ordinary certificate checks.
@MainActor
private final class TLSTransport: WoWAccountTransport {
    private let connection: NWConnection
    private var ready: CheckedContinuation<Void, any Error>?
    private var closed = false

    init(_ endpoint: WoWAccountDiscovery.Endpoint) {
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                  port: NWEndpoint.Port(rawValue: endpoint.port) ?? 1119, using: .tls)
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        // Also fails a send or read in flight.
        connection.cancel()
        ready?.resume(throwing: CancellationError())
        ready = nil
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard !closed else { continuation.resume(throwing: CancellationError()); return }
            ready = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let pending = self.ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        pending.resume()
                    // Waiting means no route right now. The refresh is one
                    // the user asked for and can repeat; don't sit it out.
                    case .failed, .cancelled, .waiting:
                        self.ready = nil
                        pending.resume(throwing: WoWAccountDiscovery.Failure.unavailable)
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: WoWAccountDiscovery.Failure.unavailable) }
                else { continuation.resume() }
            })
        }
    }

    func read(maximum: Int) async throws -> Data {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                guard error == nil, let data, !data.isEmpty else {
                    continuation.resume(throwing: WoWAccountDiscovery.Failure.unavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
