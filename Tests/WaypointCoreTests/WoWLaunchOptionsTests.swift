import Foundation
import Testing
@testable import WaypointCore

private let tokenA = "US-0123456789abcdef0123456789abcdef-111"
private let tokenB = "US-fedcba9876543210fedcba9876543210-222"

/// Launch options in a throwaway preferences domain, never `net.battle`.
private func withOptions(_ gameKey: String = "WoW", _ body: (LaunchOptions, UserDefaults) throws -> Void) throws {
    let suite = "WaypointCoreTests.launchOptions.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(LaunchOptions(gameKey: gameKey, userName: "testuser", preferencesDomain: suite, notesDomain: suite), defaults)
}

@Test func launchOptionsDefaultToNetBattle() {
    #expect(LaunchOptions(gameKey: "WoW").preferencesDomain == "net.battle")
    // Waypoint's own notes never go into Battle.net's domain.
    #expect(LaunchOptions(gameKey: "WoW").notesDomain == "dev.waypoint.launch-options")
    #expect(!LaunchOptions(gameKey: "WoW").gameAccountOwnerKey.hasPrefix("Launch Options/"))
}

@Test func selectedLicenseIsWrittenWithItsToken() throws {
    try withOptions { options, defaults in
        try options.write(token: tokenA, region: .us, locale: "enUS", gameAccount: "WoW1")
        #expect(try options.storedToken() == tokenA)
        #expect(options.storedRegion() == "US")
        #expect(options.storedLocale() == "enUS")
        #expect(options.storedGameAccount() == "WoW1")
        #expect(defaults.string(forKey: "Launch Options/WoW/GAME_ACCOUNT") == "WoW1")

        try options.write(token: tokenB, region: .eu, locale: "enGB", gameAccount: "WoW2")
        #expect(try options.storedToken() == tokenB)
        #expect(options.storedRegion() == "EU")
        #expect(options.storedGameAccount() == "WoW2")
    }
}

@Test func automaticHandoffClearsALicenseFromAnotherRegion() throws {
    try withOptions { options, _ in
        try options.write(token: tokenA, region: .us, locale: "enUS", gameAccount: "WoW2")
        try options.write(token: tokenA, region: .eu, locale: nil, gameAccount: nil)
        #expect(options.storedGameAccount() == nil)
        #expect(options.storedRegion() == "EU")
        // Locale still only changes when given.
        #expect(options.storedLocale() == "enUS")
    }
}

@Test func automaticHandoffClearsALicenseFromAnotherAccount() throws {
    try withOptions { options, _ in
        var store = WoWAccountStore()
        store.select(WoWGameAccount(id: "1", name: "WoW2"), owner: "111", uid: "wow", region: .us)
        let a = try #require(LoginToken(tokenA)), b = try #require(LoginToken(tokenB))

        try options.write(token: a.value, region: .us, locale: nil,
                          gameAccount: store.launchAccount(for: a, uid: "wow", region: .us))
        #expect(options.storedGameAccount() == "WoW2")
        try options.write(token: b.value, region: .us, locale: nil,
                          gameAccount: store.launchAccount(for: b, uid: "wow", region: .us))
        #expect(try options.storedToken() == tokenB)
        #expect(options.storedGameAccount() == nil)
    }
}

@Test func automaticHandoffClearsALicenseBattleNetLeftBehind() throws {
    try withOptions { options, defaults in
        defaults.set("WoW3", forKey: options.gameAccountKey)
        try options.write(token: tokenA, region: .us, locale: nil)
        #expect(options.storedGameAccount() == nil)
    }
}

@Test func keptHandoffLeavesBattleNetsLicenseForTheSameAccountAndRegion() throws {
    try withOptions { options, defaults in
        let a = try #require(LoginToken(tokenA))
        // Battle.net launched account A in the Americas with WoW3.
        try options.write(token: tokenA, region: .us, locale: nil)
        defaults.set("WoW3", forKey: options.gameAccountKey)
        #expect(options.canKeepStoredGameAccount(for: .us, token: a))
        #expect(try options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == "WoW3")
        // Battle.net never wrote an owner note, and Waypoint doesn't add one.
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
        // Without the keep flag (Ask in WoW, or a choice gone from the
        // account) it's cleared as before.
        #expect(try !options.write(token: tokenA, region: .us, locale: nil))
        #expect(options.storedGameAccount() == nil)
    }
}

