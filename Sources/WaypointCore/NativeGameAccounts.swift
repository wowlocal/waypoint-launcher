import Foundation
import Network

/// Uses the saved game authorization, never website cookies or a second login.
/// A separate normal game-service session: do not run while a WoW client is open.
@MainActor
public final class NativeGameAccounts {
    public enum Failure: Error, LocalizedError {
        case unavailable, rejected(UInt64), owner, unsupported, gameRunning
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t retrieve your WoW accounts. Check your connection and try again."
            case .rejected: "Blizzard couldn’t authorize account discovery. Your saved account selection has been kept."
            case .owner: "Blizzard returned a different account identity. No account choices were changed."
            case .gameRunning: "Close World of Warcraft before retrieving accounts, then try again."
            case .unsupported: "Background account discovery is currently tested for Americas only."
            }
        }
    }
    public private(set) var authenticatedProfile: NativeAccountProfile?
    private typealias W = BGSWire
    private let transport: any NativeAccountTransport
    private let timeout: Duration
    private var sequence: UInt64 = 1
    private var frames = 0
    private var loggedIn = false
    private var expectedOwner: UInt64 = 0
    private var deadlineTask: Task<Void, Never>?
    private var closed = false

    public convenience init() { self.init(transport: TLSAccountTransport()) }
    init(transport: any NativeAccountTransport, timeout: Duration = .seconds(35)) {
        self.transport = transport; self.timeout = timeout
    }
    public func cancel() { closed = true; transport.cancel() }
    private func withAuthenticatedSession<T>(token: LoginToken, build: UInt64, region: Region, titleID: UInt64 = 0x576f57, platform: String = "Mc64", operation: () async throws -> T) async throws -> T {
        guard region == .us else { throw Failure.unsupported }
        guard let owner = UInt64(token.accountID), owner > 0, build > 0 else { throw Failure.owner }
        expectedOwner = owner
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: self?.timeout ?? .seconds(35)) } catch { return }
            self?.cancel()
        }
        defer { deadlineTask?.cancel(); cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await transport.connect()
            try await send(service: 0, method: 1, token: 0, body: W.number(3, 1))
            let (header, _) = try await receive()
            guard try W.uint(header, 1) == 254, try W.uint(header, 3) == 0,
                  try W.uint(header, 6, default: 0) == 0 else { throw Failure.unavailable }
            let request = W.number(1, titleID) + W.text(2, platform) + W.text(3, "enUS")
                + W.number(4, build) + W.bytes(10, W.text(1, token.value))
            _ = try await call(hash: 0xc02f8216, method: 1, body: request)
            while !loggedIn {
                let (header, body) = try await receive()
                try notification(header, body)
            }
            return try await operation()
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
    }

    /// Retrieves only the verified identity; no licence/social/session RPCs.
    public func fetchProfile(token: LoginToken, build: UInt64, region: Region) async throws -> NativeAccountProfile {
        try await withAuthenticatedSession(token: token, build: build, region: region) {
            guard let profile = authenticatedProfile else { throw Failure.unavailable }
            return profile
        }
    }

    /// Owner-verified v2 GenerateAuthToken request for supported cross-game sign-in.
    /// Schema/method verified against installed Forever static descriptors.
    public enum CredentialTarget: Sendable {
        case worldOfWarcraft, diabloIV, hearthstone
        var titleID: UInt64 {
            switch self { case .worldOfWarcraft: 0x576f57; case .diabloIV: 0x46656e; case .hearthstone: 0x57544347 }
        }
        public var displayName: String {
            switch self { case .worldOfWarcraft: "World of Warcraft"; case .diabloIV: "Diablo IV"; case .hearthstone: "Hearthstone" }
        }
        public var codename: String {
            switch self { case .worldOfWarcraft: "WoW"; case .diabloIV: "Fen"; case .hearthstone: "WTCG" }
        }
        public var productCode: String {
            switch self { case .worldOfWarcraft: "wowf"; case .diabloIV: "fenris"; case .hearthstone: "hsb" }
        }
        var platform: String { self == .diabloIV ? "Wn64" : "Mc64" }
        /// Only these cross-game routes have been enabled and validated.
        public init?(sharedCodename: String) {
            switch sharedCodename { case "Fen": self = .diabloIV; case "WTCG": self = .hearthstone; default: return nil }
        }
    }
    public func requestCredential(token: LoginToken, build: UInt64, region: Region,
                                  target: CredentialTarget = .diabloIV) async throws -> LoginToken {
        try await withAuthenticatedSession(token: token, build: build, region: region) {
            let response = try await call(hash: 0xc02f8216, method: 3, body: W.number(1, target.titleID))
            let data = try W.data(W.decode(response), 1)
            guard data.count <= 256, let text = String(data: data, encoding: .utf8),
                  let issued = LoginToken(text), issued.accountID == String(expectedOwner) else { throw Failure.owner }
            return issued
        }
    }

    /// Isolated target-service acceptance check; no game licence/session selection.
    public func validateCredential(token: LoginToken, build: UInt64, region: Region, target: CredentialTarget) async throws {
        try await withAuthenticatedSession(token: token, build: build, region: region,
                                           titleID: target.titleID, platform: target.platform) {
            guard authenticatedProfile?.accountID == token.accountID else { throw Failure.owner }
        }
    }

    public func discover(token: LoginToken, build: UInt64, region: Region) async throws -> [GameAccount] {
        try await withAuthenticatedSession(token: token, build: build, region: region) {
            let owner = expectedOwner
            let body = try await call(hash: 0x22dc2464, method: 108)
            let links = try W.decode(W.data(W.decode(body), 1))[1] ?? []
            guard links.count <= 100 else { throw Failure.unavailable }
            var seen = Set<String>(), handles: [(UInt64, Data)] = []
            for link in links {
                guard case .bytes(let handle) = link else { throw Failure.unavailable }
                let fields = try W.decode(handle)
                let id = try W.uint(fields, 1), title = try W.uint(fields, 2), regionID = try W.uint(fields, 3)
                guard id > 0, title <= UInt32.max, regionID <= UInt32.max,
                      seen.insert("\(id):\(title):\(regionID)").inserted else { throw Failure.unavailable }
                if title == 5_730_135, regionID == 1 { handles.append((id, handle)) }
            }
            guard handles.count <= 20 else { throw Failure.unavailable }
            var accounts: [GameAccount] = []
            for (id, handle) in handles {
                let response = try await call(hash: 0x22dc2464, method: 201, body: W.bytes(1, handle))
                let info = try W.decode(W.data(W.decode(response), 1))
                guard try W.uint(info, 1) == owner else { throw Failure.owner }
                guard let name = String(data: try W.data(info, 2), encoding: .utf8),
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unavailable }
                accounts.append(GameAccount(titleID: "5730135", accountID: String(id), name: name, region: region.rawValue))
            }
            return accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    private func send(service: UInt64, method: UInt64, token: UInt64, body: Data, hash: UInt32? = nil) async throws {
        try Task.checkCancellation()
        guard !closed, body.count <= 1_048_576 else { throw Failure.unavailable }
        var header = W.number(1, service) + W.number(2, method) + W.number(3, token) + W.number(5, UInt64(body.count))
        if let hash { header += W.fixed32(11, hash) }
        let frame = Data([UInt8(header.count >> 8), UInt8(header.count & 255)]) + header + body
        try await transport.send(frame)
    }
    private func exact(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 1_048_576 else { throw Failure.unavailable }
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            guard !closed else { throw Failure.unavailable }
            let chunk = try await transport.read(maximum: count - result.count)
            guard !chunk.isEmpty, chunk.count <= count - result.count else { throw Failure.unavailable }
            result += chunk
        }
        return result
    }
    private func receive() async throws -> (W.Message, Data) {
        frames += 1; guard frames <= 100 else { throw Failure.unavailable }
        let prefix = [UInt8](try await exact(2)), length = Int(prefix[0]) * 256 + Int(prefix[1])
        guard length > 0, length <= 8192 else { throw Failure.unavailable }
        let header = try W.decode(await exact(length))
        for field in [1, 2, 3, 5, 6, 9, 11] where header[field] != nil { _ = try W.uint(header, field) }
        let size = try W.uint(header, 5, default: 0)
        guard size <= 1_048_576 else { throw Failure.unavailable }
        return (header, try await exact(Int(size)))
    }
    private func call(hash: UInt32, method: UInt64, body: Data = Data()) async throws -> Data {
        let token = sequence; sequence += 1
        try await send(service: 0, method: method, token: token, body: body, hash: hash)
        while true {
            let (header, response) = try await receive()
            if try W.uint(header, 1) == 254 {
                guard try W.uint(header, 3) == token else { throw Failure.unavailable }
                let status = try W.uint(header, 6, default: 0)
                guard status == 0 else { throw Failure.rejected(status) }
                return response
            }
            try notification(header, response)
        }
    }
    private func notification(_ header: W.Message, _ body: Data) throws {
        let hash = try W.uint(header, 11), method = try W.uint(header, 2) & 0x3fff_ffff
        guard hash == 0x9da8116b || hash == 0xecb8b826 else { throw Failure.unavailable }
        switch method {
        case 1:
            let message = try W.decode(body), status = try W.uint(message, 1, default: 0)
            guard status == 0 else { throw Failure.rejected(status) }
            let record = try W.decode(W.data(message, 2))
            guard try W.uint(record, 1) == expectedOwner else { throw Failure.owner }
            authenticatedProfile = NativeAccountProfile(accountID: String(expectedOwner), record: record)
            loggedIn = true
        case 2:
            let state = try W.decode(W.data(W.decode(body), 1))
            for field in state.keys { _ = try W.uint(state, field) }
        case 3: guard body.isEmpty else { throw Failure.unavailable }
        default: throw Failure.unavailable // Never answer an external challenge.
        }
        // These listener methods are NO_RESPONSE: do not send RPC acknowledgements.
    }
}

