import Foundation

/// A one-shot snapshot of everything useful for diagnosing Waypoint: the
/// machine, the installed Waypoint, the games it sees, its own install
/// records, Battle.net's presence, and the latest warnings and errors.
/// `waypoint-cli diagnose` prints it; the app's "Export Diagnostics…"
/// saves it next to the logs.
public enum DiagnosticsReport {
    public static func make(library: GameLibrary = GameLibrary(), recentProblems: Int = 30) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var report: [String: Any] = [
            "generated_at": Diagnostics.timestamp(Date()),
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "arch": machineArchitecture(),
            "rosetta_installed": FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"),
            "log_directory": Diagnostics.shared.directory.path,
            "verbose_logging": Diagnostics.shared.verbose,
        ]

        let installedApp = URL(fileURLWithPath: "/Applications/Waypoint.app")
        if let info = Bundle(url: installedApp)?.infoDictionary {
            report["waypoint_app"] = [
                "path": installedApp.path,
                "version": info["CFBundleShortVersionString"] as? String ?? "?",
                "build": info["CFBundleVersion"] as? String ?? "?",
                "feed": info["SUFeedURL"] as? String ?? "none",
            ]
        }

        report["games"] = library.games().map { game -> [String: Any] in
            [
                "uid": game.install.uid,
                "product": game.install.productCode,
                "name": game.displayName,
                "path": game.install.installPath,
                "version": game.install.version ?? "?",
                "build_config": game.install.buildConfig ?? "?",
                "region": game.install.region ?? "?",
                "language": game.install.textLanguage ?? "?",
                "app": game.appURL?.path ?? "not found",
                "architectures": game.architectures.map(\.rawValue).sorted(),
                "supported": game.isSupported,
                "running": !RunningProcesses.inside(URL(fileURLWithPath: game.install.installPath)).isEmpty,
            ]
        }
        report["waypoint_install_records"] = library.stateStore.load().mapValues { build -> [String: Any] in
            ["version": build.version, "build_config": build.buildConfig, "path": build.installPath ?? "(Battle.net install)"]
        }
        report["battle_net"] = [
            "app_installed": FileManager.default.fileExists(atPath: "/Applications/Battle.net.app"),
            "agent_database": FileManager.default.fileExists(atPath: ProductDB.agentDatabaseURL.path),
            "running": !RunningProcesses.inside(URL(fileURLWithPath: "/Applications/Battle.net.app")).isEmpty
                || !RunningProcesses.inside(URL(fileURLWithPath: "/Users/Shared/Battle.net")).isEmpty,
        ]

        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        report["recent_problems"] = Diagnostics.shared.events(since: since, minimumLevel: .warning)
            .suffix(recentProblems)
            .map { "\(Diagnostics.timestamp($0.date)) \($0.level.rawValue) \($0.category)/\($0.event) \($0.message ?? "") \($0.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))" }
        return report
    }

    public static func json(_ report: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the report plus the last week of logs into one JSONL file:
    /// first line is the report, then every event.
    @discardableResult
    public static func export(to file: URL, library: GameLibrary = GameLibrary()) throws -> Int {
        let report = make(library: library)
        var out = (try JSONSerialization.data(withJSONObject: ["report": report], options: [.sortedKeys, .withoutEscapingSlashes]))
        out.append(Data("\n".utf8))
        let events = Diagnostics.shared.events(since: Date().addingTimeInterval(-7 * 24 * 3600))
        for event in events { out.append(Data((event.line + "\n").utf8)) }
        try out.write(to: file, options: .atomic)
        Log.info(.app, "diagnostics_exported", nil, ["path": file.path, "events": events.count])
        return events.count
    }

    static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
