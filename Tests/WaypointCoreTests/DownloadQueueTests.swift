import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

private func queueDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-queue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func queuedRequest(_ directory: URL, uid: String = "hs_beta", platform: InstallPlatform = .macOS) -> DownloadRequest {
    var product = InstallableProduct.hearthstone
    product.uid = uid
    let install = product.install(at: directory.appendingPathComponent("game"), region: .eu,
        languages: GameLanguages(text: "enUS", speech: "deDE"), tagString: "\(platform.manifestTag) enUS text:deDE speech", platform: platform)
    return DownloadRequest(kind: .install, install: install, product: product)
}

@Test @MainActor func unfinishedQueueRestoresOptionsProgressAndKeepAwakeWithoutStartingWork() async throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
    let (started, start) = AsyncStream<Void>.makeStream()
    var starts = started.makeAsyncIterator()
    var first: DownloadQueue? = DownloadQueue(store: store) { _, progress in
        progress(UpdateProgress(completedBytes: 19_761_142_371, totalBytes: 52_226_739_846, completedFiles: 100, totalFiles: 200))
        start.yield()
        try await Task.sleep(for: .seconds(3600))
    }
    var request = queuedRequest(directory, platform: .windows)
    request.kind = .languages
    request.languages = GameLanguages(text: "ruRU", speech: "enUS")
    request.verify = true
    request.target = ProductVersion(region: "eu", buildConfig: "target", cdnConfig: "cdn", buildID: 17, name: "1.2.3")
    try first!.enqueue(request)
    first!.jobs[request.key]!.keepsMacAwake = true
    let run = Task { [queue = first!] in await queue.run(key: request.key) }
    await starts.next()
    try await first!.pauseAll()
    #expect(await run.value == .paused)
    let expected = first!.jobs[request.key]!.progress
    #expect(expected?.completedBytes == 19_761_142_371)
    first = nil

    let second = DownloadQueue(store: store) { _, _ in Issue.record("Restore must not start network work") }
    let restored = try #require(second.jobs[request.key])
    #expect(restored.request == request)
    #expect(restored.progress == expected)
    #expect(restored.keepsMacAwake)
    #expect(restored.state == .paused)
    #expect(restored.canResume)
    #expect(!second.hasActiveJobs)
}

@Test @MainActor func savedQueueRemovesFinishedAndCancelledJobsButRetainsFailedJobs() async throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
    let queue = DownloadQueue(store: store) { request, _ in
        if request.install.uid == "fail" { throw URLError(.networkConnectionLost) }
    }
    let finished = queuedRequest(directory, uid: "finish")
    let cancelled = queuedRequest(directory, uid: "cancel")
    let failed = queuedRequest(directory, uid: "fail")
    for request in [finished, cancelled, failed] { try queue.enqueue(request) }
    #expect(await queue.run(key: finished.key) == .completed)
    #expect(!FileManager.default.fileExists(atPath: store.file(for: finished.key).path))
    try queue.remove(key: cancelled.key)
    #expect(!FileManager.default.fileExists(atPath: store.file(for: cancelled.key).path))
    #expect(await queue.run(key: failed.key) == .failed("The connection was lost. Try again to continue."))
    #expect(try store.read(store.file(for: failed.key)).request == failed)
    #expect(queue.jobs[failed.key]?.canCancel == true)
    try queue.remove(key: failed.key)
    #expect(try store.files().isEmpty)
}

@Test @MainActor func appCopiesCannotOverwriteOrResumeEachOthersUnfinishedJobs() throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
    let request = queuedRequest(directory)
    var first: DownloadQueue? = DownloadQueue(store: store)
    try first!.enqueue(request)
    let second = DownloadQueue(store: store)
    #expect(second.jobs.isEmpty)
    #expect(throws: DownloadStoreError.self) { try second.enqueue(request) }
    first = nil
    second.restoreAvailableJobs()
    #expect(second.jobs[request.key]?.state == .paused)
    #expect(try store.read(store.file(for: request.key)).request == request)
}

@Test @MainActor func corruptCheckpointIsPreservedAndDoesNotHideOtherJobs() throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DownloadStore(directory: directory.appendingPathComponent("queue"))
    let request = queuedRequest(directory)
    try store.save(UnfinishedDownload(request: request))
    let corrupt = store.file(for: "bad")
    let original = Data("incomplete json".utf8)
    try original.write(to: corrupt)
    let queue = DownloadQueue(store: store)
    #expect(queue.jobs[request.key]?.canResume == true)
    #expect(queue.restoreErrors.count == 1)
    #expect(try Data(contentsOf: corrupt) == original)
}