/// Internal seam for deterministic disconnect/cancellation tests. Production
/// always creates TLSAccountTransport with normal system trust validation.
@MainActor
protocol NativeAccountTransport: AnyObject {
    func connect() async throws
    func send(_ data: Data) async throws
    func read(maximum: Int) async throws -> Data
    func cancel()
}

@MainActor
private final class TLSAccountTransport: NativeAccountTransport {
    private let connection = NWConnection(host: "us.actual.battle.net", port: 1119, using: .tls)
    private var ready: CheckedContinuation<Void, Error>?
    private var closed = false
    func cancel() {
        closed = true; connection.cancel()
        ready?.resume(throwing: CancellationError()); ready = nil
    }
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !closed else { continuation.resume(throwing: CancellationError()); return }
            ready = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let pending = self.ready else { return }
                    switch state {
                    case .ready: self.ready = nil; pending.resume()
                    case .failed, .cancelled: self.ready = nil; pending.resume(throwing: NativeGameAccounts.Failure.unavailable)
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: NativeGameAccounts.Failure.unavailable) }
                else { continuation.resume() }
            })
        }
    }
    func read(maximum: Int) async throws -> Data {
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                guard error == nil, let data, !data.isEmpty else {
                    continuation.resume(throwing: NativeGameAccounts.Failure.unavailable); return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
