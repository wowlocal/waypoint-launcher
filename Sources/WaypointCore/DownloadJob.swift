import Foundation
import Observation

/// Owns one install/update task. Pausing cancels network requests and waits
/// for the installer to unwind before allowing another writer to start.
/// The operation retains its options and reuses staged/journaled data on run.
@MainActor
@Observable
public final class DownloadJob {
    public enum State: Equatable, Sendable {
        case ready, running, pausing, paused, completed
        case failed(String)
    }

    public typealias Progress = @Sendable (UpdateProgress) -> Void
    public typealias Operation = @Sendable (@escaping Progress) async throws -> Void

    public private(set) var state: State = .ready {
        didSet { updateSleepPrevention() }
    }
    public private(set) var progress: UpdateProgress?
    /// Opt-in for this job. Pausing releases the hold; resuming restores it.
    public var keepsMacAwake = false {
        didSet {
            updateSleepPrevention()
            checkpointIfNeeded(force: true)
        }
    }
    public var request: DownloadRequest? { checkpoint?.record.request }
    public var canPause: Bool { state == .running }
    public var canResume: Bool {
        switch state {
        case .paused, .failed: task == nil
        default: false
        }
    }
    public var canCancel: Bool { canResume }

    /// Recent network throughput, excluding data reused from an earlier run.
    /// Read on demand so tooltips remain accurate during a network stall.
    public var bytesPerSecond: Double? { state == .running ? speed?.bytesPerSecond() : nil }

    @ObservationIgnored private let uid: String
    @ObservationIgnored private let category: Diagnostics.Category
    @ObservationIgnored private let operation: Operation
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var speed: DownloadSpeed?
    @ObservationIgnored private var sleepPrevention: DownloadSleepPrevention?
    @ObservationIgnored private var checkpoint: DownloadCheckpoint?

    public init(uid: String, category: Diagnostics.Category, operation: @escaping Operation) {
        self.uid = uid
        self.category = category
        self.operation = operation
    }

    convenience init(checkpoint: DownloadCheckpoint, restoring: Bool, operation: @escaping Operation) {
        let record = checkpoint.record
        self.init(uid: record.request.key, category: record.request.category, operation: operation)
        progress = record.progress
        keepsMacAwake = record.keepsMacAwake
        state = restoring ? .paused : .ready
        self.checkpoint = checkpoint
    }

    /// A second caller cannot start a duplicate task, including while pausing.
    @discardableResult
    public func run() async -> State {
        guard state == .ready || canResume else { return state }
        generation = UUID()
        let generation = generation
        let speed = DownloadSpeed()
        self.speed = speed
        state = .running
        do { try saveCheckpoint() }
        catch {
            state = .failed("Could not save download state: \(errorMessage(error))")
            return state
        }
        let task = Task { [self] () -> State in
            let result: State
            do {
                try Task.checkCancellation()
                try await DownloadSpeed.$current.withValue(speed) {
                    try await operation { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.generation == generation,
                                  self.state == .running || self.state == .pausing else { return }
                            self.progress = progress
                            self.checkpointIfNeeded(force: false)
                        }
                    }
                }
                // Finishing an already-started commit wins over a late pause.
                result = .completed
            } catch {
                if Task.isCancelled, state == .pausing, NetworkRetry.isCancellation(error) {
                    result = .paused
                    Log.notice(category, "paused", nil, ["uid": uid])
                } else {
                    result = .failed(errorMessage(error))
                    Log.error(category, "failed", nil, ["uid": uid, "error": error])
                }
            }
            self.task = nil
            state = result
            do {
                if result == .completed { try discardCheckpoint() }
                else { try saveCheckpoint() }
            } catch {
                state = .failed("Could not save download state: \(errorMessage(error))")
                Log.error(category, "checkpoint_failed", nil, ["uid": uid, "error": error])
            }
            return state
        }
        self.task = task
        return await task.value
    }

    public func pause() {
        guard canPause, let task else { return }
        state = .pausing
        Log.info(category, "pause_requested", nil, ["uid": uid])
        task.cancel()
    }

    public func waitUntilStopped() async { if let task { _ = await task.value } }

    public func saveCheckpoint() throws {
        try checkpoint?.save(progress: progress, keepsMacAwake: keepsMacAwake,
                             failure: failureMessage, force: true)
    }

    func discardCheckpoint() throws {
        guard task == nil else { throw DownloadStoreError.inUse }
        try checkpoint?.remove()
        checkpoint = nil
    }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private func checkpointIfNeeded(force: Bool) {
        do {
            try checkpoint?.save(progress: progress, keepsMacAwake: keepsMacAwake,
                                 failure: failureMessage, force: force)
        } catch {
            Log.error(category, "checkpoint_failed", nil, ["uid": uid, "error": error])
        }
    }

    private func updateSleepPrevention() {
        if keepsMacAwake && (state == .running || state == .pausing) {
            if sleepPrevention == nil { sleepPrevention = DownloadSleepPrevention(uid: uid) }
        } else {
            sleepPrevention = nil
        }
    }
}
