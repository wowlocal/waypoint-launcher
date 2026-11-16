import Foundation
import Testing
@testable import WaypointCore

private func automaticUpdateCalendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func automaticUpdateDate(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

@Test func automaticUpdatesAreOffUntilEachGameIsChosen() throws {
    let suite = "WaypointCoreTests.automaticUpdates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = AutomaticUpdatePreferences.load(defaults: defaults)
    #expect(preferences == AutomaticUpdatePreferences())
    #expect(!preferences.allowsUpdate(gameID: "wow", build: "build-a"))
    preferences.enabledGames = ["wow"]
    #expect(preferences.allowsUpdate(gameID: "wow", build: "build-a"))
    #expect(!preferences.allowsUpdate(gameID: "wow_classic", build: "build-a"))
    #expect(!preferences.allowsUpdate(gameID: "wow", build: ""))
}

@Test func automaticUpdateChoicesAndSkippedBuildsSurviveRestart() throws {
    let suite = "WaypointCoreTests.automaticUpdates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow", "heroes@windows"]
    preferences.usesTimeWindow = true
    preferences.startMinute = 22 * 60
    preferences.endMinute = 6 * 60
    preferences.skippedBuilds = ["wow": "build-a"]
    preferences.save(defaults: defaults)
    #expect(AutomaticUpdatePreferences.load(defaults: defaults) == preferences)
}

@Test func malformedAutomaticUpdatePreferencesFailClosed() throws {
    let suite = "WaypointCoreTests.automaticUpdates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for data in [Data("not json".utf8), Data("{}".utf8),
                 Data(#"{"version":1,"preferences":{"enabledGames":["wow"],"usesTimeWindow":true,"startMinute":-1,"endMinute":360,"skippedBuilds":{}}}"#.utf8),
                 Data(#"{"version":2,"preferences":{"enabledGames":["wow"],"usesTimeWindow":false,"startMinute":120,"endMinute":360,"skippedBuilds":{}}}"#.utf8)] {
        defaults.set(data, forKey: AutomaticUpdatePreferences.defaultsKey)
        #expect(AutomaticUpdatePreferences.load(defaults: defaults).enabledGames.isEmpty)
    }
    defaults.set(["enabledGames": ["wow"]], forKey: AutomaticUpdatePreferences.defaultsKey)
    #expect(AutomaticUpdatePreferences.load(defaults: defaults).enabledGames.isEmpty)
}

@Test func invalidAutomaticUpdateWindowCannotBecomeUnrestricted() throws {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow"]
    preferences.startMinute = -1
    #expect(!preferences.allowsDownloads())
    #expect(!preferences.allowsUpdate(gameID: "wow", build: "build-a"))
    #expect(preferences.nextBoundary() == nil)
    let suite = "WaypointCoreTests.automaticUpdates.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    preferences.save(defaults: defaults)
    #expect(AutomaticUpdatePreferences.load(defaults: defaults).enabledGames.isEmpty)
}

@Test func automaticUpdateDaytimeWindowIncludesStartAndExcludesEnd() {
    var preferences = AutomaticUpdatePreferences()
    preferences.usesTimeWindow = true
    let calendar = automaticUpdateCalendar()
    #expect(!preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T01:59:59Z"), calendar: calendar))
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T02:00:00Z"), calendar: calendar))
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T05:59:59Z"), calendar: calendar))
    #expect(!preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T06:00:00Z"), calendar: calendar))
}

@Test func automaticUpdateWindowCanCrossMidnight() {
    var preferences = AutomaticUpdatePreferences()
    preferences.usesTimeWindow = true
    preferences.startMinute = 22 * 60
    let calendar = automaticUpdateCalendar()
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T22:00:00Z"), calendar: calendar))
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-17T00:00:00Z"), calendar: calendar))
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-17T05:59:59Z"), calendar: calendar))
    #expect(!preferences.allowsDownloads(at: automaticUpdateDate("2026-11-17T06:00:00Z"), calendar: calendar))
    #expect(!preferences.allowsDownloads(at: automaticUpdateDate("2026-11-17T21:59:59Z"), calendar: calendar))
}

@Test func identicalAutomaticUpdateTimesMeanAllDay() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow"]
    preferences.usesTimeWindow = true
    preferences.endMinute = preferences.startMinute
    #expect(preferences.allowsDownloads(at: automaticUpdateDate("2026-11-16T12:00:00Z")))
    #expect(preferences.nextBoundary() == nil)
}

