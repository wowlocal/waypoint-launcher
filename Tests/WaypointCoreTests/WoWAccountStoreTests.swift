import Foundation
import Testing
@testable import WaypointCore

private let wow1 = WoWGameAccount(id: "101", name: "WoW1")
private let wow2 = WoWGameAccount(id: "102", name: "WoW2")

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "WaypointCoreTests.wowAccounts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Test func wowSelectionIsScopedToOwnerEditionAndRegion() {
    var store = WoWAccountStore()
    store.select(wow1, owner: "1", uid: "wow", region: .us)
    store.select(wow2, owner: "1", uid: "wow_classic", region: .us)
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow1)
    #expect(store.selected(owner: "1", uid: "wow_classic", region: .us) == wow2)
    #expect(store.selected(owner: "2", uid: "wow", region: .us) == nil)
    #expect(store.selected(owner: "1", uid: "wow", region: .eu) == nil)
    #expect(store.selected(owner: "1", uid: "wow_classic_era", region: .us) == nil)
}

@Test func choosingAutomaticRemovesOnlyThatSelection() {
    var store = WoWAccountStore()
    store.select(wow2, owner: "1", uid: "wow", region: .us)
    store.select(wow2, owner: "1", uid: "wow", region: .eu)
    store.select(wow1, owner: "1", uid: "wow", region: .us)
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow1)
    do { let ok = store.select(nil, owner: "1", uid: "wow", region: .us); #expect(ok) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
    #expect(store.selected(owner: "1", uid: "wow", region: .eu) == wow2)
}

@Test func wowAccountsSurviveRestartAndSignOutIsIsolated() throws {
    try withDefaults { defaults in
        var store = WoWAccountStore()
        store.cache([wow1, wow2], owner: "1", region: .us)
        store.cache([wow1], owner: "2", region: .us)
        store.select(wow2, owner: "1", uid: "wow", region: .us)
        store.select(wow1, owner: "2", uid: "wow", region: .us)
        store.save(to: defaults)

        var loaded = WoWAccountStore.load(from: defaults)
        #expect(loaded == store)
        #expect(loaded.selected(owner: "1", uid: "wow", region: .us) == wow2)
        #expect(loaded.cachedAccounts(owner: "1", region: .us) == [wow1, wow2])

        loaded.remove(owner: "1")
        loaded.save(to: defaults)
        let after = WoWAccountStore.load(from: defaults)
        #expect(after.selected(owner: "1", uid: "wow", region: .us) == nil)
        #expect(after.cachedAccounts(owner: "1", region: .us).isEmpty)
        #expect(after.selected(owner: "2", uid: "wow", region: .us) == wow1)
        #expect(after.cachedAccounts(owner: "2", region: .us) == [wow1])
    }
}

