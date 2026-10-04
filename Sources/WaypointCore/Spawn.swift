import Darwin
import Foundation

/// Starts a game as its own, independent process.
///
/// Battle.net launches games through LaunchServices, so each game is its own
/// "responsible process" for privacy prompts (WoW voice chat asks for the
/// microphone). A plain child process would make macOS attribute those prompts
/// to us instead, so we disclaim responsibility the way terminals do. We also
/// can't use NSWorkspace, because it can't set the working directory the
/// games expect.
enum Spawn {
    struct Failure: Error, LocalizedError {
        var errno: Int32
        var errorDescription: String? { String(cString: strerror(errno)) }
    }

    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Private but long-stable libsystem call; looked up at runtime so a
    /// future macOS without it just falls back to a normal spawn.
    private static let disclaim: DisclaimFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    static func detached(executable: URL, arguments: [String], workingDirectory: URL) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group, so signals aimed at us (Ctrl-C in a terminal) don't reach the game.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        _ = disclaim?(&attributes, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw Failure(errno: result) }

        // Reap the child when it exits so it doesn't linger as a zombie while we run.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return pid
    }
}
