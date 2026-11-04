import CryptoKit
import Foundation
import Observation
import Testing
@testable import WaypointCore

private actor DownloadSignal {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Every progress report, as the operation made it.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [UpdateProgress] = []

    var last: UpdateProgress? { lock.withLock { reports.last } }
    func append(_ progress: UpdateProgress) { lock.withLock { reports.append(progress) } }
}

private actor PausableWork {
    let started = DownloadSignal()
    let stopping = DownloadSignal()
    let allowStop = DownloadSignal()
    private(set) var runs = 0

    func perform(_ progress: DownloadJob.Progress) async throws {
        runs += 1
        if runs == 1 {
            progress(UpdateProgress(completedBytes: 20, totalBytes: 100, completedFiles: 1, totalFiles: 2))
            await started.open()
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                await stopping.open()
                // Model a writer closing files after its network tasks stop.
                await allowStop.wait()
                throw error
            }
        }
    }
}

@Test @MainActor func pauseWaitsForCleanupAndResumeCannotStartAnotherWriter() async {
    let work = PausableWork()
    let job = DownloadJob(uid: "pause-test", category: .install) { try await work.perform($0) }
    let progressReported = DownloadSignal()
    withObservationTracking {
        _ = job.progress
    } onChange: {
        Task { await progressReported.open() }
    }
    let first = Task { await job.run() }
    await work.started.wait()
    await progressReported.wait()
    #expect(job.canPause)
    job.pause()
    job.pause() // A double click does not change the pending pause.
    await work.stopping.wait()
    #expect(job.state == .pausing)
    #expect(!job.canResume)
    #expect(!job.canCancel)
    #expect(await job.run() == .pausing)
    #expect(await work.runs == 1)

    await work.allowStop.open()
    #expect(await first.value == .paused)
    #expect(job.canResume)
    #expect(job.canCancel)
    #expect(!job.canPause)
    #expect(job.progress?.completedBytes == 20)

    #expect(await job.run() == .completed)
    #expect(await work.runs == 2)
    #expect(!job.canResume)
    #expect(!job.canCancel)
    #expect(await job.run() == .completed)
    #expect(await work.runs == 2)
}

@Test @MainActor func pauseDuringTheFinalCommitFinishesSuccessfully() async {
    let committing = DownloadSignal(), finish = DownloadSignal()
    let job = DownloadJob(uid: "commit-test", category: .gameUpdate) { _ in
        await committing.open()
        // The synchronous commit deliberately does not observe cancellation.
        await finish.wait()
    }
    let run = Task { await job.run() }
    await committing.wait()
    job.pause()
    #expect(job.state == .pausing)
    await finish.open()
    #expect(await run.value == .completed)
    #expect(job.state == .completed)
    #expect(!job.canResume)
}

private actor FailingWork {
    private(set) var runs = 0
    func perform() throws {
        runs += 1
        if runs == 1 { throw URLError(.networkConnectionLost) }
    }
}

@Test @MainActor func failedJobsKeepTheirOperationForRetry() async {
    let work = FailingWork()
    let job = DownloadJob(uid: "retry-test", category: .install) { _ in try await work.perform() }
    #expect(await job.run() == .failed("The connection was lost. Try again to continue."))
    #expect(job.canResume)
    #expect(await job.run() == .completed)
    #expect(await work.runs == 2)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
@MainActor func pauseCancelsTheDownloadAndResumeReusesVerifiedStaging() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let fm = FileManager.default
    let root = server.directory.appendingPathComponent("game")
    let fixtures = server.directory.appendingPathComponent("fixtures")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let plain = [Data(repeating: 17, count: 128 * 1024), Data(repeating: 34, count: 128 * 1024)]
    let files = try plain.enumerated().map { i, data -> UpdatePlan.File in
        let encoded = Data("BLTE".utf8) + Data(count: 4) + Data("N".utf8) + data
        let encodedKey = Data(Insecure.MD5.hash(data: encoded))
        try encoded.write(to: fixtures.appendingPathComponent(encodedKey.hex))
        try Data("old".utf8).write(to: root.appendingPathComponent("file\(i)"))
        return UpdatePlan.File(path: "file\(i)", contentKey: Data(Insecure.MD5.hash(data: data)),
                               encodedKey: encodedKey, size: UInt64(data.count), location: nil)
    }
    let install = ProductInstall(uid: "test", productCode: "hsb", installPath: root.path)
    let store = InstallStateStore(file: server.directory.appendingPathComponent("state.json"))
    let client = server.client(["fixtures"])
    defer { client.session.invalidateAndCancel() }
    let target = ProductVersion(region: "eu", buildConfig: "new", cdnConfig: "cdn", buildID: 1, name: "1.0")
    let plan = UpdatePlan(install: install, target: target, cdn: client, files: files, deletions: [])
    let updater = GameUpdater(install: install, store: store, concurrency: 1)
    let job = DownloadJob(uid: install.uid, category: .gameUpdate) { try await updater.apply(plan, progress: $0) }
    let run = Task { await job.run() }
    defer { job.pause() }

    // The first file is staged; the server holds the second response open.
    for _ in 0..<200 {
        if (try? server.requests().count) == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try server.requests().count == 2)
    job.pause()
    #expect(await run.value == .paused)
    #expect(store.load().isEmpty)
    for file in files {
        #expect(try Data(contentsOf: root.appendingPathComponent(file.path)) == Data("old".utf8))
    }
    let requestsBeforeResume = try server.requests()
    let completedKey = try #require(requestsBeforeResume.first?["file"])
    let completed = try #require(files.first { $0.encodedKey.hex == completedKey })
    let staged = root.appendingPathComponent(".waypoint-staging/\(completed.contentKey.hex)")
    #expect(fm.fileExists(atPath: staged.path))

    // Release the server first, so it can observe any leaked new requests.
    try Data().write(to: server.directory.appendingPathComponent("release"))
    // No new requests are scheduled while the job is paused.
    try await Task.sleep(for: .milliseconds(50))
    #expect(try server.requests().count == 2)
    #expect(await job.run() == .completed)
    #expect(try server.requests().count == 3)
    #expect(try server.requests().filter { $0["file"] == completedKey }.count == 1)
    for (i, file) in files.enumerated() {
        #expect(try Data(contentsOf: root.appendingPathComponent(file.path)) == plain[i])
    }
    #expect(store.load()[install.uid]?.buildConfig == target.buildConfig)
    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".waypoint-staging").path))
}