@Test @MainActor func unwritableQueueNeverStartsAnUnrecordedDownload() throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocked = directory.appendingPathComponent("file-instead-of-directory")
    try Data().write(to: blocked)
    let queue = DownloadQueue(store: DownloadStore(directory: blocked)) { _, _ in Issue.record("Must not run") }
    #expect(throws: (any Error).self) { try queue.enqueue(queuedRequest(directory)) }
    #expect(queue.jobs.isEmpty)
}

@Test @MainActor func aNewQueueResumesVerifiedFilesWithoutDownloadingThemAgain() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let root = server.directory.appendingPathComponent("game")
    let fixtures = server.directory.appendingPathComponent("fixtures")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let files = try [UInt8(17), UInt8(34)].enumerated().map { index, byte -> UpdatePlan.File in
        let plain = Data(repeating: byte, count: 128 * 1024)
        let encoded = Data("BLTE".utf8) + Data(count: 4) + Data("N".utf8) + plain
        let key = Data(Insecure.MD5.hash(data: encoded))
        try encoded.write(to: fixtures.appendingPathComponent(key.hex))
        return UpdatePlan.File(path: "file\(index)", contentKey: Data(Insecure.MD5.hash(data: plain)), encodedKey: key,
                               size: UInt64(plain.count), location: nil)
    }
    let request = queuedRequest(server.directory)
    let client = server.client(["fixtures"])
    defer { client.session.invalidateAndCancel() }
    let state = InstallStateStore(file: server.directory.appendingPathComponent("installs.json"))
    let plan = UpdatePlan(install: request.install,
        target: ProductVersion(region: "eu", buildConfig: "new", cdnConfig: "cdn", buildID: 1, name: "1.0"),
        cdn: client, files: files, deletions: [])
    let operation: DownloadQueue.Operation = { request, progress in
        try await GameUpdater(install: request.install, store: state, concurrency: 1).apply(plan, progress: progress)
    }
    let store = DownloadStore(directory: server.directory.appendingPathComponent("queue"))
    var first: DownloadQueue? = DownloadQueue(store: store, operation: operation)
    try first!.enqueue(request)
    let run = Task { [queue = first!] in await queue.run(key: request.key) }
    for _ in 0..<200 {
        if (try? server.requests().count) == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try server.requests().count == 2)
    try await first!.pauseAll()
    #expect(await run.value == .paused)
    first = nil
    let second = DownloadQueue(store: store, operation: operation)
    #expect(second.jobs[request.key]?.canResume == true)
    try Data().write(to: server.directory.appendingPathComponent("release"))
    #expect(await second.run(key: request.key) == .completed)
    #expect(try server.requests().count == 3)
    #expect(try store.files().isEmpty)
}

@Test @MainActor func legacyRecoveryRequiresARealJournalAndDoesNotResurrectCancelledDownloads() throws {
    let directory = try queueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let product = try #require(InstallableProduct.forProduct("s2"))
    let storage = directory.appendingPathComponent("Data/data")
    do {
        let writer = try CASCStorageWriter(directory: storage)
        try writer.append(encodedKey: Data(repeating: 17, count: 16), blob: Data(repeating: 3, count: 1234), fullKey: false)
    }
    func event(_ category: String, _ name: String, _ fields: [String: Any]) throws -> Diagnostics.Event {
        let data = try JSONSerialization.data(withJSONObject: ["ts": "2026-11-04T12:00:00.000Z", "level": "info",
            "category": category, "event": name, "fields": fields, "process": "Waypoint"])
        return try #require(Diagnostics.parse(String(decoding: data, as: UTF8.self)))
    }
    let events = try [event("install", "requested", ["uid": "s2", "path": directory.path, "region": "eu", "language": "enUS"]),
                      event("install", "casc_apply_started", ["uid": "s2", "bytes": 5000, "resumed_bytes": 0])]
    let records = LegacyDownloadRecovery.records(events: events, products: [product])
    #expect(records.count == 1)
    #expect(records.first?.progress?.completedBytes == 1234)
    #expect(records.first?.progress?.totalBytes == 5000)
    let cancelled = try event("cdn", "cancelled", ["uid": "s2"])
    #expect(LegacyDownloadRecovery.records(events: events + [cancelled], products: [product]).isEmpty)
    let queue = DownloadQueue(store: DownloadStore(directory: directory.appendingPathComponent("queue")))
    queue.recoverLegacyInstalls(events: events, products: [product])
    #expect(queue.jobs["s2"]?.state == .paused)
    try queue.remove(key: "s2")
    queue.recoverLegacyInstalls(events: events, products: [product])
    #expect(queue.jobs.isEmpty)
}
