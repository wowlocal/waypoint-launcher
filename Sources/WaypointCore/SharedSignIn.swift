import Foundation

/// A game that can sign in with a ticket issued from the saved WoW login,
/// instead of a login of its own. Only these have been tried.
public enum SharedSignIn: Sendable, CaseIterable {
    case hearthstone, diabloIV

    /// From the game's codename, as in `Launch Options`.
    public init?(codename: String) {
        switch codename {
        case "WTCG": self = .hearthstone
        case "Fen": self = .diabloIV
        default: return nil
        }
    }

    public var codename: String {
        switch self {
        case .hearthstone: "WTCG"
        case .diabloIV: "Fen"
        }
    }

    /// The game as the game service names it: its codename's four-character code.
    var program: UInt64 {
        codename.utf8.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension WoWAccountDiscovery {
    /// Whether any WoW client runs on this Mac.
    public nonisolated static func isWoWRunning() -> Bool { isWoWRunning(in: RunningProcesses.executables()) }

    /// The live WoW build in `region`, to sign in with where no WoW is
    /// installed. One short attempt: callers have another way to go.
    public nonisolated static func liveBuild(region: Region) async throws -> UInt64 {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let version = try await VersionService(session: session).latest(product: "wowf", region: region)
        guard version.region == region.rawValue, version.buildID > 0 else { throw Failure.unavailable }
        return UInt64(version.buildID)
    }
}
