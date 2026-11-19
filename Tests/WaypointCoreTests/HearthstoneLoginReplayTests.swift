import Foundation
import os
import Testing
@testable import WaypointCore

/// Replay sign-in at the process and preferences boundary. The shell process
/// writes the recorded client log and keeps its descriptor open as Hearthstone
/// does. The launcher writes synthetic tokens to a unique preferences domain.
@MainActor
private struct HearthstoneLoginReplay {
    let root: URL
    let defaults: UserDefaults
    let options: LaunchOptions
    let domain: String
    let region: Region = .eu

    init() throws {
        let id = UUID().uuidString
        let domain = "WaypointCoreTests.HearthstoneLoginReplay.\(id)"
        self.domain = domain
        defaults = try #require(UserDefaults(suiteName: domain))
        options = LaunchOptions(gameKey: "WTCG", userName: "replay", preferencesDomain: domain)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-hs-replay-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt",
                                                 subdirectory: "Fixtures/HearthstoneLogin"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func play(_ token: LoginToken, log: String, overwrittenBy anotherToken: LoginToken? = nil,
              processLifetime: String = "1", timeout: Duration = .seconds(15),
              otherLauncherAtHandoff: Bool = false,
              hasOtherLauncher: @Sendable () -> Bool = { false }) async throws -> HearthstoneLogin.Observation {
        let folder = root.appendingPathComponent("Logs/Hearthstone_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("replay.txt")
        try log.write(to: input, atomically: false, encoding: .utf8)
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", """
                                  exec 3>"$2"
                                  /bin/cat "$1" >&3
                                  exec /bin/sleep "$3"
                                  """, "hearthstone-replay", input.path,
                                          folder.appendingPathComponent("Login.log").path, processLifetime],
                              workingDirectory: root, codename: "WTCG", region: region, locale: nil)
        let launchedAt = Date()
        let pid = try GameLauncher.launch(plan, token: token, gameName: "Hearthstone Replay", options: options)
        #expect(options.matchesHandoff(token: token, region: region))
        if let anotherToken { try options.write(token: anotherToken.value, region: region, locale: nil) }
        return await HearthstoneLogin.check(pid: pid, in: root, launchedAt: launchedAt, options: options,
                                           token: token, region: region, timeout: timeout,
                                           otherLauncherAtHandoff: otherLauncherAtHandoff, hasOtherLauncher: hasOtherLauncher)
    }
}

@Test(arguments: [true, false])
@MainActor func hearthstoneLoginReplayRetriesOnce(replacementSucceeds: Bool) async throws {
    let old = try #require(LoginToken("EU-00000000000000000000000000000001-1"))
    let fresh = try #require(LoginToken("EU-00000000000000000000000000000002-1"))
    let rejected = try HearthstoneLoginReplay.fixture("rejected")
    let accepted = try HearthstoneLoginReplay.fixture("signed-in")
    let replay = try HearthstoneLoginReplay()
    defer { replay.cleanUp() }
    var recovery = HearthstoneLoginRecovery.load(from: replay.defaults)
    #expect(recovery.nextPlay(cached: old, region: replay.region) == .useCached(old))
    let failure = try await replay.play(old, log: rejected)
    #expect(failure.outcome == .challengeExhausted)
    #expect(failure.permitsRecovery)
    recovery.record(failure, for: old, region: replay.region, usedCache: true, saved: true, replacing: nil)
    recovery.save(to: replay.defaults)

    recovery = HearthstoneLoginRecovery.load(from: replay.defaults)
    guard case .signIn(let replacing) = recovery.nextPlay(cached: old, region: replay.region) else {
        Issue.record("The next Play did not request a new sign-in")
        return
    }
    #expect(replacing == old)
    // The sign-in boundary is simulated. The replacement is the same
    // account's test token, and acts as the value returned by the vault.
    let afterSignIn = try await replay.play(fresh, log: replacementSucceeds ? accepted : rejected)
    #expect(afterSignIn.outcome == (replacementSucceeds ? .signedIn : .challengeExhausted))
    recovery.record(afterSignIn, for: fresh, region: replay.region, usedCache: false, saved: true, replacing: replacing)
    recovery.save(to: replay.defaults)

    recovery = HearthstoneLoginRecovery.load(from: replay.defaults)
    if !replacementSucceeds {
        #expect(recovery.nextPlay(cached: fresh, region: replay.region) == .signInAgain)
        return
    }
    guard case .useCached(let cached) = recovery.nextPlay(cached: fresh, region: replay.region) else {
        Issue.record("The third Play did not reuse the new sign-in")
        return
    }
    #expect(cached == fresh)
    #expect(try await replay.play(cached, log: accepted).outcome == .signedIn)
}

private enum HearthstoneUncertainLogin: CaseIterable {
    case networkTimeout, competingLauncher, overwrittenHandoff
}

@Test(arguments: HearthstoneUncertainLogin.allCases)
@MainActor private func hearthstoneLoginReplayKeepsCacheWhenUncertain(scenario: HearthstoneUncertainLogin) async throws {
    let cached = try #require(LoginToken("EU-00000000000000000000000000000001-1"))
    let other = try #require(LoginToken("EU-00000000000000000000000000000001-2"))
    let replay = try HearthstoneLoginReplay()
    defer { replay.cleanUp() }
    // No captured network failure yet. This is a synthetic negative control.
    let log = scenario == .networkTimeout
        ? "E 22:06:40.9015560 Login connection timed out\n"
        : try HearthstoneLoginReplay.fixture("rejected")
    let observation = try await replay.play(cached, log: log, overwrittenBy: scenario == .overwrittenHandoff ? other : nil,
                                            otherLauncherAtHandoff: scenario == .competingLauncher)
    #expect(observation.outcome == (scenario == .networkTimeout ? nil : .challengeExhausted))
    #expect(!observation.permitsRecovery)
    var recovery = HearthstoneLoginRecovery.load(from: replay.defaults)
    recovery.record(observation, for: cached, region: replay.region, usedCache: true, saved: true, replacing: nil)
    #expect(recovery.nextPlay(cached: cached, region: replay.region) == .useCached(cached))
}

@Test @MainActor func hearthstoneLoginReplayRemembersTemporaryConflictThroughDeadline() async throws {
    let cached = try #require(LoginToken("EU-00000000000000000000000000000001-1"))
    let replay = try HearthstoneLoginReplay()
    defer { replay.cleanUp() }
    let rejected = try HearthstoneLoginReplay.fixture("rejected")
    let launcherChecks = OSAllocatedUnfairLock(initialState: [ContinuousClock.Instant]())
    let observation = try await replay.play(cached, log: rejected, processLifetime: "4", timeout: .milliseconds(2200)) {
        launcherChecks.withLock { checks in
            checks.append(.now)
            return checks.count == 2
        }
    }
    #expect(observation.outcome == .challengeExhausted)
    #expect(observation.otherLauncher == true)
    #expect(!observation.permitsRecovery)
    // The conflict was detected during the window, not by the final check.
    let foundAt = try #require(launcherChecks.withLock { $0.last })
    #expect(foundAt.duration(to: .now) >= .milliseconds(250))
}

@Test @MainActor func hearthstoneLoginReplayDoesNotClearRejectionOnUnattributedSuccess() async throws {
    let old = try #require(LoginToken("EU-00000000000000000000000000000001-1"))
    let other = try #require(LoginToken("EU-00000000000000000000000000000001-2"))
    let replay = try HearthstoneLoginReplay()
    defer { replay.cleanUp() }
    var recovery = HearthstoneLoginRecovery.load(from: replay.defaults)
    recovery.reject(old, region: replay.region, needsManualSignIn: false)
    let accepted = try HearthstoneLoginReplay.fixture("signed-in")
    let observation = try await replay.play(old, log: accepted, overwrittenBy: other)
    #expect(observation.outcome == .signedIn)
    #expect(observation.handoffMatches == false)
    recovery.record(observation, for: old, region: replay.region, usedCache: false, saved: true, replacing: nil)
    #expect(recovery.nextPlay(cached: old, region: replay.region) == .signIn(replacing: old))
}
