import Foundation
import Testing
@testable import WaypointCore

@Suite @MainActor struct AutomaticDownloadTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-automatic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func request(at directory: URL, kind: DownloadRequest.Kind = .update) -> DownloadRequest {
        let product = InstallableProduct.hearthstone
        let install = product.install(at: directory.appendingPathComponent("game"), region: .eu, language: "enUS", tagString: "OSX enUS")
        return DownloadRequest(kind: kind, install: install, product: product,
            target: ProductVersion(region: "eu", buildConfig: "target", cdnConfig: "cdn", buildID: 17, name: "1.2.3"))
    }

    @Test func olderCheckpointsStayManual() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
        let request = request(at: directory)
        try store.save(UnfinishedDownload(request: request))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.file(for: request.key))) as? [String: Any])
        #expect(json["automaticUpdate"] == nil)
        let queue = DownloadQueue(store: store)
        let job = try #require(queue.jobs[request.key])
        #expect(!job.isAutomaticUpdate)
        #expect(job.state == .paused)
        #expect(job.canResume)
    }

    @Test func scheduledPauseSurvivesRestartAndCanResume() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
        let request = request(at: directory)
        let (started, start) = AsyncStream<Void>.makeStream()
        var starts = started.makeAsyncIterator()
        var first: DownloadQueue? = DownloadQueue(store: store) { _, progress in
            progress(UpdateProgress(completedBytes: 50, totalBytes: 100, completedFiles: 1, totalFiles: 2))
            start.yield()
            try await Task.sleep(for: .seconds(3600))
        }
        try first!.enqueue(request, automaticUpdate: true)
        let run = Task { [queue = first!] in await queue.run(key: request.key) }
        await starts.next()
        try await first!.pauseAll()
        #expect(await run.value == .paused)
        #expect(first!.jobs[request.key]?.isAutomaticUpdate == true)
        let saved = try store.read(store.file(for: request.key))
        #expect(saved.automaticUpdate == true)
        #expect(saved.progress?.completedBytes == 50)
        first = nil

        let second = DownloadQueue(store: store) { _, _ in }
        let restored = try #require(second.jobs[request.key])
        #expect(restored.isAutomaticUpdate)
        #expect(restored.state == .paused)
        #expect(restored.progress == saved.progress)
        #expect(await second.run(key: request.key) == .completed)
        #expect(try store.files().isEmpty)
    }

    @Test func userPauseTakesOwnershipWithoutLosingProgress() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
        let request = request(at: directory)
        let (started, start) = AsyncStream<Void>.makeStream()
        var starts = started.makeAsyncIterator()
        var first: DownloadQueue? = DownloadQueue(store: store) { _, progress in
            progress(UpdateProgress(completedBytes: 37, totalBytes: 100, completedFiles: 1, totalFiles: 2))
            start.yield()
            try await Task.sleep(for: .seconds(3600))
        }
        try first!.enqueue(request, automaticUpdate: true)
        let run = Task { [queue = first!] in await queue.run(key: request.key) }
        await starts.next()
        try first!.jobs[request.key]!.makeManual()
        first!.jobs[request.key]!.pause()
        #expect(await run.value == .paused)
        #expect(first!.jobs[request.key]?.isAutomaticUpdate == false)
        let saved = try store.read(store.file(for: request.key))
        #expect(saved.automaticUpdate == nil)
        #expect(saved.progress?.completedBytes == 37)
        first = nil
        let second = DownloadQueue(store: store)
        #expect(second.jobs[request.key]?.isAutomaticUpdate == false)
        #expect(second.jobs[request.key]?.progress == saved.progress)
    }

    @Test func failedAutomaticUpdateWaitsForManualRetry() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
        let request = request(at: directory)
        var first: DownloadQueue? = DownloadQueue(store: store) { _, _ in throw URLError(.networkConnectionLost) }
        try first!.enqueue(request, automaticUpdate: true)
        #expect(await first!.run(key: request.key) == .failed("The connection was lost. Try again to continue."))
        #expect(first!.jobs[request.key]?.isAutomaticUpdate == false)
        let saved = try store.read(store.file(for: request.key))
        #expect(saved.automaticUpdate == nil)
        #expect(saved.failure != nil)
        first = nil
        let second = DownloadQueue(store: store)
        #expect(second.jobs[request.key]?.isAutomaticUpdate == false)
        #expect(second.jobs[request.key]?.canResume == true)
    }

    @Test func onlyUpdatesCanBeAutomaticallyManaged() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
        let queue = DownloadQueue(store: store)
        for kind in [DownloadRequest.Kind.install, .languages] {
            #expect(throws: TACTError.self) { try queue.enqueue(request(at: directory, kind: kind), automaticUpdate: true) }
        }
        #expect(queue.jobs.isEmpty)
        #expect(try store.files().isEmpty)
        // Even an externally altered record cannot opt an install into scheduling.
        var record = UnfinishedDownload(request: request(at: directory, kind: .install))
        record.automaticUpdate = true
        try store.save(record)
        queue.restoreAvailableJobs()
        #expect(queue.jobs[record.request.key]?.isAutomaticUpdate == false)
    }

    @Test func unsuccessfulOwnershipChangeKeepsTheOriginalRecord() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueDirectory = directory.appendingPathComponent("queue")
        let store = DownloadStore(directory: queueDirectory)
        let request = request(at: directory)
        let progress = UpdateProgress(completedBytes: 75, totalBytes: 100, completedFiles: 1, totalFiles: 2)
        try store.save(UnfinishedDownload(request: request, progress: progress, automaticUpdate: true))
        let queue = DownloadQueue(store: store)
        let job = try #require(queue.jobs[request.key])
        let displaced = directory.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: queueDirectory, to: displaced)
        try Data().write(to: queueDirectory)
        #expect(throws: (any Error).self) { try job.makeManual() }
        #expect(job.isAutomaticUpdate)
        #expect(job.progress == progress)
        try FileManager.default.removeItem(at: queueDirectory)
        try FileManager.default.moveItem(at: displaced, to: queueDirectory)
        #expect(try store.read(store.file(for: request.key)).automaticUpdate == true)
        try job.makeManual()
        #expect(!job.isAutomaticUpdate)
        #expect(try store.read(store.file(for: request.key)).progress == progress)
        #expect(try store.read(store.file(for: request.key)).automaticUpdate == nil)
    }
}
