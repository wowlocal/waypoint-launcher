import Foundation
import Testing
@testable import WaypointCore

private let repeated = "I 21:19:08.5600630 A repeated token was retrieved when disallowed. Setting to null token for failure"
private let exhausted = "E 21:19:08.6019140 Failed to get token to respond to login challenge"
private let accepted = "I 21:20:29.9177840 We are now logged in, stopping processing challenges"

@Test(arguments: [
    ("\(repeated)\n\(exhausted)\n", HearthstoneLogin.Outcome.challengeExhausted),
    ("\(repeated)\r\n\(exhausted)\r\n", .challengeExhausted),
    ("\(accepted)\n", .signedIn),
    ("\(repeated)\n\(accepted)\n", .signedIn),
    ("\(exhausted)\n\(accepted)\n", .signedIn),
    ("\(exhausted)\n\(repeated)\n\(exhausted)\n", .challengeExhausted),
    ("\(repeated)\n\(exhausted)\n\(accepted)\n", .signedIn),
    ("\(exhausted)\n", nil),
    ("\(repeated)\n\(exhausted)", nil),
    ("I 21:19:07.1604330 LoginService LoginService.UpdateStatus:Success\n", nil),
])
func hearthstoneLoginOutcome(log: String, expected: HearthstoneLogin.Outcome?) {
    #expect(HearthstoneLogin.outcome(in: Data(log.utf8)) == expected)
}

@Test func hearthstoneRecoveryIgnoresUnverifiedMarkersFromEarlierBuild() throws {
    let suite = "WaypointCoreTests.hearthstoneLogin.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // A previous test build used this key before checking handoff attribution.
    let attempted = try #require(LoginToken("EU-0123456789abcdef0123456789abcdef-1"))
    var old = HearthstoneLoginRecovery.load(from: defaults)
    old.reject(attempted, region: .eu, needsManualSignIn: false)
    defaults.set(try JSONEncoder().encode(old), forKey: "hearthstoneLoginRecovery")
    #expect(HearthstoneLoginRecovery.load(from: defaults).action(for: attempted, region: .eu) == nil)
}

@Test func hearthstoneHandoffCheckRequiresExactTokenAndRegion() throws {
    let attempted = try #require(LoginToken("EU-0123456789abcdef0123456789abcdef-1"))
    let replacement = try #require(LoginToken("EU-0123456789abcdef0123456789abcdea-1"))
    let domain = "WaypointCoreTests.hearthstoneHandoff.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: domain))
    defer { preferences.removePersistentDomain(forName: domain) }
    let options = LaunchOptions(gameKey: "WTCG", userName: "test-user", preferencesDomain: domain)

    #expect(!options.matchesHandoff(token: attempted, region: .eu))
    try options.write(token: attempted.value, region: .eu, locale: nil)
    #expect(options.matchesHandoff(token: attempted, region: .eu))
    #expect(!options.matchesHandoff(token: attempted, region: .us))
    try options.write(token: replacement.value, region: .eu, locale: nil)
    #expect(!options.matchesHandoff(token: attempted, region: .eu))
}

@Test(arguments: [false, true])
func hearthstoneLoginUsesOnlyTheNewLogOpenedByItsProcess(writesFailedChallengeFirst: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("waypoint-hs-login-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("Logs/Hearthstone_old", isDirectory: true)
    let current = root.appendingPathComponent("Logs/Hearthstone_current", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try "\(repeated)\n\(exhausted)\n".write(to: old.appendingPathComponent("Login.log"), atomically: false, encoding: .utf8)

    let launchedAt = Date()
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: "/bin/sh")
    writer.arguments = ["-c", """
        exec 3<"$1" 4>"$2"
        if [ -n "$4" ]; then
            printf '%s\\n' "$4" >&4
            sleep 1
        fi
        printf '%s\\n' "$3" >&4
        exec sleep 5
        """,
                        "hearthstone-log-test", old.appendingPathComponent("Login.log").path,
                        current.appendingPathComponent("Login.log").path, accepted,
                        writesFailedChallengeFirst ? "\(repeated)\n\(exhausted)" : ""]
    try writer.run()
    defer {
        if writer.isRunning { writer.terminate() }
        writer.waitUntilExit()
    }
    let (outcome, _) = await HearthstoneLogin.observe(pid: writer.processIdentifier, in: root, launchedAt: launchedAt)
    #expect(outcome == .signedIn)
}

@Test func hearthstoneRejectionMatchesExactTokenAccountAndRegionAcrossRestarts() throws {
    let first = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-1"))
    let replacement = try #require(LoginToken("US-0123456789abcdef0123456789abcdea-1"))
    let other = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-2"))
    let suite = "WaypointCoreTests.hearthstoneLogin.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var recovery = HearthstoneLoginRecovery.load(from: defaults)
    #expect(recovery.action(for: first, region: .eu) == nil)
    recovery.reject(first, region: .eu, needsManualSignIn: false)
    recovery.save(to: defaults)
    recovery = HearthstoneLoginRecovery.load(from: defaults)
    #expect(recovery.action(for: first, region: .eu) == .refresh)
    #expect(recovery.action(for: first, region: .us) == nil)
    #expect(recovery.action(for: other, region: .eu) == nil)
    #expect(recovery.action(for: replacement, region: .eu) == nil)

    recovery.reject(replacement, region: .eu, needsManualSignIn: true)
    #expect(recovery.action(for: replacement, region: .eu) == .signInAgain)
    recovery.reject(other, region: .eu, needsManualSignIn: false)
    recovery.clear(for: replacement, region: .eu)
    #expect(recovery.action(for: replacement, region: .eu) == nil)
    #expect(recovery.action(for: other, region: .eu) == .refresh)
    recovery.remove(owner: other.accountID)
    #expect(recovery.action(for: other, region: .eu) == nil)
}

@Test func hearthstoneFailedUnsavedReplacementStopsRefreshingTheOldToken() throws {
    let old = try #require(LoginToken("EU-0123456789abcdef0123456789abcdef-1"))
    let replacement = try #require(LoginToken("EU-0123456789abcdef0123456789abcdea-1"))
    let suite = "WaypointCoreTests.hearthstoneLogin.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var recovery = HearthstoneLoginRecovery.load(from: defaults)
    recovery.recordRejection(of: old, region: .eu, usedCache: true, saved: true, replacing: nil)
    #expect(recovery.action(for: old, region: .eu) == .refresh)
    // A sign-in with a different token can't clear an old rejection while
    // that old token may still be in Keychain.
    recovery.clear(for: replacement, region: .eu)
    #expect(recovery.action(for: old, region: .eu) == .refresh)
    recovery.recordRejection(of: replacement, region: .eu, usedCache: false, saved: false, replacing: old)
    recovery.save(to: defaults)
    recovery = HearthstoneLoginRecovery.load(from: defaults)
    #expect(recovery.action(for: old, region: .eu) == .signInAgain)
    #expect(recovery.action(for: replacement, region: .eu) == nil)
}
