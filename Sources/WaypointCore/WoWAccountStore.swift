import Foundation

/// One World of Warcraft license ("game account") under a Battle.net
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

/// Whose WoW choice, for which installed edition and play region.
public struct WoWAccountScope: Equatable, Sendable {
    public var owner: String
    public var uid: String
    public var region: Region

    public init(owner: String, uid: String, region: Region) {
        self.owner = owner
        self.uid = uid
        self.region = region
    }
}

/// The WoW licenses Waypoint knows about and the one the user picked, kept
/// apart from Battle.net sign-in. A choice belongs to one Battle.net account
/// (owner), one installed edition (uid) and one play region; with none,
/// Waypoint launches "automatic" and the game decides (WoW asks at login
/// when there are several). Known licenses are cached per owner and region.
/// Nothing here is a credential.
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
    }

    /// The `GAME_ACCOUNT` to hand over with `token`. The owner comes from the
    /// token itself, so one account's license can't ride along with another
    /// account's login. A choice the last lookup no longer listed goes out as
    /// automatic: the game picks, rather than Play failing on a stale name.
    public func launchAccount(for token: LoginToken, uid: String, region: Region) -> String? {
        selected(owner: token.accountID, uid: uid, region: region)
            .flatMap { listed($0, owner: token.accountID, region: region) }?.name
    }

    /// Whether a launch with `token` should leave the license Battle.net
    /// chose for that account alone: Waypoint has no choice of its own and
    /// never looked the licenses up, so it can't do better. After a lookup,
    /// no choice means WoW asks.
    public func defersToBattleNet(for token: LoginToken, uid: String, region: Region) -> Bool {
        selected(owner: token.accountID, uid: uid, region: region) == nil
            && !hasCatalog(owner: token.accountID, region: region)
    }

    /// Whether a saved choice is still on the account. Before any lookup
    /// there is nothing to compare with, so it counts as available.
    public func isAvailable(_ account: WoWGameAccount, owner: String, region: Region) -> Bool {
        listed(account, owner: owner, region: region) != nil
    }

    /// The last lookup's entry for `account`'s id, so a renamed license goes
    /// out under its current name; `account` itself before any lookup.
    private func listed(_ account: WoWGameAccount, owner: String, region: Region) -> WoWGameAccount? {
        guard hasCatalog(owner: owner, region: region) else { return account }
        return cachedAccounts(owner: owner, region: region).first { $0.id == account.id }
    }

    /// After a lookup with exactly one license there is nothing to choose, so
    /// it becomes the edition's choice. With several, the choice stays as it
    /// is (WoW asks at login until the user picks one). An explicit "Ask in
    /// WoW" isn't kept apart from no choice, so it gives way too;
    /// with one license WoW would pick that one anyway.
    @discardableResult
    public mutating func selectOnlyAccount(in scope: WoWAccountScope) -> WoWGameAccount? {
        let accounts = cachedAccounts(owner: scope.owner, region: scope.region)
        guard accounts.count == 1, let only = accounts.first,
              select(only, owner: scope.owner, uid: scope.uid, region: scope.region) else { return nil }
        return only
    }

    /// A choice made in a menu or sheet. It applies only while `current` is
    /// still the scope the menu was built for, so a late click can't land on
    /// another account or region, and only to a license the last lookup
    /// listed. `nil` (let WoW choose) is always allowed.
    @discardableResult
    public mutating func select(_ account: WoWGameAccount?, in scope: WoWAccountScope, current: WoWAccountScope?) -> Bool {
        guard scope == current else { return false }
        if let account, !cachedAccounts(owner: scope.owner, region: scope.region).contains(account) { return false }
        return select(account, owner: scope.owner, uid: scope.uid, region: scope.region)
    }

    /// The choice worth showing in the library row: only when there is more
    /// than one license to pick from and the chosen one is still listed.
    public func shownChoice(in scope: WoWAccountScope) -> WoWGameAccount? {
        guard cachedAccounts(owner: scope.owner, region: scope.region).count > 1,
              let chosen = selected(owner: scope.owner, uid: scope.uid, region: scope.region) else { return nil }
        return listed(chosen, owner: scope.owner, region: scope.region)
    }

    /// `nil` goes back to automatic. Malformed input leaves the saved
    /// choice alone and returns false.
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

    // MARK: Known licenses

    public func cachedAccounts(owner: String, region: Region) -> [WoWGameAccount] {
        catalogs.first { $0.owner == owner && $0.region == region }?.accounts ?? []
    }

    /// Tells "looked up, none found" apart from "never looked up".
    public func hasCatalog(owner: String, region: Region) -> Bool {
        catalogs.contains { $0.owner == owner && $0.region == region }
    }

    /// Replaces the known licenses after a refresh, keeping an empty result
    /// too. Never touches the saved choice: a license missing from one
    /// refresh stays selected (shown as unavailable, launched as automatic)
    /// until the user changes it. A list with anything malformed in it, or
    /// too many entries, is rejected whole and the previous cache kept.
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
