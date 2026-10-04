import Foundation
import Testing
@testable import WaypointCore

@Test func signingInAddsAndActivatesAccounts() {
    var list = AccountList()
    let a = WebSessionID.fresh(), b = WebSessionID.fresh()
    #expect(list.signedIn("1", session: a) == nil)
    #expect(list.signedIn("2", session: b) == nil)
    #expect(list.accounts.map(\.id) == ["1", "2"])
    #expect(list.active?.id == "2")

    list.activate("1")
    #expect(list.active?.id == "1")
    list.activate("missing")
    #expect(list.active?.id == "1")
}

@Test func signingInAgainMovesTheAccountToTheNewSession() {
    var list = AccountList()
    let old = WebSessionID.fresh(), new = WebSessionID.fresh()
    list.signedIn("1", session: old)
    #expect(list.signedIn("1", session: new) == old)
    #expect(list["1"]?.session == new)
    #expect(list.signedIn("1", session: new) == nil)
    #expect(list.accounts.count == 1)
}

@Test func aSessionBelongsToWhoeverSignedInToIt() {
    var list = AccountList()
    let shared = WebSessionID.shared, other = WebSessionID.fresh()
    list.signedIn("1", session: shared)
    list.signedIn("2", session: other)
    // Account 2 signs in to account 1's session: 1 needs a new one.
    #expect(list.signedIn("2", session: shared) == other)
    #expect(list["2"]?.session == shared)
    let moved = list["1"]?.session
    #expect(moved != shared && moved != other)
}

@Test func removingTheActiveAccountActivatesTheNext() {
    var list = AccountList()
    list.signedIn("1", session: .fresh())
    list.signedIn("2", session: .fresh())
    list.activate("1")
    #expect(list.remove("1")?.id == "1")
    #expect(list.active?.id == "2")
    #expect(list.remove("1") == nil)
    list.remove("2")
    #expect(list.active == nil && list.accounts.isEmpty)
}

@Test func accountsGetDistinctTints() {
    var list = AccountList()
    for id in 1...AccountTint.allCases.count { list.signedIn("\(id)", session: .fresh()) }
    #expect(list.accounts.map(\.tint) == AccountTint.allCases)
    // A freed tint goes to the next new account.
    let freed = list.remove("3")?.tint
    list.signedIn("new", session: .fresh())
    #expect(list["new"]?.tint == freed)
    // Signing in again keeps the tint.
    list.signedIn("1", session: .fresh())
    #expect(list["1"]?.tint == .blue)
}

@Test func accountNamesFallBackToEmailThenID() {
    var list = AccountList()
    list.signedIn("42", session: .shared)
    #expect(list["42"]?.displayName == "Account 42")
    list.setProfile("42", battleTag: nil, email: "a@example.com")
    #expect(list["42"]?.displayName == "a@example.com")
    list.setProfile("42", battleTag: "Name#1234", email: nil)
    #expect(list["42"]?.displayName == "Name#1234")
    #expect(list["42"]?.email == "a@example.com")
}

@Test func accountListSurvivesSaving() throws {
    let suite = "WaypointCoreTests.accounts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var list = AccountList()
    list.signedIn("1", session: .shared)
    list.signedIn("2", session: .fresh())
    list.setProfile("2", battleTag: "Name#1234", email: "a@example.com")
    list.activate("1")
    list.save(to: defaults)
    #expect(AccountList.load(from: defaults) == list)
    #expect(AccountList.load(from: UserDefaults(suiteName: suite + ".empty")!) == AccountList())
}

@Test func tokenVaultKeepsTokensPerAccountAndGame() throws {
    let vault = TokenVault(service: "WaypointCoreTests \(UUID().uuidString)")
    let first = try #require(LoginToken("EU-0123456789abcdef0123456789abcdef-111"))
    let newer = try #require(LoginToken("US-fedcba9876543210fedcba9876543210-111"))
    let other = try #require(LoginToken("EU-0123456789abcdef0123456789abcdef-222"))
    defer {
        vault.removeAll(account: "111")
        vault.removeAll(account: "222")
    }
    try vault.save(first, codename: "WTCG")
    try vault.save(other, codename: "WTCG")
    try vault.save(newer, codename: "WTCG")
    try vault.save(first, codename: "WoW")
    #expect(vault.token(account: "111", codename: "WTCG") == newer)
    #expect(vault.token(account: "111", codename: "WoW") == first)
    #expect(vault.token(account: "222", codename: "WTCG") == other)
    #expect(vault.token(account: "222", codename: "WoW") == nil)
    vault.removeAll(account: "111")
    #expect(vault.token(account: "111", codename: "WTCG") == nil)
    #expect(vault.token(account: "222", codename: "WTCG") == other)
}
