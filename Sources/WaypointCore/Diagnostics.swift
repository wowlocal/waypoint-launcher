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
        if !fields.isEmpty { record["fields"] = fields }
        if let version { record["version"] = version }

        let sanitized = Self.sanitizedFields(record)
        mirror(level, category, sanitized)
        guard let line = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .withoutEscapingSlashes])
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
            // Before writing, so the current file always exists afterwards. A
            // failed rotation (two in the same millisecond) keeps the line.
            if let size = try? handle?.offset(), size > maxFileBytes {
                try? rotate()
                if handle == nil { try open() }
            }
            handle?.write(line)
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

    private func mirror(_ level: Level, _ category: Category, _ record: [String: Any]) {
        lock.lock()
        let logger = loggers[category.rawValue] ?? Logger(subsystem: Self.subsystem, category: category.rawValue)
        loggers[category.rawValue] = logger
        lock.unlock()
        // Both sinks receive the same already sanitized record. Never format
        // the caller's Error/NSError again here: that prints its whole userInfo.
        let text = Self.mirrorText(record)
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
    }

    static func mirrorText(_ record: [String: Any]) -> String {
        let fields = record["fields"] as? [String: Any] ?? [:]
        let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return [record["event"] as? String, record["message"] as? String, details.isEmpty ? nil : details]
            .compactMap { $0 }.joined(separator: " ")
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
        /// The sanitized JSON line, including when reading an older log.
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
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        // Older versions may already have written an auth URL. Sanitize on
        // read too, so diagnostics exports never copy those secrets onward.
        let object = sanitizedFields(raw)
        guard let ts = object["ts"] as? String, let date = parseTimestamp(ts),
              let level = (object["level"] as? String).flatMap(Level.init(rawValue:)),
              let category = object["category"] as? String, let event = object["event"] as? String
        else { return nil }
        let fields = (object["fields"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return Event(date: date, level: level, category: category, event: event, message: object["message"] as? String,
                     process: object["process"] as? String ?? "?", line: String(decoding: data, as: UTF8.self), fields: fields)
    }

    // MARK: Helpers

    static func sanitizedFields(_ fields: [String: Any]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let name = key.lowercased().filter { $0.isLetter || $0.isNumber }
            return (key, secretFields.contains(name) ? "[redacted]" : jsonValue(value))
        })
    }

    private static let secretFields: Set<String> = [
        "password", "passwd", "pwd", "secret", "clientsecret", "credentials",
        "token", "webtoken", "st", "accesstoken", "refreshtoken", "idtoken",
        "authorization", "cookie", "cookies", "setcookie",
    ]

    static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let v as String: redact(v)
        case let v as URL: v.isFileURL ? v.path : redact(v.absoluteString)
        case let v as Error: describe(v)
        case let v as [String: Any]: sanitizedFields(v)
        case let v as [Any]: v.map(jsonValue)
        case let v as NSNull: v
        case let v as NSNumber: v
        default: redact(String(describing: value))
        }
    }

    /// Keep the host and path for diagnosis, but never URL credentials,
    /// queries or fragments: OAuth codes, ST tickets and state live there.
    /// Apply this to prose too because localized error descriptions can
    /// contain the failing URL instead of providing it as a separate value.
    private static let urlExpression = try! NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"']+"#)

    static func redact(_ text: String) -> String {
        var result = text
        for match in urlExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            // Punctuation belongs to the surrounding error prose, not the
            // URL. Keep it outside URLComponents so repeated redaction does
            // not turn a closing bracket into part of the URL's path.
            let raw = String(matched.reversed().drop(while: { ")]},.;".contains($0) }).reversed())
            let suffix = String(matched.dropFirst(raw.count))
            guard var url = URLComponents(string: raw), url.host != nil else {
                result.replaceSubrange(range, with: "[redacted URL]" + suffix)
                continue
            }
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            result.replaceSubrange(range, with: (url.string ?? "[redacted URL]") + suffix)
        }
        result = result.replacingOccurrences(of: #"(?i)\b[A-Z]{2}-[0-9a-f]{32}-[0-9]+\b"#,
                                             with: "[redacted]", options: .regularExpression)
        // Also handle raw NSError strings from old logs. Arbitrary userInfo
        // is never useful enough to risk retaining an unknown secret field.
        result = result.replacingOccurrences(of: #"(?s)UserInfo=\{.*\}"#,
                                             with: "UserInfo=[redacted]", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)(\b(?:authorization|cookie|set-cookie)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\r\n]+)"#,
            with: "$1[redacted]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\bBearer\s+[a-z0-9._~+/-]+=*"#,
                                             with: "Bearer [redacted]", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)(\b(?:password|passwd|pwd|secret|token|client[_-]?secret|web[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|cookie|ST)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&}]+)"#,
            with: "$1[redacted]", options: .regularExpression)
        return result
    }

    /// A compact error plus whitelisted network context. Never interpolate
    /// NSError/URLError or its arbitrary userInfo, including underlying errors.
    static func describe(_ error: Error) -> String { describe(error, depth: 0) }

    private static func describe(_ error: Error, depth: Int) -> String {
        if !(type(of: error) is NSError.Type), !(error is URLError) {
            let text = String(describing: error)
            if !text.contains("UserInfo=") { return redact(text) }
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(redact(ns.localizedDescription))"
        let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
        if let url { text += " (\(redact(url)))" }
        if depth < 3, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            text += " [underlying: \(describe(underlying, depth: depth + 1))]"
        }
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
