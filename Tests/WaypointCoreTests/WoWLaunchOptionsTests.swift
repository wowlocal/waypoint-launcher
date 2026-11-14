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
    try body(LaunchOptions(gameKey: gameKey, userName: "testuser", preferencesDomain: suite), defaults)
}

@Test func launchOptionsDefaultToNetBattle() {
    #expect(LaunchOptions(gameKey: "WoW").preferencesDomain == "net.battle")
}

@Test func selectedLicenceIsWrittenWithItsToken() throws {
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

@Test func automaticHandoffClearsALicenceFromAnotherRegion() throws {
    try withOptions { options, _ in
        try options.write(token: tokenA, region: .us, locale: "enUS", gameAccount: "WoW2")
        try options.write(token: tokenA, region: .eu, locale: nil, gameAccount: nil)
        #expect(options.storedGameAccount() == nil)
        #expect(options.storedRegion() == "EU")
        // Locale still only changes when given.
        #expect(options.storedLocale() == "enUS")
    }
}

@Test func automaticHandoffClearsALicenceFromAnotherAccount() throws {
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

@Test func automaticHandoffClearsALicenceBattleNetLeftBehind() throws {
    try withOptions { options, defaults in
        defaults.set("WoW3", forKey: options.gameAccountKey)
        try options.write(token: tokenA, region: .us, locale: nil)
        #expect(options.storedGameAccount() == nil)
    }
}

@Test func cliReplayKeepsOnlyTheSameRegionsValidatedLicence() throws {
    try withOptions { options, defaults in
        let a = try #require(LoginToken(tokenA))
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        #expect(options.storedGameAccount(for: .us, token: a) == "WoW2")
        #expect(options.storedGameAccount(for: .eu, token: a) == nil)
        defaults.set("WoW2\n", forKey: options.gameAccountKey)
        #expect(options.storedGameAccount(for: .us, token: a) == nil)
    }
}

@Test func cliReplayKeepsOnlyTheTokenOwnersLicence() throws {
    try withOptions { options, defaults in
        let a = try #require(LoginToken(tokenA)), b = try #require(LoginToken(tokenB))
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == "111")
        #expect(options.storedGameAccount(for: .us, token: a) == "WoW2")
        // Battle.net signed another account in and left Waypoint's licence.
        #expect(options.storedGameAccount(for: .us, token: b) == nil)
        // A licence without Waypoint's owner note (Battle.net's, or an
        // older Waypoint's) isn't replayed either.
        defaults.removeObject(forKey: options.gameAccountOwnerKey)
        #expect(options.storedGameAccount(for: .us, token: a) == nil)
        // An automatic launch and Sign Out clear the note with the licence.
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: nil)
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
        try options.write(token: tokenA, region: .us, locale: nil, gameAccount: "WoW2")
        options.clearToken()
        #expect(defaults.string(forKey: options.gameAccountOwnerKey) == nil)
    }
}

@Test func malformedLicenceNameWritesNothing() throws {
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

@Test func clearingTheTokenAlsoClearsTheLicence() throws {
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
}
