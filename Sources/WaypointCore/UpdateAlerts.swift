import Foundation

/// Shared preferences keep automatic checks distinct from explicit Check for Updates.
public enum UpdatePreferences {
    public static let automaticKey = "automaticUpdateChecks"
    public static let notificationsKey = "updateNotifications"
    public static let hideDockKey = "hideDockIcon"
    public static func automatic(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticKey) as? Bool ?? true
    }
}

/// Persist only alerts actually handed to Notification Center, so failed or
/// denied delivery can retry. A new build produces a new alert, not every poll.
public struct UpdateAlertLedger {
    private let defaults: UserDefaults
    private let key = "announcedUpdateBuilds"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func needsAlert(id: String, build: String) -> Bool {
        (defaults.dictionary(forKey: key) as? [String: String])?[id] != build
    }
    public func record(id: String, build: String) {
        var records = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        records[id] = build
        defaults.set(records, forKey: key)
    }
}

/// Coalesces concurrent checks without losing a forced post-download refresh.
public struct UpdateCheckSchedule {
    private var running = false
    private var forcedAgain = false
    private var lastCheck: Date?
    public init() {}
    public mutating func request(force: Bool, automatic: Bool, now: Date = Date()) -> Bool {
        guard force || automatic else { return false }
        if running {
            if force { forcedAgain = true }
            return false
        }
        if !force, let lastCheck, now.timeIntervalSince(lastCheck) < 15 * 60 { return false }
        running = true; lastCheck = now
        return true
    }
    /// True means the owner must immediately run a fresh pass with current installs.
    public mutating func complete(now: Date = Date()) -> Bool {
        if forcedAgain {
            forcedAgain = false; lastCheck = now
            return true
        }
        running = false
        return false
    }
    public mutating func cancel() { running = false; forcedAgain = false }
}
