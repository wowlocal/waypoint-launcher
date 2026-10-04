import Foundation
import Security

/// Which web session (cookie jar) an account signs in with. Each account
/// keeps its own, side by side, so switching between them needs no sign-in.
public enum WebSessionID: Codable, Hashable, Sendable {
    /// The app's default WebKit store: the one session from before Waypoint
    /// had accounts. It stays with whichever account was signed in there.
    case shared
    /// A persistent WebKit store of its own (`WKWebsiteDataStore(forIdentifier:)`).
    case own(UUID)

    public static func fresh() -> Self { .own(UUID()) }
}

/// A color that tells accounts apart at a glance, in the toolbar and menus.
public enum AccountTint: String, Codable, CaseIterable, Sendable {
    case blue, orange, green, pink, purple, teal, yellow, red, indigo, brown
}

/// A Battle.net account Waypoint has signed in to.
public struct Account: Codable, Equatable, Sendable, Identifiable {
    /// The Battle.net account id: the numeric suffix of its login tokens.
    public var id: String
    public var battleTag: String?
    public var email: String?
    public var session: WebSessionID
    public var tint: AccountTint

    public init(id: String, battleTag: String? = nil, email: String? = nil, session: WebSessionID, tint: AccountTint = .blue) {
        self.id = id
        self.battleTag = battleTag
        self.email = email
        self.session = session
        self.tint = tint
    }

    /// The BattleTag once Blizzard's account page has told us; until then
    /// the email, or the bare account id.
    public var displayName: String { battleTag ?? email ?? "Account \(id)" }
}

/// The saved accounts and the one games launch with.
public struct AccountList: Codable, Equatable, Sendable {
    public private(set) var accounts: [Account] = []
    public private(set) var activeID: String?

    public init() {}

    public var active: Account? { accounts.first { $0.id == activeID } }

    public subscript(id: String) -> Account? { accounts.first { $0.id == id } }

    /// Makes a saved account the one games launch with.
    public mutating func activate(_ id: String) {
        if self[id] != nil { activeID = id }
    }

    /// Records that account `id` signed in through `session`, and makes it
    /// active. A new account is added; a saved one moves to `session`. Whoever
    /// had `session` before gets a fresh one, since its cookies now belong to
    /// `id`. Returns the session nothing uses any more, for the caller to
    /// delete.
    @discardableResult
    public mutating func signedIn(_ id: String, session: WebSessionID) -> WebSessionID? {
        for i in accounts.indices where accounts[i].id != id && accounts[i].session == session {
            accounts[i].session = .fresh()
        }
        activeID = id
        guard let i = accounts.firstIndex(where: { $0.id == id }) else {
            accounts.append(Account(id: id, session: session, tint: unusedTint))
            return nil
        }
        let old = accounts[i].session
        accounts[i].session = session
        return old == session ? nil : old
    }

    /// The first tint no saved account has, so each one looks different
    /// while there are enough colors.
    private var unusedTint: AccountTint {
        let used = Set(accounts.map(\.tint))
        return AccountTint.allCases.first { !used.contains($0) }
            ?? AccountTint.allCases[accounts.count % AccountTint.allCases.count]
    }

    /// Fills in what Blizzard's account page says about a saved account.
    public mutating func setProfile(_ id: String, battleTag: String?, email: String?) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let battleTag, !battleTag.isEmpty { accounts[i].battleTag = battleTag }
        if let email, !email.isEmpty { accounts[i].email = email }
    }

    /// Forgets an account; the next one, if any, becomes active. Returns the
    /// removed account, whose session the caller should delete.
    @discardableResult
    public mutating func remove(_ id: String) -> Account? {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = accounts.remove(at: i)
        if activeID == id { activeID = accounts.first?.id }
        return removed
    }

    // MARK: Saving

    public static let defaultsKey = "accounts"

    public static func load(from defaults: UserDefaults = .standard) -> AccountList {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode(AccountList.self, from: data)
        else { return AccountList() }
        return list
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Each account's last login token per game (codename), in the login
/// keychain. A token stays valid for months, so a switched-to account whose
/// web session has expired can still play without the login page.
public struct TokenVault: Sendable {
    /// The keychain item's service; one item per account.
    public var service: String

    public init(service: String = "Waypoint Battle.net login tokens") {
        self.service = service
    }

    public func token(account: String, codename: String) -> LoginToken? {
        tokens(account: account)[codename].flatMap(LoginToken.init)
    }

    public func save(_ token: LoginToken, codename: String) throws {
        let account = token.accountID
        var tokens = tokens(account: account)
        tokens[codename] = token.value
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrLabel] = service
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func removeAll(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    private func tokens(account: String) -> [String: String] {
        var item = query(account)
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let tokens = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return tokens
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
        }
    }
}
