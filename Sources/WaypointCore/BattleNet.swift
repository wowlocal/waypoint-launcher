import Darwin
import Foundation

/// Battle.net's own processes. Waypoint doesn't install or update games
/// while they run, so the two never write to the same game files at once
/// (the Agent patches games in the background). Simpler and sturdier than
/// sharing the Agent's locks.
public enum BattleNet {
    public enum Process: Sendable, Equatable {
        /// The Battle.net app (or one of its helpers).
        case app
        /// The background Agent that installs and patches games.
        case agent
    }

    /// Which Battle.net process an executable is, if any. The app lives
    /// wherever it was installed; the Agent in
    /// `/Users/Shared/Battle.net/Agent/Agent.<build>/Agent.app`.
    static func kind(ofExecutable path: String) -> Process? {
        if path.contains("/Battle.net.app/Contents/") { return .app }
        if path.contains("/Battle.net/Agent/"), path.hasSuffix("/Contents/MacOS/Agent") { return .agent }
        return nil
    }

    public static func running() -> Set<Process> {
        Set(RunningProcesses.executables().compactMap { kind(ofExecutable: $0.path) })
    }

    /// Throws while Battle.net or its Agent is running.
    public static func ensureNotRunning() throws {
        let running = running()
        guard running.isEmpty else {
            Log.warning(.gameUpdate, "battlenet_running", nil, ["app": running.contains(.app), "agent": running.contains(.agent)])
            throw UpdateError.battleNetRunning(agentOnly: !running.contains(.app))
        }
    }
}
