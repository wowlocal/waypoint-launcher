import Foundation
import Testing
@testable import WaypointCore

@Test func automaticUpdateChecksDefaultOnButRespectOptOut() throws {
    let suite = "WaypointCoreTests.updatePreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(UpdatePreferences.automatic(in: defaults))
    defaults.set(false, forKey: UpdatePreferences.automaticKey)
    #expect(!UpdatePreferences.automatic(in: defaults))
    defaults.set(true, forKey: UpdatePreferences.automaticKey)
    #expect(UpdatePreferences.automatic(in: defaults))
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
    let result1 = schedule.request(force: false, automatic: true, now: now)
    #expect(result1)
    let result2 = !schedule.request(force: true, automatic: true, now: now)
    #expect(result2)
    let result3 = !schedule.request(force: true, automatic: true, now: now)
    #expect(result3)
    // A completed install requests force:true while another title is waiting.
    let result4 = schedule.complete(now: now)
    #expect(result4)
    let result5 = !schedule.complete(now: now)
    #expect(result5)
    let result6 = !schedule.request(force: false, automatic: true, now: now.addingTimeInterval(899))
    #expect(result6)
    let result7 = schedule.request(force: false, automatic: true, now: now.addingTimeInterval(900))
    #expect(result7)
    let result8 = !schedule.complete(now: now)
    #expect(result8)
}

@Test func automaticOptOutStillAllowsManualCheckAndCancellationAllowsRetry() {
    var schedule = UpdateCheckSchedule()
    let result9 = !schedule.request(force: false, automatic: false)
    #expect(result9)
    let result10 = schedule.request(force: true, automatic: false)
    #expect(result10)
    schedule.cancel()
    let result11 = schedule.request(force: true, automatic: false)
    #expect(result11)
}
