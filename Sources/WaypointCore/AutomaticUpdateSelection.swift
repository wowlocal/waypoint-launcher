import Foundation

/// Eligibility read from the current library and download queue. A paused
/// manual download must never set `canResume`; shared-folder owners prevent
/// both starting and resuming until the folder is available again.
public struct AutomaticUpdateCandidate: Equatable, Sendable {
    public var id: String
    public var build: String
    public var canStart: Bool
    public var canResume: Bool

    public init(id: String, build: String, canStart: Bool, canResume: Bool) {
        self.id = id
        self.build = build
        self.canStart = canStart
        self.canResume = canResume
    }
}

/// Choose one job in library order, reusing the same decision after an
/// asynchronous preflight. Starting a job changes the facts for the next pass.
public enum AutomaticUpdateSelection {
    public static func next(in ordered: [AutomaticUpdateCandidate], preferences: AutomaticUpdatePreferences,
                            hasActiveDownloads: Bool, isUpdatingAll: Bool, isQuitting: Bool,
                            at date: Date = Date(), calendar: Calendar = .current) -> AutomaticUpdateCandidate? {
        guard !hasActiveDownloads, !isUpdatingAll, !isQuitting else { return nil }
        return ordered.first { candidate in
            (candidate.canStart || candidate.canResume)
                && preferences.allowsUpdate(gameID: candidate.id, build: candidate.build, at: date, calendar: calendar)
        }
    }
}
