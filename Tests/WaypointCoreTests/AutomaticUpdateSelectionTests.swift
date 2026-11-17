import Foundation
import Testing
@testable import WaypointCore

private let retailUpdate = AutomaticUpdateCandidate(id: "wow", build: "retail-new", canStart: true, canResume: false)
private let classicUpdate = AutomaticUpdateCandidate(id: "wow_classic", build: "classic-new", canStart: true, canResume: false)

private func selectAutomaticUpdate(_ ordered: [AutomaticUpdateCandidate], preferences: AutomaticUpdatePreferences,
                                   active: Bool = false, batch: Bool = false, quitting: Bool = false,
                                   playing: Bool = false, at date: Date = Date()) -> AutomaticUpdateCandidate? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return AutomaticUpdateSelection.next(in: ordered, preferences: preferences, hasActiveDownloads: active,
                                          isUpdatingAll: batch, isQuitting: quitting, isPlaying: playing, at: date, calendar: calendar)
}

@Test func automaticUpdatePriorityFollowsLibraryOrderAndStartsOneAtATime() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    #expect(selectAutomaticUpdate([retailUpdate, classicUpdate], preferences: preferences) == retailUpdate)
    #expect(selectAutomaticUpdate([classicUpdate, retailUpdate], preferences: preferences) == classicUpdate)
    // Once the first starts, its active download excludes all other games.
    #expect(selectAutomaticUpdate([retailUpdate, classicUpdate], preferences: preferences, active: true) == nil)
    // Completing the first removes it from the pending candidates.
    #expect(selectAutomaticUpdate([classicUpdate], preferences: preferences) == classicUpdate)
}

@Test func automaticUpdatesWaitForManualDownloadsBatchesAndQuit() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id]
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, active: true) == nil)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, batch: true) == nil)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, quitting: true) == nil)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences) == retailUpdate)
}

@Test func automaticUpdatesWaitWhileAnyGameIsPlayed() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    var paused = retailUpdate
    paused.canStart = false
    paused.canResume = true
    // Any game running holds every automatic update, not just its own:
    // neither a new one nor a paused one starts.
    #expect(selectAutomaticUpdate([retailUpdate, classicUpdate], preferences: preferences, playing: true) == nil)
    #expect(selectAutomaticUpdate([paused], preferences: preferences, playing: true) == nil)
    // Once every game has quit, the paused one picks up where it stopped.
    #expect(selectAutomaticUpdate([paused, classicUpdate], preferences: preferences) == paused)
}

@Test func automaticUpdatesLeaveManualPausesAloneAndResumeSchedulerPauses() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    var paused = retailUpdate
    paused.canStart = false
    paused.canResume = false
    #expect(selectAutomaticUpdate([paused, classicUpdate], preferences: preferences) == classicUpdate)
    // The scheduler owns a pause made at the end of the download window.
    paused.canResume = true
    #expect(selectAutomaticUpdate([paused, classicUpdate], preferences: preferences) == paused)
    // A user Resume/Pause takes ownership away again.
    paused.canResume = false
    #expect(selectAutomaticUpdate([paused], preferences: preferences) == nil)
}

@Test func automaticUpdatesSkipBusyOrSharedFolderCandidatesWithoutBlockingOtherGames() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    var blocked = retailUpdate
    // AppModel clears both eligibility flags while a sibling is running,
    // paused, being removed, or cleaning shared CASC storage.
    blocked.canStart = false
    blocked.canResume = false
    #expect(selectAutomaticUpdate([blocked, classicUpdate], preferences: preferences) == classicUpdate)
    #expect(selectAutomaticUpdate([blocked], preferences: preferences) == nil)
}

@Test func cancelledAutomaticBuildCannotBeRecreatedButNextBuildIsEligible() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    preferences.skippedBuilds[retailUpdate.id] = retailUpdate.build
    #expect(selectAutomaticUpdate([retailUpdate, classicUpdate], preferences: preferences) == classicUpdate)
    var later = retailUpdate
    later.build = "retail-next"
    #expect(selectAutomaticUpdate([later, classicUpdate], preferences: preferences) == later)
}

@Test func automaticUpdatePreflightRechecksOptOutAndManualWorkBeforeStarting() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id]
    let chosen = selectAutomaticUpdate([retailUpdate], preferences: preferences)
    #expect(chosen == retailUpdate)
    // Reading a volume UUID suspends AppModel. The user's changes during
    // that await must be reflected by a fresh selection before enqueuing.
    preferences.enabledGames.remove(retailUpdate.id)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences) == nil)
    preferences.enabledGames.insert(retailUpdate.id)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, active: true) == nil)
    preferences.skippedBuilds[retailUpdate.id] = retailUpdate.build
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences) == nil)
}

@Test func automaticUpdatePreflightRejectsAChangedTargetAndChangedPriority() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id, classicUpdate.id]
    let original = selectAutomaticUpdate([retailUpdate, classicUpdate], preferences: preferences)
    var changed = retailUpdate
    changed.build = "newer-live-build"
    #expect(selectAutomaticUpdate([changed, classicUpdate], preferences: preferences) != original)
    #expect(selectAutomaticUpdate([classicUpdate, retailUpdate], preferences: preferences) != original)
}

@Test func automaticUpdatePreflightCannotCrossTheEndOfTheDownloadWindow() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id]
    preferences.usesTimeWindow = true
    let formatter = ISO8601DateFormatter()
    let before = formatter.date(from: "2026-11-16T05:59:59Z")!
    let after = formatter.date(from: "2026-11-16T06:00:00Z")!
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, at: before) == retailUpdate)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: preferences, at: after) == nil)
}

@Test func automaticUpdatesNeverAssumeThatMissingMetadataIsANewBuild() {
    var preferences = AutomaticUpdatePreferences()
    preferences.enabledGames = [retailUpdate.id]
    var candidate = retailUpdate
    candidate.build = ""
    #expect(selectAutomaticUpdate([candidate], preferences: preferences) == nil)
    #expect(selectAutomaticUpdate([], preferences: preferences) == nil)
    #expect(selectAutomaticUpdate([retailUpdate], preferences: AutomaticUpdatePreferences()) == nil)
}