@Test func refreshingKnownAccountsNeverChangesTheChoice() {
    var store = WoWAccountStore()
    store.cache([wow1, wow2], owner: "1", region: .us)
    store.select(wow2, owner: "1", uid: "wow", region: .us)
    // A refresh that no longer lists WoW2 (or lists nothing) keeps it chosen.
    do { let ok = store.cache([wow1], owner: "1", region: .us); #expect(ok) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow2)
    do { let ok = store.cache([], owner: "1", region: .us); #expect(ok) }
    #expect(store.cachedAccounts(owner: "1", region: .us).isEmpty)
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow2)
}

private let us1 = WoWAccountScope(owner: "1", uid: "wow", region: .us)

@Test func aLookupWithOneLicenseChoosesIt() {
    var store = WoWAccountStore()
    do { let r = store.selectOnlyAccount(in: us1); #expect(r == nil, "no lookup yet") }
    store.cache([], owner: "1", region: .us)
    do { let r = store.selectOnlyAccount(in: us1); #expect(r == nil) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)

    store.cache([wow1], owner: "1", region: .us)
    do { let r = store.selectOnlyAccount(in: us1); #expect(r == wow1) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow1)
    // Only the edition the lookup ran for.
    #expect(store.selected(owner: "1", uid: "wow_classic", region: .us) == nil)

    // A license gone from the account is replaced by the only one left.
    store.select(wow2, owner: "1", uid: "wow_classic", region: .us)
    do { let r = store.selectOnlyAccount(in: WoWAccountScope(owner: "1", uid: "wow_classic", region: .us)); #expect(r == wow1) }
    #expect(store.selected(owner: "1", uid: "wow_classic", region: .us) == wow1)
}

@Test func aLookupWithSeveralLicensesLeavesTheChoiceAlone() {
    var store = WoWAccountStore()
    store.cache([wow1, wow2], owner: "1", region: .us)
    do { let r = store.selectOnlyAccount(in: us1); #expect(r == nil) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
    store.select(wow2, owner: "1", uid: "wow", region: .us)
    do { let r = store.selectOnlyAccount(in: us1); #expect(r == nil) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow2)
}

@Test func aMenuChoiceAppliesOnlyToTheScopeItWasBuiltFor() {
    var store = WoWAccountStore()
    store.cache([wow1, wow2], owner: "1", region: .us)
    store.cache([wow1, wow2], owner: "2", region: .us)
    store.cache([wow1, wow2], owner: "1", region: .eu)
    // Another account became active, or the play region changed.
    for current in [WoWAccountScope(owner: "2", uid: "wow", region: .us),
                    WoWAccountScope(owner: "1", uid: "wow", region: .eu), nil] {
        do { let r = store.select(wow2, in: us1, current: current); #expect(!r) }
        do { let r = store.select(nil, in: us1, current: current); #expect(!r) }
    }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
    #expect(store.selected(owner: "2", uid: "wow", region: .us) == nil)
    #expect(store.selected(owner: "1", uid: "wow", region: .eu) == nil)

    do { let r = store.select(wow2, in: us1, current: us1); #expect(r) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow2)
    // Only licences the last lookup listed.
    do { let r = store.select(WoWGameAccount(id: "103", name: "WoW3"), in: us1, current: us1); #expect(!r) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow2)
    do { let r = store.select(nil, in: us1, current: us1); #expect(r) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
}

@Test func knownAccountsArePerOwnerAndRegion() {
    var store = WoWAccountStore()
    store.cache([wow1, wow1, wow2], owner: "1", region: .us)
    #expect(store.cachedAccounts(owner: "1", region: .us) == [wow1, wow2])
    #expect(store.cachedAccounts(owner: "1", region: .eu).isEmpty)
    #expect(store.cachedAccounts(owner: "2", region: .us).isEmpty)
}

@Test func malformedAccountsAreRejectedWithoutLosingState() {
    var store = WoWAccountStore()
    store.cache([wow1], owner: "1", region: .us)
    store.select(wow1, owner: "1", uid: "wow", region: .us)
    let token = "US-0123456789abcdef0123456789abcdef-123456789"
    let bad = [
        WoWGameAccount(id: "", name: "WoW1"),
        WoWGameAccount(id: "1 2", name: "WoW1"),
        WoWGameAccount(id: "1", name: ""),
        WoWGameAccount(id: "1", name: "   "),
        WoWGameAccount(id: "1", name: " WoW1"),
        WoWGameAccount(id: "1", name: "WoW1 "),
        WoWGameAccount(id: "1", name: "WoW1\nWEB_TOKEN"),
        WoWGameAccount(id: "1", name: "WoW\u{0}1"),
        WoWGameAccount(id: "1", name: "WoW\u{202E}1"),
        WoWGameAccount(id: "1", name: String(repeating: "W", count: 65)),
        WoWGameAccount(id: "1", name: token),
        WoWGameAccount(id: token, name: "WoW1"),
        WoWGameAccount(id: "1", name: "ST=\(token)"),
        WoWGameAccount(id: "x\(token)", name: "WoW1"),
    ]
    for account in bad {
        #expect(!account.isValid, "\(account)")
        do { let ok = store.select(account, owner: "1", uid: "wow", region: .us); #expect(!ok) }
        do { let ok = store.cache([wow2, account], owner: "1", region: .us); #expect(!ok) }
    }
    do { let ok = store.select(wow2, owner: "", uid: "wow", region: .us); #expect(!ok) }
    do { let ok = store.select(wow2, owner: "1", uid: "wow\n", region: .us); #expect(!ok) }
    do { let ok = store.cache([wow2], owner: "1\t", region: .us); #expect(!ok) }
    let tooMany = (0...WoWAccountStore.maxAccounts).map { WoWGameAccount(id: "\($0)", name: "WoW\($0)") }
    do { let ok = store.cache(tooMany, owner: "1", region: .us); #expect(!ok) }
    #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow1)
    #expect(store.cachedAccounts(owner: "1", region: .us) == [wow1])
}

@Test func corruptWoWAccountDataLoadsAsAutomatic() throws {
    try withDefaults { defaults in
        for junk: Any in [Data("not json".utf8), "a string", 42, Data(count: WoWAccountStore.maxBytes + 1)] {
            defaults.set(junk, forKey: WoWAccountStore.defaultsKey)
            #expect(WoWAccountStore.load(from: defaults) == WoWAccountStore())
        }
        // Well-formed JSON with a tampered entry: only that entry is dropped.
        let json = """
        {"selections":[
          {"owner":"1","uid":"wow","region":"us","account":{"id":"101","name":"WoW1"}},
          {"owner":"1","uid":"wow","region":"eu","account":{"id":"102","name":"WoW2\\u0000"}}],
         "catalogs":[
          {"owner":"1","region":"us","accounts":[{"id":"101","name":"WoW1"}]},
          {"owner":"1","region":"eu","accounts":[{"id":"x y","name":"WoW2"}]}]}
        """
        defaults.set(Data(json.utf8), forKey: WoWAccountStore.defaultsKey)
        let store = WoWAccountStore.load(from: defaults)
        #expect(store.selected(owner: "1", uid: "wow", region: .us) == wow1)
        #expect(store.selected(owner: "1", uid: "wow", region: .eu) == nil)
        #expect(store.cachedAccounts(owner: "1", region: .us) == [wow1])
        #expect(store.cachedAccounts(owner: "1", region: .eu).isEmpty)
        // A region this build doesn't know costs only its own entries.
        var other = WoWAccountStore()
        other.cache([wow1], owner: "1", region: .us)
        other.select(wow1, owner: "1", uid: "wow", region: .us)
        other.select(wow2, owner: "1", uid: "wow", region: .eu)
        other.cache([wow2], owner: "1", region: .eu)
        other.save(to: defaults)
        let saved = String(decoding: try #require(defaults.data(forKey: WoWAccountStore.defaultsKey)), as: UTF8.self)
        defaults.set(Data(saved.replacingOccurrences(of: "\"eu\"", with: "\"xx\"").utf8), forKey: WoWAccountStore.defaultsKey)
        let survivor = WoWAccountStore.load(from: defaults)
        #expect(survivor.selected(owner: "1", uid: "wow", region: .us) == wow1)
        #expect(survivor.cachedAccounts(owner: "1", region: .us) == [wow1])
        #expect(survivor.selected(owner: "1", uid: "wow", region: .eu) == nil)
        #expect(survivor.cachedAccounts(owner: "1", region: .eu).isEmpty)
        // Missing top-level structure: automatic everywhere.
        defaults.set(Data(#"{"selections":[]}"#.utf8), forKey: WoWAccountStore.defaultsKey)
        #expect(WoWAccountStore.load(from: defaults) == WoWAccountStore())
    }
}

@Test func existingUsersStartOnAutomatic() throws {
    try withDefaults { defaults in
        let store = WoWAccountStore.load(from: defaults)
        #expect(store == WoWAccountStore())
        #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
    }
}

@Test func externalContributorPreferencesDoNotChangeUpgradeDefaults() throws {
    try withDefaults { defaults in
        let legacy = #"{"entries":[{"owner":"1","uid":"wow","region":"us","choice":{"accountID":"101","name":"WoW1","region":"us"}}]}"#
        defaults.set(Data(legacy.utf8), forKey: "gameAccountSelections")
        let store = WoWAccountStore.load(from: defaults)
        #expect(store.selected(owner: "1", uid: "wow", region: .us) == nil)
        #expect(store.cachedAccounts(owner: "1", region: .us).isEmpty)
        store.save(to: defaults)
        #expect(defaults.data(forKey: "gameAccountSelections") == Data(legacy.utf8))
    }
}

@Test func persistedWoWAccountsHoldNoTickets() throws {
    try withDefaults { defaults in
        var store = WoWAccountStore()
        store.cache([wow1, wow2], owner: "123456789", region: .us)
        store.select(wow2, owner: "123456789", uid: "wow", region: .us)
        store.save(to: defaults)
        let data = try #require(defaults.data(forKey: WoWAccountStore.defaultsKey))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["selections", "catalogs"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("WEB_TOKEN") && !text.contains("US-"))
    }
}

@Test func launchAccountComesFromTheTokensOwnAccount() throws {
    var store = WoWAccountStore()
    store.select(wow2, owner: "111", uid: "wow", region: .us)
    let a = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-111"))
    let b = try #require(LoginToken("US-fedcba9876543210fedcba9876543210-222"))
    #expect(store.launchAccount(for: a, uid: "wow", region: .us) == "WoW2")
    #expect(store.launchAccount(for: a, uid: "wow", region: .eu) == nil)
    #expect(store.launchAccount(for: b, uid: "wow", region: .us) == nil)
}
