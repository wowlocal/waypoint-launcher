import Darwin
import Foundation
import os

/// Structured, agent-friendly logging.
///
/// Every event is one JSON object per line in `~/Library/Logs/Waypoint/`,
/// with a stable shape:
///
///     {"ts":"2026-10-04T14:30:00.123Z","level":"info","category":"update",
///      "event":"plan_ready","fields":{"files":3,"bytes":44912000},
///      "process":"Waypoint","pid":123,"version":"0.2.0"}
///
/// Events are also mirrored to the unified log (subsystem
/// `dev.waypoint.launcher`), so `log stream --predicate 'subsystem ==
/// "dev.waypoint.launcher"'` works too. Read them back with `waypoint-cli
/// logs` / `waypoint-cli diagnose`.
///
/// Never log secrets: no login tokens, no account identifiers, no cookies.
public final class Diagnostics: @unchecked Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        case debug, info, notice, warning, error

        var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }

        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .warning: .error
            case .error: .fault
            }
        }
    }

    public enum Category: String, Sendable, CaseIterable {
        case app, library, auth, launch, gameUpdate = "game_update", install, cdn, selfUpdate = "self_update", cli
    }

    public static let shared = Diagnostics(directory: directoryForThisProcess)

    /// `WAYPOINT_LOG_DIR` wins; test runs log to a temp folder so they don't
    /// fill the user's logs (and `waypoint-cli logs`) with test fixtures.
    static var directoryForThisProcess: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["WAYPOINT_LOG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        let testRunners: Set = ["swiftpm-testing-helper", "xctest"]
        if testRunners.contains(ProcessInfo.processInfo.processName) || env["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-test-logs", isDirectory: true)
        }
        return defaultDirectory
    }
    public static let subsystem = "dev.waypoint.launcher"

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Waypoint", isDirectory: true)
    }

    public let directory: URL
    /// Rotate a process's file past this size…
    let maxFileBytes: UInt64
    /// …and keep at most this many files in total.
    let maxFiles: Int
    /// Debug events are dropped unless verbose logging is on
    /// (`WAYPOINT_VERBOSE=1`, or `defaults write dev.waypoint.launcher VerboseLogging -bool YES`).
    public var verbose: Bool

    private let queue = DispatchQueue(label: "dev.waypoint.diagnostics")
    private let processName: String
    private let version: String?
    private var handle: FileHandle?
    private var currentFile: URL
    private var loggers: [String: Logger] = [:]
    private let lock = NSLock()

    public init(directory: URL = Diagnostics.defaultDirectory, maxFileBytes: UInt64 = 5 * 1024 * 1024, maxFiles: Int = 10,
                processName: String = ProcessInfo.processInfo.processName) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.processName = processName
        self.version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.verbose = ProcessInfo.processInfo.environment["WAYPOINT_VERBOSE"] == "1"
            || UserDefaults(suiteName: Diagnostics.subsystem)?.bool(forKey: "VerboseLogging") == true
        let safeName = processName.lowercased().replacingOccurrences(of: " ", with: "-")
        self.currentFile = directory.appendingPathComponent("\(safeName).jsonl")
    }

    // MARK: Writing

    public func log(_ level: Level, _ category: Category, _ event: String, _ message: String? = nil,
                    _ fields: [String: Any] = [:]) {
        guard level != .debug || verbose else { return }
        var record: [String: Any] = [
            "ts": Self.timestamp(Date()),
            "level": level.rawValue,
            "category": category.rawValue,
            "event": event,
            "process": processName,
            "pid": Int(getpid()),
        ]
        if let message { record["message"] = message }
        if !fields.isEmpty { record["fields"] = fields.mapValues(Self.jsonValue) }
        if let version { record["version"] = version }

        mirror(level, category, event, message, fields)
        guard let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        queue.async { self.append(line + Data("\n".utf8)) }
    }

    /// Waits until queued events are on disk (before exit, or before export).
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: Data) {
        do {
            if handle == nil { try open() }
            handle?.write(line)
            if let size = try? handle?.offset(), size > maxFileBytes { try rotate() }
        } catch {
            // Logging must never take the app down; the unified log still has it.
            handle = nil
        }
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: currentFile.path) {
            FileManager.default.createFile(atPath: currentFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: currentFile)
        try handle.seekToEnd()
        self.handle = handle
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let stamp = Self.timestamp(Date()).replacingOccurrences(of: ":", with: "-")
        let rotated = currentFile.deletingPathExtension().appendingPathExtension("\(stamp).jsonl")
        try FileManager.default.moveItem(at: currentFile, to: rotated)
        prune()
    }

    /// Deletes the oldest rotated files (`name.<timestamp>.jsonl`). Never a
    /// current file: the app and the CLI share this folder, and another
    /// process may be writing to its own. Runs right after rotation, while
    /// this process's current file is momentarily gone; leave room for it.
    private func prune() {
        let files = logFiles().filter { $0.lastPathComponent.split(separator: ".").count > 2 }
        let keep = max(maxFiles - 1, 1)
        guard files.count > keep else { return }
        for file in files.prefix(files.count - keep) { try? FileManager.default.removeItem(at: file) }
    }

    private func mirror(_ level: Level, _ category: Category, _ event: String, _ message: String?, _ fields: [String: Any]) {
        lock.lock()
        let logger = loggers[category.rawValue] ?? Logger(subsystem: Self.subsystem, category: category.rawValue)
        loggers[category.rawValue] = logger
        lock.unlock()
        let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let text = [event, message, details.isEmpty ? nil : details].compactMap { $0 }.joined(separator: " ")
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
    }

    // MARK: Reading

    /// Log files, oldest first (by modification time).
    public func logFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    public struct Event: Sendable {
        public var date: Date
        public var level: Level
        public var category: String
        public var event: String
        public var message: String?
        public var process: String
        /// The original JSON line, for `--json` output.
        public var line: String
        public var fields: [String: String]
    }

    /// All events from every process, merged in time order.
    public func events(since: Date? = nil, minimumLevel: Level = .debug) -> [Event] {
        flush()
        var events: [Event] = []
        for file in logFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let event = Self.parse(String(line)) else { continue }
                if let since, event.date < since { continue }
                if event.level < minimumLevel { continue }
                events.append(event)
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    static func parse(_ line: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let ts = object["ts"] as? String, let date = parseTimestamp(ts),
              let level = (object["level"] as? String).flatMap(Level.init(rawValue:)),
              let category = object["category"] as? String, let event = object["event"] as? String
        else { return nil }
        let fields = (object["fields"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        return Event(date: date, level: level, category: category, event: event, message: object["message"] as? String,
                     process: object["process"] as? String ?? "?", line: line, fields: fields)
    }

    // MARK: Helpers

    static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let v as Bool: v
        case let v as Int: v
        case let v as Int32: Int(v)
        case let v as Int64: v
        case let v as UInt64: v
        case let v as UInt32: Int(v)
        case let v as Double: v
        case let v as String: v
        case let v as URL: v.path
        case let v as Error: describe(v)
        default: String(describing: value)
        }
    }

    /// One line per error: our own errors as they describe themselves,
    /// system ones as `domain code: description` (not the userInfo dump).
    static func describe(_ error: Error) -> String {
        if !(type(of: error) is NSError.Type) {
            let text = String(describing: error)
            if !text.contains("UserInfo=") { return text }
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let url = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { text += " (\(url))" }
        return text
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let formatterLock = NSLock()

    /// ISO 8601 with milliseconds, as written in the logs.
    public static func timestampString(_ date: Date) -> String { timestamp(date) }

    static func timestamp(_ date: Date) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.date(from: string)
    }
}

/// Shorthand for the shared logger: `Log.info(.launch, "spawned", ["pid": pid])`.
public enum Log {
    public static func debug(_ c: Diagnostics.Category, _ e: String, _ m: String? = nil, _ f: [String: Any] = [:]) {
        Diagnostics.shared.log(.debug, c, e, m, f)
    }
    public static func info(_ c: Diagnostics.Category, _ e: String, _ m: String? = nil, _ f: [String: Any] = [:]) {
        Diagnostics.shared.log(.info, c, e, m, f)
    }
    public static func notice(_ c: Diagnostics.Category, _ e: String, _ m: String? = nil, _ f: [String: Any] = [:]) {
        Diagnostics.shared.log(.notice, c, e, m, f)
    }
    public static func warning(_ c: Diagnostics.Category, _ e: String, _ m: String? = nil, _ f: [String: Any] = [:]) {
        Diagnostics.shared.log(.warning, c, e, m, f)
    }
    public static func error(_ c: Diagnostics.Category, _ e: String, _ m: String? = nil, _ f: [String: Any] = [:]) {
        Diagnostics.shared.log(.error, c, e, m, f)
    }
}
