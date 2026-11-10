import Darwin
import Foundation

/// When the kernel started this process: before dyld loaded anything and
/// before any of Waypoint's code ran. The launch time in the log is measured
/// from here, so it is what the person waited, not what the app saw.
public enum ProcessStart {
    public static var date: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    public static var millisecondsAgo: Int? {
        date.map { Int(Date().timeIntervalSince($0) * 1000) }
    }
}
