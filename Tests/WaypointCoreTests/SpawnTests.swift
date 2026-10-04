import Foundation
import Testing
@testable import WaypointCore

@Test func spawnSetsWorkingDirectoryArgumentsAndProcessGroup() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-spawn-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let pid = try Spawn.detached(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "{ pwd -P; echo \"$1\"; ps -o pgid= -p $$; } > out.txt", "sh", "-launch -uid x"],
        workingDirectory: dir)

    let out = dir.appendingPathComponent("out.txt")
    for _ in 0..<50 where !(fm.fileExists(atPath: out.path) && (try? String(contentsOf: out, encoding: .utf8))?.split(separator: "\n").count == 3) {
        try await Task.sleep(for: .milliseconds(100))
    }
    let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(lines.count == 3)
    let realDir = try #require(realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) })
    #expect(lines.first == realDir)
    #expect(lines.dropFirst().first == "-launch -uid x")
    #expect(lines.last == String(pid), "child should lead its own process group")
    #expect(getpgrp() != pid)
}

@Test func spawnReportsMissingExecutable() {
    #expect(throws: (any Error).self) {
        try Spawn.detached(executable: URL(fileURLWithPath: "/nonexistent/game"), arguments: [],
                           workingDirectory: URL(fileURLWithPath: "/tmp"))
    }
}
