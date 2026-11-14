import Foundation

/// Who a game-service logon signed in as. Never a login ticket.
public struct NativeAccountProfile: Equatable, Sendable {
    public let accountID: String
    /// Only a well-formed `Name#1234`; anything else is left out.
    public let battleTag: String?

    public init(accountID: String, battleTag: String?) {
        self.accountID = accountID
        self.battleTag = battleTag.flatMap(Self.validBattleTag)
    }

    /// `record` is the logon outcome's account record, whose owner the
    /// caller has checked.
    init(accountID: String, record: WoWAccountWire.Message) {
        let tag = (try? record.bytes(3)).flatMap { $0.count <= 256 ? String(data: $0, encoding: .utf8) : nil }
        self.init(accountID: accountID, battleTag: tag)
    }

    private static func validBattleTag(_ text: String) -> String? {
        let unwanted = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        guard !text.unicodeScalars.contains(where: unwanted.contains) else { return nil }
        let tag = text.trimmingCharacters(in: .whitespaces)
        let parts = tag.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return tag
    }
}

extension AccountList {
    /// Names a saved account by the BattleTag its own logon reported. Only
    /// for that account: none is added, and a missing tag changes nothing.
    @discardableResult
    public mutating func setNativeProfile(_ profile: NativeAccountProfile, for owner: String) -> Bool {
        guard profile.accountID == owner, self[owner] != nil, let tag = profile.battleTag else { return false }
        setProfile(owner, battleTag: tag, email: nil)
        return true
    }
}
