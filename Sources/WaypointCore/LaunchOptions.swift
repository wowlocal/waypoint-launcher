import CommonCrypto
import CoreFoundation
import Foundation

/// The hand-off channel Battle.net uses on macOS: before starting a game it
/// writes the login token and region into the `net.battle` preferences domain
/// under `Launch Options/<GAME>/…`, and the game reads them back on startup
/// (see the client's `RegistryDarwin`). We write the same values, so the game
/// can't tell who launched it.
public struct LaunchOptions {
    public static var domain: CFString { "net.battle" as CFString }

    /// The key prefix the game looks under. Not the same as the product code.
    public var gameKey: String
    public var userName: String
    /// `net.battle` except in tests.
    public var preferencesDomain: String

    public init(gameKey: String, userName: String = NSUserName(), preferencesDomain: String = LaunchOptions.domain as String) {
        self.gameKey = gameKey
        self.userName = userName
        self.preferencesDomain = preferencesDomain
    }

    public var webTokenKey: String { "Launch Options/\(gameKey)/WEB_TOKEN" }
    public var regionKey: String { "Launch Options/\(gameKey)/REGION" }
    public var localeKey: String { "Launch Options/\(gameKey)/LOCALE" }
    /// Which WoW licence to log in with, by name (`WoW1`). Only WoW reads it.
    public var gameAccountKey: String { "Launch Options/\(gameKey)/GAME_ACCOUNT" }
    /// Waypoint's own note of whose licence `GAME_ACCOUNT` is: the Battle.net
    /// account id of the token it was written with. The game ignores it.
    public var gameAccountOwnerKey: String { "Launch Options/\(gameKey)/WAYPOINT_GAME_ACCOUNT_OWNER" }
    public var usesGameAccount: Bool { gameKey == "WoW" }

    // MARK: Reading and writing

    public func storedToken() throws -> String? {
        guard let data = value(webTokenKey) as? Data else { return nil }
        return try TokenCipher(userName: userName).decrypt(data)
    }

    public func storedRegion() -> String? {
        value(regionKey) as? String
    }

    public func storedLocale() -> String? {
        value(localeKey) as? String
    }

    public func storedGameAccount() -> String? {
        value(gameAccountKey) as? String
    }

    /// The CLI replays the existing handoff, including its license only in
    /// the same region and only when Waypoint recorded `token`'s own account
    /// as its owner. Without that note (another account's license, or one
    /// only Battle.net or an older Waypoint wrote) it's dropped and WoW
    /// chooses. App launches use their own per-edition preferences.
    public func storedGameAccount(for region: Region, token: LoginToken) -> String? {
        guard usesGameAccount, storedRegion() == region.launchOptionValue,
              value(gameAccountOwnerKey) as? String == token.accountID,
              let name = storedGameAccount(), WoWGameAccount.isValidName(name) else { return nil }
        return name
    }

    /// Writes the token and region the way Battle.net does. Locale is only
    /// written when given, so we don't clobber what the user picked in Battle.net.
    /// For WoW the licence is always written with them: a nil `gameAccount`
    /// removes `GAME_ACCOUNT`, so a licence left by another account, region
    /// or Battle.net itself never goes out with this token. Other games
    /// ignore `gameAccount`.
    public func write(token: String, region: Region, locale: String?, gameAccount: String? = nil) throws {
        if usesGameAccount, let gameAccount, !WoWGameAccount.isValidName(gameAccount) {
            throw CocoaError(.keyValueValidation, userInfo: [NSLocalizedDescriptionKey: "Invalid WoW account name"])
        }
        let encrypted = try TokenCipher(userName: userName).encrypt(token)
        set(webTokenKey, encrypted as CFData)
        set(regionKey, region.launchOptionValue as CFString)
        if let locale { set(localeKey, locale as CFString) }
        if usesGameAccount {
            set(gameAccountKey, gameAccount as CFString?)
            // A token that doesn't parse leaves no owner, so the CLI won't
            // replay this license: it fails safe.
            set(gameAccountOwnerKey, gameAccount == nil ? nil : LoginToken(token)?.accountID as CFString?)
        }
        guard CFPreferencesAppSynchronize(preferencesDomain as CFString) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not save net.battle preferences"])
        }
    }

    /// Removes the token, and for WoW the licence chosen with it.
    public func clearToken() {
        set(webTokenKey, nil)
        if usesGameAccount {
            set(gameAccountKey, nil)
            set(gameAccountOwnerKey, nil)
        }
        CFPreferencesAppSynchronize(preferencesDomain as CFString)
    }

    private func value(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key as CFString, preferencesDomain as CFString)
    }

    private func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, preferencesDomain as CFString)
    }
}