@Test func cancellingOneAutomaticBuildDoesNotBlockFutureBuildsOrOtherGames() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow", "heroes@windows"]
    preferences.skippedBuilds["wow"] = "build-a"
    #expect(!preferences.allowsUpdate(gameID: "wow", build: "build-a"))
    #expect(preferences.allowsUpdate(gameID: "wow", build: "build-b"))
    #expect(preferences.allowsUpdate(gameID: "heroes@windows", build: "build-a"))
}

@Test func automaticUpdateTimerFindsNextBoundaryWithoutRepeatingCurrentBoundary() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow"]
    let calendar = automaticUpdateCalendar()
    #expect(preferences.nextBoundary(after: automaticUpdateDate("2026-11-16T00:00:00Z"), calendar: calendar) == nil)
    preferences.usesTimeWindow = true
    #expect(preferences.nextBoundary(after: automaticUpdateDate("2026-11-16T00:00:00Z"), calendar: calendar) == automaticUpdateDate("2026-11-16T02:00:00Z"))
    #expect(preferences.nextBoundary(after: automaticUpdateDate("2026-11-16T02:00:00Z"), calendar: calendar) == automaticUpdateDate("2026-11-16T06:00:00Z"))
    #expect(preferences.nextBoundary(after: automaticUpdateDate("2026-11-16T06:00:00Z"), calendar: calendar) == automaticUpdateDate("2026-11-17T02:00:00Z"))
    preferences.enabledGames = []
    #expect(preferences.nextBoundary(after: automaticUpdateDate("2026-11-16T00:00:00Z"), calendar: calendar) == nil)
}

@Test func automaticUpdatesFollowLocalTimeAcrossSpringClockChange() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow"]
    preferences.usesTimeWindow = true
    preferences.startMinute = 90
    preferences.endMinute = 180
    let calendar = automaticUpdateCalendar("Europe/London")
    let before = automaticUpdateDate("2026-03-29T00:59:59Z")
    let transition = automaticUpdateDate("2026-03-29T01:00:00Z")
    #expect(!preferences.allowsDownloads(at: before, calendar: calendar))
    #expect(preferences.nextBoundary(after: before, calendar: calendar) == transition)
    #expect(preferences.allowsDownloads(at: transition, calendar: calendar))
    #expect(preferences.nextBoundary(after: transition, calendar: calendar) == automaticUpdateDate("2026-03-29T02:00:00Z"))
}

@Test func automaticUpdatesReevaluateBothOccurrencesOfRepeatedAutumnHour() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = ["wow"]
    preferences.usesTimeWindow = true
    preferences.startMinute = 90
    preferences.endMinute = 150
    let calendar = automaticUpdateCalendar("Europe/London")
    let first0145 = automaticUpdateDate("2026-10-25T00:45:00Z")
    let repeated0100 = automaticUpdateDate("2026-10-25T01:00:00Z")
    let second0130 = automaticUpdateDate("2026-10-25T01:30:00Z")
    #expect(preferences.allowsDownloads(at: first0145, calendar: calendar))
    #expect(preferences.nextBoundary(after: first0145, calendar: calendar) == repeated0100)
    #expect(!preferences.allowsDownloads(at: repeated0100, calendar: calendar))
    #expect(preferences.nextBoundary(after: repeated0100, calendar: calendar) == second0130)
    #expect(preferences.allowsDownloads(at: second0130, calendar: calendar))
    #expect(preferences.nextBoundary(after: second0130, calendar: calendar) == automaticUpdateDate("2026-10-25T02:30:00Z"))
}
