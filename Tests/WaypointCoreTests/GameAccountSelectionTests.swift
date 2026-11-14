import Foundation
import Testing
@testable import WaypointCore

@Test func gameAccountChoiceIsScopedToOwnerEditionAndRegion() {
    var choices = GameAccountSelections()
    let one = GameAccountSelection(accountID:"101",name:"WoW1",region:"us")
    let two = GameAccountSelection(accountID:"102",name:"WoW2",region:"us")
    choices.select(one,owner:"owner-a",uid:"wowf",region:"US")
    choices.select(two,owner:"owner-a",uid:"wow",region:"us")
    #expect(choices.choice(owner:"owner-a",uid:"wowf",region:"us") == one)
    #expect(choices.choice(owner:"owner-a",uid:"wow",region:"US") == two)
    #expect(choices.choice(owner:"owner-b",uid:"wowf",region:"us") == nil)
    #expect(choices.choice(owner:"owner-a",uid:"wowf",region:"eu") == nil)
}
@Test func selectedGameAccountSurvivesRestartAndOwnerRemovalIsIsolated() throws {
    let suite="WaypointCoreTests.gameChoices.\(UUID().uuidString)"
    let defaults=try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    var choices=GameAccountSelections()
    let one=GameAccountSelection(accountID:"101",name:"WoW1",region:"us")
    let two=GameAccountSelection(accountID:"102",name:"WoW2",region:"us")
    choices.select(one,owner:"owner-a",uid:"wowf",region:"us")
    choices.select(two,owner:"owner-a",uid:"wowf",region:"us")
    choices.select(one,owner:"owner-b",uid:"wowf",region:"us")
    choices.save(to:defaults)
    var loaded=GameAccountSelections.load(from:defaults)
    #expect(loaded.choice(owner:"owner-a",uid:"wowf",region:"us") == two)
    loaded.remove(owner:"owner-a")
    #expect(loaded.choice(owner:"owner-a",uid:"wowf",region:"us") == nil)
    #expect(loaded.choice(owner:"owner-b",uid:"wowf",region:"us") == one)
}
@Test func explicitGameAccountHandoffReplacesPreviousSelectionWithMatchingToken() throws {
    let suite="WaypointCoreTests.gameHandoff.\(UUID().uuidString)"
    let defaults=try #require(UserDefaults(suiteName:suite))
    defer { defaults.removePersistentDomain(forName:suite) }
    let options=LaunchOptions(gameKey:"WoW",userName:"testuser",preferencesDomain:suite)
    let one="US-0123456789abcdef0123456789abcdef-111"
    let two="US-fedcba9876543210fedcba9876543210-222"
    try options.write(token:one,region:.us,locale:"enUS",gameAccount:"WoW1")
    #expect(defaults.string(forKey:options.gameAccountKey) == "WoW1")
    try options.write(token:two,region:.eu,locale:"enGB",gameAccount:"WoW2")
    #expect(defaults.string(forKey:options.gameAccountKey) == "WoW2")
    #expect(try options.storedToken() == two)
    #expect(options.storedRegion() == "EU")
    #expect(options.storedLocale() == "enGB")
}

@Test func unselectedWoWLaunchClearsPreviousOwnerAndRegionLicence() throws {
    let suite = "WaypointCoreTests.unselectedGameHandoff.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let options = LaunchOptions(gameKey: "WoW", userName: "testuser", preferencesDomain: suite)
    try options.write(token: "US-0123456789abcdef0123456789abcdef-111", region: .us, locale: "enUS", gameAccount: "WoW1")
    #expect(defaults.string(forKey: options.gameAccountKey) == "WoW1")
    let newOwner = "US-fedcba9876543210fedcba9876543210-222"
    try options.write(token: newOwner, region: .eu, locale: "enGB")
    #expect(defaults.string(forKey: options.gameAccountKey) == nil)
    #expect(try options.storedToken() == newOwner)
    #expect(options.storedRegion() == "EU")
}
