import Foundation
import Testing
@testable import WaypointCore

@Test func downloadSpeedAveragesRecentNetworkBytesAndDecaysDuringAStall() {
    let speed = DownloadSpeed(now: 0)
    #expect(speed.bytesPerSecond(at: 0) == 0)
    for second in 0..<20 {
        speed.record(2_000_000, at: Double(second) + 0.5)
    }
    #expect(speed.bytesPerSecond(at: 20) == 2_000_000)
    #expect(speed.bytesPerSecond(at: 25) < 2_000_000)
    #expect(speed.bytesPerSecond(at: 30) == 0)
    #expect(speed.receivedBytes == 40_000_000)
}

@Test func downloadSpeedCombinesConcurrentCallbacksRegardlessOfArrivalOrder() async {
    let speed = DownloadSpeed(now: 0)
    await withTaskGroup(of: Void.self) { group in
        for second in 0..<5 {
            group.addTask {
                for _ in 0..<100 { speed.record(1_000, at: Double(second) + 0.5) }
            }
        }
    }
    #expect(speed.bytesPerSecond(at: 5) == 100_000)
    #expect(speed.receivedBytes == 500_000)
}

@Test func realConcurrentDownloadsReportBytesToTheirOwnJob() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["normal"], limiter: DownloadBandwidthLimiter())
    defer { client.session.invalidateAndCancel() }
    let first = DownloadSpeed(), second = DownloadSpeed()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for speed in [first, second] {
            group.addTask {
                try await DownloadSpeed.$current.withValue(speed) {
                    try await withThrowingTaskGroup(of: Void.self) { transfers in
                        for key in ["aabb", "ccdd"] {
                            transfers.addTask {
                                let file = try await client.download(.data, key)
                                try FileManager.default.removeItem(at: file)
                            }
                        }
                        try await transfers.waitForAll()
                    }
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(first.receivedBytes == UInt64(DownloadServer.payload.count * 2))
    #expect(second.receivedBytes == first.receivedBytes)
    #expect(DownloadSpeed.current == nil)
}

@Test @MainActor func resumingDownloadUsesAFreshSpeedMeterAndExcludesReusedData() async {
    let started = DownloadSignalForSpeed()
    let job = DownloadJob(uid: "speed-resume", category: .install) { progress in
        let speed = DownloadSpeed.current
        #expect(speed?.receivedBytes == 0)
        progress(UpdateProgress(completedBytes: 16_000_000_000, totalBytes: 52_000_000_000,
                                completedFiles: 100, totalFiles: 200))
        #expect(speed?.receivedBytes == 0)
        speed?.record(1_000_000)
        await started.open()
        try await Task.sleep(for: .seconds(3600))
    }
    for _ in 0..<2 {
        let run = Task { await job.run() }
        await started.wait()
        #expect(job.bytesPerSecond != nil)
        job.pause()
        #expect(await run.value == .paused)
        #expect(job.bytesPerSecond == nil)
    }
}

private actor DownloadSignalForSpeed {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { opened = false; return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        if let continuation { self.continuation = nil; continuation.resume() }
        else { opened = true }
    }
}

@Test func timeLeftComesFromWhatRemainsAndTheRate() {
    let progress = UpdateProgress(completedBytes: 1_000_000_000, totalBytes: 13_000_000_000, completedFiles: 0, totalFiles: 1)
    #expect(progress.secondsLeft(bytesPerSecond: 40_000_000) == 300)
    #expect(progress.secondsLeft(bytesPerSecond: 0) == nil, "a stalled transfer says nothing")
    #expect(progress.secondsLeft(bytesPerSecond: 500) == nil)
    let done = UpdateProgress(completedBytes: 5, totalBytes: 5, completedFiles: 1, totalFiles: 1)
    #expect(done.secondsLeft(bytesPerSecond: 40_000_000) == nil)
    // Reused data can put a resumed download past its own total.
    let past = UpdateProgress(completedBytes: 6, totalBytes: 5, completedFiles: 1, totalFiles: 1)
    #expect(past.secondsLeft(bytesPerSecond: 40_000_000) == nil)
}

@Test func timeLeftIsRoundedToWhatTheRateCanSupport() {
    #expect(UpdateProgress.timeLeft(12) == "less than a minute left")
    #expect(UpdateProgress.timeLeft(60) == "about 1 minute left")
    #expect(UpdateProgress.timeLeft(89) == "about 1 minute left")
    #expect(UpdateProgress.timeLeft(90) == "about 2 minutes left")
    #expect(UpdateProgress.timeLeft(300) == "about 5 minutes left")
    #expect(UpdateProgress.timeLeft(59 * 60) == "about 59 minutes left")
    #expect(UpdateProgress.timeLeft(59 * 60 + 30) == "about 1 hour left")
    #expect(UpdateProgress.timeLeft(80 * 60) == "about 1 hour 20 minutes left")
    #expect(UpdateProgress.timeLeft(83 * 60) == "about 1 hour 25 minutes left")
    #expect(UpdateProgress.timeLeft(118 * 60) == "about 2 hours left")
    #expect(UpdateProgress.timeLeft(24 * 3600) == "about 24 hours left")
    #expect(UpdateProgress.timeLeft(24 * 3600 + 1) == "more than a day left")
    #expect(UpdateProgress.timeLeft(3 * 24 * 3600) == "more than a day left")
}
