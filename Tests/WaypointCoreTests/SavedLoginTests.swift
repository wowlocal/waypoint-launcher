import Foundation
import Testing
@testable import WaypointCore

@Test func savedPasswordsCanBeReplacedAndDeletedPerAccount() throws {
    let vault = CredentialVault(service: "WaypointCoreTests.passwords.\(UUID().uuidString)")
    defer {
        try? vault.remove(account: "1")
        try? vault.remove(account: "2")
    }
    let first = SavedCredentials(username: "first@example.com", password: "old password")
    let replacement = SavedCredentials(username: "first@example.com", password: "new ' \\ \" пароль")
    let other = SavedCredentials(username: "other@example.com", password: "other password")
    #expect(try vault.credentials(account: "1") == nil)
    try vault.save(first, account: "1")
    try vault.save(other, account: "2")
    try vault.save(replacement, account: "1")
    #expect(try vault.credentials(account: "1") == replacement)
    #expect(try vault.credentials(account: "2") == other)
    try vault.remove(account: "1")
    #expect(try vault.credentials(account: "1") == nil)
    #expect(try vault.credentials(account: "2") == other)
    try vault.remove(account: "1") // Forgetting twice is harmless.
}

@Test func autoLoginBacksOffAndStopsAfterThreeFailuresAcrossRestarts() throws {
    let suite = "WaypointCoreTests.autoLogin.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1000)
    var state = AutoLoginState()
    let firstAttempt = state.begin(at: start)
    #expect(firstAttempt)
    let immediateRetry = state.begin(at: start.addingTimeInterval(299))
    #expect(!immediateRetry)
    AutoLoginState.save(["1": state, "2": AutoLoginState()], to: defaults)
    state = try #require(AutoLoginState.load(from: defaults)["1"])
    let retryAfterRestart = state.begin(at: start)
    #expect(!retryAfterRestart)
    let secondAttempt = state.begin(at: start.addingTimeInterval(300))
    #expect(secondAttempt)
    state.failedTemporarily()
    let retryBeforeCooldown = state.begin(at: start.addingTimeInterval(1199))
    #expect(!retryBeforeCooldown)
    let thirdAttempt = state.begin(at: start.addingTimeInterval(1200))
    #expect(thirdAttempt)
    // Even a crash before the result of the third submission cannot retry.
    AutoLoginState.save(["1": state], to: defaults)
    state = try #require(AutoLoginState.load(from: defaults)["1"])
    #expect(state.isPaused)
    let fourthAttempt = state.begin(at: .distantFuture)
    #expect(!fourthAttempt)
    state.failedTemporarily()
    #expect(state.pauseReason == .tooManyFailures)
}

@Test func rejectedPasswordStaysPausedUntilExplicitReplacement() throws {
    var state = AutoLoginState()
    let firstAttempt = state.begin()
    #expect(firstAttempt)
    state.requiresSignIn()
    #expect(!state.canAttempt(at: .distantFuture))
    let decoded = try JSONDecoder().decode(AutoLoginState.self, from: JSONEncoder().encode(state))
    #expect(decoded.isPaused)
    #expect(!decoded.canAttempt(at: .distantFuture))
    state = AutoLoginState() // Explicitly saving replacement credentials.
    let newPasswordAttempt = state.begin()
    #expect(newPasswordAttempt)
    state.succeeded()
    #expect(state.attempts == 0)
    #expect(state.retryAfter == nil)
    #expect(state.canAttempt())
}

@Test func autoLoginPreferencesContainNoCredentialsAndAccountsAreIndependent() throws {
    var first = AutoLoginState(), second = AutoLoginState()
    first.begin()
    first.requiresSignIn()
    let otherAccountAttempt = second.begin()
    #expect(otherAccountAttempt)
    let json = String(decoding: try JSONEncoder().encode(["1": first, "2": second]), as: UTF8.self)
    #expect(!json.contains("username"))
    #expect(!json.contains("password"))
    #expect(!json.contains("email"))
    #expect(SavedCredentials(username: "secret", password: "secret").description == "SavedCredentials(redacted)")
}

@Test func credentialsOnlyGoToTheExpectedHTTPSLoginOrigin() {
    let host = "eu.battle.net"
    #expect(LoginForm.isTrusted(URL(string: "https://eu.battle.net/login/en/"), expectedHost: host))
    #expect(LoginForm.isTrusted(URL(string: "https://eu.battle.net:443/login"), expectedHost: host))
    for url in ["http://eu.battle.net/login/en/", "https://eu.battle.net.evil.com/login/en/",
                "https://evil.com/login/en/", "https://eu.battle.net:444/login/en/",
                "https://eu.battle.net/support/", "https://eu.battle.net/login-evil/",
                "https://user:password@eu.battle.net/login/en/", "about:blank"] {
        #expect(!LoginForm.isTrusted(URL(string: url), expectedHost: host))
    }
    #expect(!LoginForm.isTrusted(nil, expectedHost: host))
}
