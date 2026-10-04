import Observation

/// Runs `apply` now, and again after any `@Observable` property it read
/// changes: how the AppKit views follow `AppModel` and `AppUpdater`. Changes
/// made together are coalesced into one run.
@MainActor
func observeChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeChanges(apply) }
    }
}
