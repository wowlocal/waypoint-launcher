import Foundation

/// One World of Warcraft licence ("game account") under a Battle.net
/// account, e.g. `WoW1`. The name is what the game reads from
/// `Launch Options/WoW/GAME_ACCOUNT`.
public struct WoWGameAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Both fields end up in user defaults and the name in `net.battle`, so
    /// they must be short, printable and never hold a login ticket.
    public var isValid: Bool {
        Self.isPlain(id, allowsSpaces: false) && Self.isValidName(name)
    }

    public static func isValidName(_ name: String) -> Bool {
        // The game matches the name exactly; padding would never match.
        isPlain(name, allowsSpaces: true) && name == name.trimmingCharacters(in: .whitespaces)
    }

    static func isPlain(_ s: String, allowsSpaces: Bool, maxLength: Int = 64) -> Bool {
        var banned = CharacterSet.controlCharacters.union(.newlines)
        if !allowsSpaces { banned.formUnion(.whitespaces) }
        return !s.isEmpty && s.unicodeScalars.count <= maxLength
            && !s.unicodeScalars.contains(where: banned.contains)
            && !s.contains(/[0-9A-Fa-f]{32}/) // a ticket's id part
    }
}

/// The WoW licences Waypoint knows about and the one the user picked, kept
/// apart from Battle.net sign-in. A choice belongs to one Battle.net account
/// (owner), one installed edition (uid) and one play region. A saved default
/// covers editions without an override; without either, the caller can ask
/// for a choice or launch automatically. Nothing here is a credential.
public struct WoWAccountStore: Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable {
        var owner: String
        var uid: String
        var region: Region
        var account: WoWGameAccount
    }

    struct Catalog: Codable, Equatable, Sendable {
        var owner: String
        var region: Region
        var accounts: [WoWGameAccount]
    }

    private var selections: [Selection] = []
    private var catalogs: [Catalog] = []

    static let maxAccounts = 32
    static let maxEntries = 256

    public init() {}

    // MARK: Selection

    public func selected(owner: String, uid: String, region: Region) -> WoWGameAccount? {
        selections.first { $0.owner == owner && $0.uid == uid && $0.region == region }?.account
            ?? defaultAccount(owner: owner, region: region)
    }

    /// Default for editions without an explicit override; old records remain valid.
    public func defaultAccount(owner: String, region: Region) -> WoWGameAccount? {
        selections.first { $0.owner == owner && $0.uid == "*" && $0.region == region }?.account
    }
    @discardableResult
    public mutating func selectDefault(_ account: WoWGameAccount, owner: String, region: Region) -> Bool {
        select(account, owner: owner, uid: "*", region: region)
    }

    /// The `GAME_ACCOUNT` to hand over with `token`. The owner comes from the
    /// token itself, so one account's licence can't ride along with another
    /// account's login.
    public func launchAccount(for token: LoginToken, uid: String, region: Region) -> String? {
        selected(owner: token.accountID, uid: uid, region: region)?.name
    }

    /// `nil` removes the edition override, revealing a saved default if any.
    /// Without a default it is automatic. Malformed input returns false.
    @discardableResult
    public mutating func select(_ account: WoWGameAccount?, owner: String, uid: String, region: Region) -> Bool {
        guard Self.isValidScope(owner), Self.isValidScope(uid), account?.isValid ?? true else { return false }
        selections.removeAll { $0.owner == owner && $0.uid == uid && $0.region == region }
        if let account {
            selections.append(Selection(owner: owner, uid: uid, region: region, account: account))
            if selections.count > Self.maxEntries { selections.removeFirst(selections.count - Self.maxEntries) }
        }
        return true
    }

    // MARK: Known licences

    public func cachedAccounts(owner: String, region: Region) -> [WoWGameAccount] {
        catalogs.first { $0.owner == owner && $0.region == region }?.accounts ?? []
    }

    /// Distinguishes no lookup from a successful empty response.
    public func hasCatalog(owner: String, region: Region) -> Bool {
        catalogs.contains { $0.owner == owner && $0.region == region }
    }

    /// Replaces the known licences after a refresh. Never touches the saved
    /// choice: a licence missing from one refresh stays selected until the
    /// user changes it. A list with anything malformed in it, or too many
    /// entries, is rejected whole and the previous cache kept.
    @discardableResult
    public mutating func cache(_ accounts: [WoWGameAccount], owner: String, region: Region) -> Bool {
        guard Self.isValidScope(owner), accounts.allSatisfy(\.isValid) else { return false }
        var seen = Set<String>()
        let unique = accounts.filter { seen.insert($0.id).inserted }
        guard unique.count <= Self.maxAccounts else { return false }
        catalogs.removeAll { $0.owner == owner && $0.region == region }
        catalogs.append(Catalog(owner: owner, region: region, accounts: unique))
        if catalogs.count > Self.maxEntries { catalogs.removeFirst(catalogs.count - Self.maxEntries) }
        return true
    }

    /// Forgets everything about an account, e.g. when it signs out.
    public mutating func remove(owner: String) {
        selections.removeAll { $0.owner == owner }
        catalogs.removeAll { $0.owner == owner }
    }

    static func isValidScope(_ s: String) -> Bool {
        WoWGameAccount.isPlain(s, allowsSpaces: false, maxLength: 128)
    }

    // MARK: Saving

    public static let defaultsKey = "wowGameAccounts"
    static let maxBytes = 256 * 1024

    /// Entries that don't read back or fail the usual checks are dropped
    /// (automatic); unreadable data as a whole loads as empty.
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), data.count <= maxBytes,
              let decoded = try? JSONDecoder().decode(Loaded.self, from: data)
        else { return Self() }
        // Re-insert through the same checks as fresh input.
        var store = Self()
        for c in decoded.catalogs.compactMap(\.value) { store.cache(c.accounts, owner: c.owner, region: c.region) }
        for s in decoded.selections.compactMap(\.value) { store.select(s.account, owner: s.owner, uid: s.uid, region: s.region) }
        return store
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(Stored(selections: selections, catalogs: catalogs)), forKey: Self.defaultsKey)
    }

    private struct Stored: Encodable {
        var selections: [Selection]
        var catalogs: [Catalog]
    }

    /// One entry another build wrote (say, with a region this one doesn't
    /// know) must not cost the rest.
    private struct Loaded: Decodable {
        struct Entry<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        }
        var selections: [Entry<Selection>]
        var catalogs: [Entry<Catalog>]
    }

}
