import Foundation

/// Opt-in game updates, independent of notification and login-item preferences.
/// Times are minutes after midnight in the Mac's current time zone.
public struct AutomaticUpdatePreferences: Codable, Equatable, Sendable {
    public var enabledGames: Set<String> = []
    public var usesTimeWindow = false
    public var startMinute = 120
    public var endMinute = 360
    /// Cancelling an automatic update leaves this build alone; a later build
    /// can still update. Paused downloads retain their own checkpoints.
    public var skippedBuilds: [String: String] = [:]

    static let defaultsKey = "automaticGameUpdates"

    private struct Saved: Codable {
        var version = 1
        var preferences: AutomaticUpdatePreferences
    }

    public init() {}

    private var isValid: Bool {
        (0..<24 * 60).contains(startMinute) && (0..<24 * 60).contains(endMinute)
            && !enabledGames.contains("")
            && !skippedBuilds.contains { $0.key.isEmpty || $0.value.isEmpty }
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1, saved.preferences.isValid else { return Self() }
        return saved.preferences
    }

    public func save(defaults: UserDefaults = .standard) {
        // An invalid schedule must never silently become unrestricted.
        let preferences = isValid ? self : Self()
        guard let data = try? JSONEncoder().encode(Saved(preferences: preferences)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The start is inclusive and the end exclusive. A window that crosses
    /// midnight covers both sides; equal times mean all day.
    public func allowsDownloads(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isValid else { return false }
        guard usesTimeWindow, startMinute != endMinute else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        if startMinute < endMinute { return current >= startMinute && current < endMinute }
        return current >= startMinute || current < endMinute
    }

    public func allowsUpdate(gameID: String, build: String, at date: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        !gameID.isEmpty && !build.isEmpty && enabledGames.contains(gameID)
            && skippedBuilds[gameID] != build && allowsDownloads(at: date, calendar: calendar)
    }

    /// Re-evaluate at the next wall-clock boundary, including a clock change
    /// that jumps across a boundary. Both occurrences of a repeated hour count:
    /// the displayed local time always determines whether downloads may run.
    public func nextBoundary(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isValid, !enabledGames.isEmpty, usesTimeWindow, startMinute != endMinute else { return nil }
        var candidates: [Date] = []
        for minute in [startMinute, endMinute] {
            let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
            for repeated in [Calendar.RepeatedTimePolicy.first, .last] {
                if let next = calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime,
                                                repeatedTimePolicy: repeated), next > date {
                    candidates.append(next)
                }
            }
        }
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: date), transition > date {
            candidates.append(transition)
        }
        return candidates.min()
    }
}