@Test @MainActor func aRealFailureRacingWithPauseIsNotHiddenAsPaused() async {
    let started = DownloadSignal(), finish = DownloadSignal()
    let job = DownloadJob(uid: "pause-real-error", category: .gameUpdate) { _ in
        try await NetworkRetry().run { _ in
            await started.open()
            await finish.wait()
            throw UpdateError.gameRunning
        }
    }
    let run = Task { await job.run() }
    await started.wait()
    job.pause()
    await finish.open()
    #expect(await run.value == .failed("Quit the game before updating"))
    #expect(job.canResume)
    #expect(job.canCancel)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
@MainActor func pauseAndResumeCASCStorageReplaysTheJournalAndDropsAnUnfinishedTail() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let fm = FileManager.default
    let root = server.directory.appendingPathComponent("game")
    let fixtures = server.directory.appendingPathComponent("fixtures")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let storage = try [UInt8(17), UInt8(34)].map { byte -> StorageItem in
        let blob = Data("BLTE".utf8) + Data(count: 4) + Data("N".utf8) + Data(repeating: byte, count: 128 * 1024)
        let key = Data(Insecure.MD5.hash(data: blob))
        try blob.write(to: fixtures.appendingPathComponent(key.hex))
        return StorageItem(key: Key16(key)!, size: UInt64(blob.count), fullKey: false)
    }
    let product = try #require(InstallableProduct.forProduct("s2"))
    let install = product.install(at: root, region: .eu, language: "enUS", tagString: "OSX enUS")
    let config = try ProductConfig(json: Data("{}".utf8))
    let store = InstallStateStore(file: server.directory.appendingPathComponent("state.json"))
    let client = server.client(["fixtures"])
    defer { client.session.invalidateAndCancel() }
    let target = ProductVersion(region: "eu", buildConfig: String(repeating: "a", count: 32),
                                cdnConfig: String(repeating: "b", count: 32), buildID: 1, name: "1.0")
    let loose = UpdatePlan(install: install, target: target, cdn: client, files: [], deletions: [])
    let plan = CASCInstallPlan(install: install, product: product, config: config, target: target, cdn: client,
                               buildConfig: Data(), cdnConfig: Data(), archives: [], storage: storage, loose: loose)
    var installer = CASCInstaller(product: product, install: install, config: config, store: store)
    installer.concurrency = 1
    let executor = installer
    let storageDirectory = root.appendingPathComponent("Data/data")
    let progressLog = ProgressLog()
    // Like the app, every run plans again: what the journal holds is done.
    let job = DownloadJob(uid: install.uid, category: .install) { progress in
        var plan = plan
        plan.storedBytes = CASCInstaller.storedBytes(plan.storage.sorted { $0.key < $1.key }, in: storageDirectory)
        try await executor.apply(plan) { report in
            progressLog.append(report)
            progress(report)
        }
    }
    let run = Task { await job.run() }
    defer { job.pause() }
    for _ in 0..<200 {
        if (try? server.requests().count) == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try server.requests().count == 2)
    job.pause()
    #expect(await run.value == .paused)
    let journal = storageDirectory.appendingPathComponent(CASCStorageWriter.journalName)
    #expect(fm.fileExists(atPath: journal.path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".build.info").path))
    #expect(store.load().isEmpty)
    let archive = storageDirectory.appendingPathComponent("data.000")
    let originalSize = try #require(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let tail = try FileHandle(forWritingTo: archive)
    try tail.seekToEnd()
    try tail.write(contentsOf: Data(repeating: 0xCC, count: 4096))
    try tail.close()
    // Resuming in the app plans again: the unfinished storage reads as none
    // yet (no index files), and the journaled blob as already downloaded.
    #expect(try StoredKeys.load(storageDirectory) == nil)
    #expect(CASCInstaller.storedBytes(storage.sorted { $0.key < $1.key }, in: storageDirectory) == storage[0].size)
    try Data().write(to: server.directory.appendingPathComponent("release"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(try server.requests().count == 2)
    #expect(await job.run() == .completed)
    let stored = try #require(try StoredKeys.load(storageDirectory))
    for item in storage { #expect(stored.contains(item.key)) }
    #expect(!fm.fileExists(atPath: journal.path))
    #expect(store.load()[install.uid]?.buildConfig == target.buildConfig)
    #expect(try server.requests().count == 3)
    let firstKey = storage[0].key.hex
    #expect(try server.requests().filter { $0["file"] == firstKey }.count == 1)
    let finalSize = try #require(archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(finalSize == originalSize + Int(storage[1].size) + CASC.headerSize)
    // Progress after resuming counts the whole install, the reused blob included.
    let last = try #require(progressLog.last)
    #expect(last.totalBytes == storage.reduce(0) { $0 + $1.size })
    #expect(last.completedBytes == last.totalBytes)
}
