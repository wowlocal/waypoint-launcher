import Foundation

/// The opt-in background preferences. All are off by default.
public enum BackgroundPreferences {
    public static let notificationsKey = "updateNotifications"
    public static let hideDockKey = "hideDockIcon"
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
    /// Whether a forced request that waited wants what it finds announced.
    public private(set) var followUpAnnounces = false
    private var lastCheck: Date?
    public init() {}
    public mutating func request(force: Bool, announces: Bool = true, now: Date = Date()) -> Bool {
        if running {
            if force {
                forcedAgain = true
                followUpAnnounces = followUpAnnounces || announces
            }
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
        followUpAnnounces = false
        return false
    }
    public mutating func cancel() { running = false; forcedAgain = false; followUpAnnounces = false }
}
