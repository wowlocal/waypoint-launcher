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
