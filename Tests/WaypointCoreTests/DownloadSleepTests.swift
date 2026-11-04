import Foundation
import IOKit.pwr_mgt
import Testing
@testable import WaypointCore

/// Check powerd's real assertions, not just whether the job owns a token.
private func sleepAssertions(for uid: String) throws -> [String] {
    var result: Unmanaged<CFDictionary>?
    #expect(IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess)
    let all = try #require(result?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
    return (all[NSNumber(value: getpid())] ?? [])
        .filter { $0["AssertName"] as? String == "Waypoint download: \(uid)" }
        .compactMap { $0["AssertType"] as? String }
}

@Test @MainActor func keepAwakeIsOptInAndEndsOnlyAfterTheWholeDownloadFinishes() async throws {
    let uid = "keep-awake-finish-\(UUID().uuidString)"
    let (started, start) = AsyncStream<Void>.makeStream()
    let (finish, complete) = AsyncStream<Void>.makeStream()
    var starts = started.makeAsyncIterator()
    let job = DownloadJob(uid: uid, category: .install) { progress in
        progress(UpdateProgress(completedBytes: 100, totalBytes: 100, completedFiles: 1, totalFiles: 1))
        start.yield()
        for await _ in finish { break } // Final verification/commit still running.
    }
    let run = Task { await job.run() }
    await starts.next()
    #expect(!job.keepsMacAwake)
    #expect(try sleepAssertions(for: uid).isEmpty)

    job.keepsMacAwake = true
    #expect(try sleepAssertions(for: uid) == ["PreventUserIdleSystemSleep"])
    job.keepsMacAwake = true
    #expect(try sleepAssertions(for: uid).count == 1)
    job.keepsMacAwake = false
    #expect(try sleepAssertions(for: uid).isEmpty)
    job.keepsMacAwake = true
    complete.yield()
    #expect(await run.value == .completed)
    #expect(try sleepAssertions(for: uid).isEmpty)
}

@Test @MainActor func keepAwakeReleasesOnPauseAndRestoresOnResume() async throws {
    let uid = "keep-awake-resume-\(UUID().uuidString)"
    let (started, start) = AsyncStream<Void>.makeStream()
    var starts = started.makeAsyncIterator()
    let job = DownloadJob(uid: uid, category: .install) { _ in
        start.yield()
        try await Task.sleep(for: .seconds(3600))
    }
    job.keepsMacAwake = true
    #expect(try sleepAssertions(for: uid).isEmpty)
    for _ in 0..<2 {
        let run = Task { await job.run() }
        await starts.next()
        #expect(try sleepAssertions(for: uid) == ["PreventUserIdleSystemSleep"])
        job.pause()
        #expect(await run.value == .paused)
        #expect(job.keepsMacAwake)
        #expect(try sleepAssertions(for: uid).isEmpty)
    }
}

@Test @MainActor func keepAwakeReleasesOnFailureWithoutReleasingAnotherDownloadsHold() async throws {
    let firstUID = "keep-awake-independent-\(UUID().uuidString)"
    let secondUID = "keep-awake-fail-\(UUID().uuidString)"
    let (started, start) = AsyncStream<Void>.makeStream()
    var starts = started.makeAsyncIterator()
    let first = DownloadJob(uid: firstUID, category: .install) { _ in
        start.yield()
        try await Task.sleep(for: .seconds(3600))
    }
    first.keepsMacAwake = true
    let running = Task { await first.run() }
    await starts.next()
    let second = DownloadJob(uid: secondUID, category: .install) { _ in
        #expect(try sleepAssertions(for: secondUID) == ["PreventUserIdleSystemSleep"])
        throw URLError(.networkConnectionLost)
    }
    second.keepsMacAwake = true
    #expect(await second.run() == .failed("The connection was lost. Try again to continue."))
    #expect(try sleepAssertions(for: secondUID).isEmpty)
    #expect(try sleepAssertions(for: firstUID) == ["PreventUserIdleSystemSleep"])
    first.pause()
    #expect(await running.value == .paused)
    #expect(try sleepAssertions(for: firstUID).isEmpty)
}

@Test func discardingSleepPreventionAlwaysReleasesItsPowerAssertion() throws {
    let uid = "keep-awake-discard-\(UUID().uuidString)"
    var prevention: DownloadSleepPrevention? = DownloadSleepPrevention(uid: uid)
    try withExtendedLifetime(prevention) { () throws -> Void in
        #expect(try sleepAssertions(for: uid) == ["PreventUserIdleSystemSleep"])
    }
    prevention = nil
    #expect(try sleepAssertions(for: uid).isEmpty)
}
