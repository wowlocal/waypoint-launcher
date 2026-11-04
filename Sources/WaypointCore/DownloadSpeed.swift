import Foundation

/// One meter per download job, inherited by its concurrent requests. The
/// delegate captures it before leaving the task-local context.
final class DownloadSpeed: @unchecked Sendable {
    @TaskLocal static var current: DownloadSpeed?

    private struct Bucket {
        var second: TimeInterval
        var bytes: UInt64
    }

    private static let origin = ContinuousClock.now
    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var buckets: [Bucket] = []
    private var received: UInt64 = 0

    init(now: TimeInterval = DownloadSpeed.now) { startedAt = now }

    var receivedBytes: UInt64 { lock.withLock { received } }

    func record(_ bytes: Int64, at now: TimeInterval = DownloadSpeed.now) {
        guard bytes > 0 else { return }
        lock.withLock {
            received += UInt64(bytes)
            let second = floor(now)
            buckets.removeAll { $0.second < second - 9 }
            if let index = buckets.firstIndex(where: { $0.second == second }) {
                buckets[index].bytes += UInt64(bytes)
            } else {
                buckets.append(Bucket(second: second, bytes: UInt64(bytes)))
            }
        }
    }

    /// Average over the current second and the preceding nine. A stalled
    /// transfer falls to zero even if no new callbacks arrive. No timer runs.
    func bytesPerSecond(at now: TimeInterval = DownloadSpeed.now) -> Double {
        lock.withLock {
            let start = max(startedAt, floor(now) - 9)
            guard now > start else { return 0 }
            let bytes = buckets.filter { $0.second >= floor(start) && $0.second <= floor(now) }
                .reduce(UInt64(0)) { $0 + $1.bytes }
            return Double(bytes) / (now - start)
        }
    }
}
