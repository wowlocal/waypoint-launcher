import Foundation

/// Profile metadata from an owner-verified native logon, never a login token.
public struct NativeAccountProfile: Equatable, Sendable {
    public let accountID: String
    public let battleTag: String?

    init(accountID: String, record: BGSWire.Message) {
        self.accountID = accountID
        guard let values = record[3], values.count == 1, case .bytes(let data) = values[0],
              data.count <= 256, let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            battleTag = nil; return
        }
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tag.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else { battleTag = nil; return }
        battleTag = tag
    }
}

extension AccountList {
    /// Applies only the owner-bound metadata returned by native authentication.
    /// Existing names survive missing/invalid metadata; no identity is added here.
    @discardableResult
    public mutating func setNativeProfile(_ profile: NativeAccountProfile, for owner: String) -> Bool {
        guard profile.accountID == owner, self[owner] != nil, let tag = profile.battleTag else { return false }
        setProfile(owner, battleTag: tag, email: nil)
        return true
    }

}
