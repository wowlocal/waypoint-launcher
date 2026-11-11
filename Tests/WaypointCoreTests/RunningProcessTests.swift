import Foundation
import Testing
@testable import WaypointCore

/// The process list here is made up, spelled the way `kernelPath` spells
/// paths; the test below checks real processes are listed in that spelling.
@Test func anAppIsRunningWhenAProcessRunsItsExecutable() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-running-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("Real/Game.app")
    let neighbor = root.appendingPathComponent("Real/Game.app Helper")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: neighbor, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.appendingPathComponent("Real"))
    func isRunning(_ bundle: URL, _ executable: String) -> Bool {
        RunningProcesses.isRunning(bundle: bundle, in: [(1, "/sbin/launchd"), (500, executable)])
    }

    // The temporary folder's path goes through a link (/var), as an install
    // path may; the kernel's path doesn't.
    let inside = try #require(RunningProcesses.kernelPath(of: app))
    #expect(inside.hasPrefix("/private/var/"))
    let game = inside + "/Contents/MacOS/Game"
    #expect(isRunning(app, game))
    #expect(isRunning(root.appendingPathComponent("Link/Game.app"), game))
    #expect(!isRunning(neighbor, game))
    #expect(!isRunning(root.appendingPathComponent("Real/Missing.app"), game))
    #expect(!RunningProcesses.isRunning(bundle: app, in: []))

    // Not the game: a helper app nested in the bundle, and a neighbor whose
    // name begins with the bundle's.
    #expect(!isRunning(app, inside + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
    #expect(!isRunning(app, inside + "/Contents/MacOS/Helper.app/Contents/MacOS/Helper"))
    #expect(!isRunning(app, try #require(RunningProcesses.kernelPath(of: neighbor)) + "/Contents/MacOS/Game"))
}

@Test func kernelPathMatchesHowProcessesAreListed() throws {
    #expect(RunningProcesses.kernelPath(of: URL(fileURLWithPath: "/tmp")) == "/private/tmp")
    let own = try #require(RunningProcesses.executables().first { $0.pid == getpid() })
    #expect(RunningProcesses.kernelPath(of: URL(fileURLWithPath: own.path)) == own.path)
    #expect(RunningProcesses.kernelPath(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")) == nil)
}
