import Foundation
import Observation

@MainActor @Observable
public final class DownloadQueue {
    public typealias Operation = @Sendable (DownloadRequest, @escaping DownloadJob.Progress) async throws -> Void
    public private(set) var jobs: [String: DownloadJob] = [:]
    public private(set) var restoreErrors: [String] = []
    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let operation: Operation

    public init(store: DownloadStore = DownloadStore(),
                operation: @escaping Operation = { try await $0.perform(progress: $1) }) {
        self.store = store
        self.operation = operation
        restoreAvailableJobs()
    }

    /// No network work on restore. Every interrupted job returns paused and
    /// keeps its last progress; Resume replans against verified data on disk.
    public func restoreAvailableJobs() {
        restoreErrors = []
        do {
            for file in try store.files() {
                do {
                    let record = try store.read(file)
                    guard jobs[record.request.key] == nil else { continue }
                    let lease = try store.claim(key: record.request.key)
                    // Re-read after acquiring ownership: the other process may
                    // have completed or checkpointed while we were claiming it.
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    let latest = try store.read(file)
                    jobs[latest.request.key] = makeJob(latest, lease: lease, restoring: true)
                    Log.notice(.cdn, "job_restored", nil, ["uid": latest.request.key])
                } catch DownloadStoreError.inUse {
                    continue
                } catch {
                    restoreErrors.append(error.localizedDescription)
                    Log.error(.cdn, "restore_failed", nil, ["file": file.path, "error": error])
                }
            }
        } catch {
            restoreErrors.append(error.localizedDescription)
            Log.error(.cdn, "restore_failed", nil, ["error": error])
        }
    }

    @discardableResult
    public func enqueue(_ request: DownloadRequest) throws -> DownloadJob {
        guard jobs[request.key] == nil else { throw DownloadStoreError.alreadyQueued }
        let lease = try store.claim(key: request.key)
        guard !FileManager.default.fileExists(atPath: store.file(for: request.key).path) else {
            throw DownloadStoreError.alreadyQueued
        }
        let record = UnfinishedDownload(request: request)
        try store.save(record) // Must be durable before the first request starts.
        let job = makeJob(record, lease: lease, restoring: false)
        jobs[request.key] = job
        return job
    }

    public func remove(key: String) throws {
        guard let job = jobs[key] else { return }
        try job.discardCheckpoint()
        jobs.removeValue(forKey: key)
    }

    @discardableResult
    public func run(key: String) async -> DownloadJob.State? {
        guard let job = jobs[key] else { return nil }
        let state = await job.run()
        if state == .completed, jobs[key] === job { jobs.removeValue(forKey: key) }
        return state
    }

    public var hasActiveJobs: Bool { jobs.values.contains { $0.state == .running || $0.state == .pausing } }

    /// `events` is read only while the one-time import is still to do:
    /// parsing the logs takes about half a second per megabyte.
    public func recoverLegacyInstalls(events: @autoclosure () -> [Diagnostics.Event],
                                      products: [InstallableProduct] = InstallableProduct.all) {
        let marker = store.directory.appendingPathComponent("legacy-imported")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            // The migration lock also creates the directory on a fresh install.
            let lease = try store.claim(key: "legacy-import")
            try withExtendedLifetime(lease) {
                guard !FileManager.default.fileExists(atPath: marker.path) else { return }
                for record in LegacyDownloadRecovery.records(events: events(), products: products) {
                    guard jobs[record.request.key] == nil,
                          !FileManager.default.fileExists(atPath: store.file(for: record.request.key).path) else { continue }
                    let jobLease = try store.claim(key: record.request.key)
                    try store.save(record)
                    jobs[record.request.key] = makeJob(record, lease: jobLease, restoring: true)
                    Log.notice(.cdn, "legacy_job_recovered", nil, ["uid": record.request.key,
                                                                 "bytes": record.progress?.completedBytes ?? 0])
                }
                try Data().write(to: marker, options: .atomic)
            }
        } catch {
            restoreErrors.append(error.localizedDescription)
            Log.error(.cdn, "legacy_recovery_failed", nil, ["error": error])
        }
    }

    public func pauseAll() async throws {
        let all = Array(jobs.values)
        all.forEach { $0.pause() }
        for job in all {
            await job.waitUntilStopped()
            try job.saveCheckpoint()
        }
    }

    private func makeJob(_ record: UnfinishedDownload, lease: DownloadLease, restoring: Bool) -> DownloadJob {
        let operation = operation
        return DownloadJob(checkpoint: DownloadCheckpoint(record: record, store: store, lease: lease), restoring: restoring) {
            try await operation(record.request, $0)
        }
    }
}
