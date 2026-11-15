import Foundation
import Testing
@testable import WaypointCore

@Test func backgroundPreferencesAreOffByDefault() throws {
    let suite = "WaypointCoreTests.updatePreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!defaults.bool(forKey: UpdatePreferences.notificationsKey))
    #expect(!defaults.bool(forKey: UpdatePreferences.hideDockKey))
}

@Test func updateAlertsRetryUntilRecordedAndPersistAcrossLaunches() throws {
    let suite = "WaypointCoreTests.updateAlerts.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let ledger = UpdateAlertLedger(defaults: defaults)
    #expect(ledger.needsAlert(id: "game:wow", build: "build-a"))
    // Denied permissions or a scheduling failure never call record.
    #expect(ledger.needsAlert(id: "game:wow", build: "build-a"))
    ledger.record(id: "game:wow", build: "build-a")
    #expect(!UpdateAlertLedger(defaults: defaults).needsAlert(id: "game:wow", build: "build-a"))
    #expect(ledger.needsAlert(id: "game:wow", build: "build-b"))
    #expect(ledger.needsAlert(id: "game:wowf", build: "build-a"))
    #expect(ledger.needsAlert(id: "waypoint", build: "build-a"))
}

@Test func forcedRefreshDuringBackgroundPassIsCoalescedButNeverLost() {
    var schedule = UpdateCheckSchedule()
    let now = Date(timeIntervalSince1970: 10000)
    let first = schedule.request(force: false, now: now)
    // A completed install asks for a forced pass while another is running.
    let forcedWhileRunning = schedule.request(force: true, now: now)
    let forcedAgain = schedule.request(force: true, now: now)
    let runsFollowUp = schedule.complete(now: now)
    let followUpDone = schedule.complete(now: now)
    #expect(first && !forcedWhileRunning && !forcedAgain && runsFollowUp && !followUpDone)
    // Unforced checks stay throttled to every 15 minutes.
    let tooSoon = schedule.request(force: false, now: now.addingTimeInterval(899))
    let later = schedule.request(force: false, now: now.addingTimeInterval(900))
    #expect(!tooSoon && later)
}

@Test func cancellationAllowsRetry() {
    var schedule = UpdateCheckSchedule()
    let first = schedule.request(force: true)
    schedule.cancel()
    let retry = schedule.request(force: true)
    #expect(first && retry)
}
