import Foundation

/// Releasing the last owner always ends the activity, including when a job
/// is discarded. Idle display sleep and explicit system sleep still work.
final class DownloadSleepPrevention {
    private let activity: NSObjectProtocol
    private let uid: String

    init(uid: String) {
        self.uid = uid
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled], reason: "Waypoint download: \(uid)")
        Log.info(.cdn, "sleep_prevention_started", nil, ["uid": uid])
    }

    deinit {
        ProcessInfo.processInfo.endActivity(activity)
        Log.info(.cdn, "sleep_prevention_ended", nil, ["uid": uid])
    }
}