/// AES-128-CBC with a zero IV and a PBKDF2 key derived from a fixed entropy
/// blob XORed with the macOS user name. Mirrors `RegistryDarwin` in the
/// Battle.net game SDK.
public struct TokenCipher {
    static let entropy: [UInt8] = [200, 118, 244, 174, 76, 149, 46, 254, 242, 250, 15, 84, 25, 192, 156, 67]
    static let salt = Array("someSalt".utf8)
    static let iterations: UInt32 = 1000

    public enum Error: Swift.Error {
        case crypto(CCCryptorStatus)
        case notUTF8
    }

    let key: [UInt8]

    public init(userName: String) {
        var password = Self.entropy
        // C# indexes the UTF-16 string and truncates each unit to a byte.
        for (i, unit) in userName.utf16.prefix(16).enumerated() {
            password[i] ^= UInt8(truncatingIfNeeded: unit)
        }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        _ = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self), pw.count,
                Self.salt, Self.salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), Self.iterations,
                &key, key.count)
        }
        self.key = key
    }

    public func encrypt(_ token: String) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), Array(token.utf8))
    }

    public func decrypt(_ data: Data) throws -> String {
        let plain = try crypt(CCOperation(kCCDecrypt), Array(data))
        guard let s = String(data: plain, encoding: .utf8) else { throw Error.notUTF8 }
        return s
    }

    private func crypt(_ op: CCOperation, _ input: [UInt8]) throws -> Data {
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw Error.crypto(status) }
        return Data(out.prefix(moved))
    }
}

public enum Region: String, CaseIterable, Sendable, Codable {
    case eu, us, kr, cn

    /// Value of `Launch Options/<GAME>/REGION`.
    public var launchOptionValue: String { rawValue.uppercased() }

    public init?(launchOptionValue: String) {
        self.init(rawValue: launchOptionValue.lowercased())
    }

    public var displayName: String {
        switch self {
        case .eu: "Europe"
        case .us: "Americas"
        case .kr: "Asia"
        case .cn: "China"
        }
    }
}

/// A Battle.net login ticket, e.g. `EU-0123abcd…-123456789`.
public struct LoginToken: Equatable, Sendable {
    public var value: String

    public init?(_ value: String) {
        // Region prefix, 32-char ticket id, numeric suffix of varying length.
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 2, parts[0].allSatisfy(\.isLetter),
              parts[1].count == 32, parts[1].allSatisfy(\.isHexDigit),
              !parts[2].isEmpty, parts[2].allSatisfy(\.isNumber)
        else { return nil }
        self.value = value
    }

    /// The numeric suffix is the Battle.net account id. (The prefix is the
    /// issuing login server, not the play region: EU accounts get `US-` too.)
    public var accountID: String { String(value.split(separator: "-").last ?? "") }

    /// Pulls the `ST` parameter out of the login page's final redirect.
    public init?(callbackURL: URL) {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let st = items.first(where: { $0.name == "ST" })?.value else { return nil }
        self.init(st)
    }

    /// Safe to log.
    public var redacted: String { "\(value.prefix(3))…(\(value.count) chars)" }
}