@Test func keptHandoffClearsALicenseOfAnotherAccountRegionOrNote() throws {
    try withOptions { options, defaults in
        let a = try #require(LoginToken(tokenA)), b = try #require(LoginToken(tokenB))
        func battleNetLeft(_ token: String, _ region: Region, _ name: String = "WoW3") throws {
            try options.write(token: token, region: region, locale: nil)
            defaults.set(name, forKey: options.gameAccountKey)
        }
        // Another account's ticket went out with it.
        try battleNetLeft(tokenB, .us)
        #expect(!options.canKeepStoredGameAccount(for: .us, token: a))
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == nil)
        // Another region.
        try battleNetLeft(tokenA, .eu)
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == nil)
        // A name WoW could never match.
        try battleNetLeft(tokenA, .us, "WoW3\n")
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == nil)
        // Waypoint chose WoW2 for A; Battle.net then signed B in and left it.
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        try options.write(token: tokenB, region: .us, locale: nil)
        defaults.set("WoW2", forKey: options.gameAccountKey)
        defaults.set("111", forKey: options.gameAccountOwnerKey)
        #expect(!options.canKeepStoredGameAccount(for: .us, token: b))
        #expect(try !options.write(token: tokenB, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == nil)
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
        // No stored license: nothing to keep.
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
    }
}

@Test func keptHandoffNeverOverridesAChoice() throws {
    try withOptions { options, defaults in
        try options.write(token: tokenA, region: .us, locale: nil)
        defaults.set("WoW3", forKey: options.gameAccountKey)
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW1", keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == "WoW1")
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == "111")
    }
}

/// The CLI replays the stored handoff with the keep flag: Waypoint's own
/// license for that token, and Battle.net's, go out again in the same region.
@Test func cliReplayKeepsTheTokensLicense() throws {
    try withOptions { options, defaults in
        let a = try #require(LoginToken(tokenA))
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == "111")
        #expect(options.canKeepStoredGameAccount(for: .us, token: a))
        #expect(!options.canKeepStoredGameAccount(for: .eu, token: a))
        #expect(try options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == "WoW2")
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == "111")
        // An automatic launch and Sign Out clear the note with the license.
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: nil)
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        options.clearToken()
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
    }
}

@Test func otherGamesNeverKeepAGameAccount() throws {
    try withOptions("WTCG") { options, defaults in
        try options.write(token: tokenA, region: .us, locale: nil)
        defaults.set("kept", forKey: options.gameAccountKey)
        #expect(!options.canKeepStoredGameAccount(for: .us, token: try #require(LoginToken(tokenA))))
        #expect(try !options.write(token: tokenA, region: .us, locale: nil, keepingStoredGameAccount: true))
        #expect(options.storedGameAccount() == "kept")
    }
}

@Test func malformedLicenseNameWritesNothing() throws {
    try withOptions { options, _ in
        try options.write(token: tokenA, region: .us, locale: "enUS", gameAccount: "WoW1")
        for name in ["", " WoW1", "WoW1\nX", "WoW\u{0}1", tokenB, "ST=\(tokenB)"] {
            #expect(throws: CocoaError.self) {
                try options.write(token: tokenB, region: .eu, locale: "enGB", gameAccount: name)
            }
        }
        #expect(try options.storedToken() == tokenA)
        #expect(options.storedRegion() == "US")
        #expect(options.storedLocale() == "enUS")
        #expect(options.storedGameAccount() == "WoW1")
    }
}

@Test func clearingTheTokenAlsoClearsTheLicense() throws {
    try withOptions { options, _ in
        try options.write(token: tokenA, region: .us, locale: "enUS", gameAccount: "WoW1")
        options.clearToken()
        #expect(try options.storedToken() == nil)
        #expect(options.storedGameAccount() == nil)
        #expect(options.storedRegion() == "US")
    }
}

@Test func otherGamesNeverTouchGameAccount() throws {
    try withOptions("WTCG") { options, defaults in
        defaults.set("kept", forKey: options.gameAccountKey)
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW1")
        try options.write(token: tokenA, region: .us, locale: nil)
        options.clearToken()
        #expect(!options.usesGameAccount)
        #expect(options.storedGameAccount() == "kept")
        #expect(defaults.object(forKey: options.gameAccountOwnerKey) == nil)
    }
}

@Test func launchPlansStartOnAutomatic() {
    let plan = LaunchPlan(executable: URL(fileURLWithPath: "/x"), arguments: [], workingDirectory: URL(fileURLWithPath: "/"),
                          codename: "WoW", region: .us, locale: nil)
    #expect(plan.gameAccount == nil)
    #expect(!plan.keepsStoredGameAccount)
}
