import Foundation
import Security

/// Passwords live only in the Keychain; account preferences contain retry
/// state, never these values.
public struct SavedCredentials: Codable, Equatable, Sendable, CustomStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "SavedCredentials(redacted)" }
}

public struct CredentialVault: Sendable {
    public var service: String

    public init(service: String = "Waypoint Battle.net passwords") {
        self.service = service
    }

    /// Background sign-in must never put up a Keychain unlock/access prompt.
    public func credentials(account: String, allowInteraction: Bool = false) throws -> SavedCredentials? {
        var item = query(account)
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        if !allowInteraction { item[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(SavedCredentials.self, from: data)
    }

    public func save(_ credentials: SavedCredentials, account: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrLabel] = service
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecAttrSynchronizable: false]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
            ])
        }
    }
}

/// An attempt is persisted BEFORE submitting anything. A crash, restart,
/// another game or another region cannot bypass the account's retry limit.
public struct AutoLoginState: Codable, Equatable, Sendable {
    public enum PauseReason: String, Codable, Sendable {
        case signInRequired, tooManyFailures
    }

    public private(set) var attempts = 0
    public private(set) var retryAfter: Date?
    public private(set) var pauseReason: PauseReason?
    public static let maximumAttempts = 3

    public init() {}

    public var isPaused: Bool { pauseReason != nil || attempts >= Self.maximumAttempts }

    public func canAttempt(at now: Date = Date()) -> Bool {
        !isPaused && (retryAfter == nil || now >= retryAfter!)
    }

    @discardableResult
    public mutating func begin(at now: Date = Date()) -> Bool {
        guard canAttempt(at: now) else { return false }
        attempts += 1
        retryAfter = now.addingTimeInterval(attempts == 1 ? 5 * 60 : 15 * 60)
        return true
    }

    public mutating func succeeded() { self = AutoLoginState() }
    public mutating func requiresSignIn() { pauseReason = .signInRequired }
    public mutating func failedTemporarily() {
        if attempts >= Self.maximumAttempts { pauseReason = .tooManyFailures }
    }

    public static let defaultsKey = "autoLoginStates"

    public static func load(from defaults: UserDefaults = .standard) -> [String: Self] {
        guard let data = defaults.data(forKey: defaultsKey),
              let states = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return states
    }

    public static func save(_ states: [String: Self], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(states), forKey: defaultsKey)
    }
}
