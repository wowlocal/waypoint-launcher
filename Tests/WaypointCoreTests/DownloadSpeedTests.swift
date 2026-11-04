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
