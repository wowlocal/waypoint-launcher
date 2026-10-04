import Foundation
import WaypointCore

/// `logs [--since 2h|30m|7d] [--level warning] [--category game_update] [--grep text] [--limit N] [--json] [--follow]`
func logs(_ args: [String]) async {
    let usage = "usage: waypoint-cli logs [--since 2h|30m|7d] [--level debug|info|notice|warning|error] [--category NAME] [--grep TEXT] [--limit N] [--json] [--follow]"
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 0
    while i < args.count {
        if ["--since", "--level", "--category", "--grep", "--limit"].contains(args[i]) {
            guard i + 1 < args.count else { fail(usage) }
            options[args[i]] = args[i + 1]
            i += 2
        } else if ["--json", "--follow"].contains(args[i]) {
            flags.insert(args[i])
            i += 1
        } else {
            fail(usage)
        }
    }
    var since = Date().addingTimeInterval(-24 * 3600)
    if let text = options["--since"] {
        guard let seconds = parseDuration(text) else { fail("bad --since \(text); use e.g. 30m, 2h, 7d") }
        since = Date().addingTimeInterval(-seconds)
    }
    guard let level = Diagnostics.Level(rawValue: options["--level"] ?? "debug") else { fail(usage) }
    let category = options["--category"]
    let needle = options["--grep"]?.lowercased()
    let limit = options["--limit"].flatMap(Int.init)
    let json = flags.contains("--json")

    func matching(since: Date) -> [Diagnostics.Event] {
        Diagnostics.shared.events(since: since, minimumLevel: level).filter { event in
            (category == nil || event.category == category) && (needle == nil || event.line.lowercased().contains(needle!))
        }
    }

    var shown = matching(since: since)
    if let limit { shown = Array(shown.suffix(limit)) }
    shown.forEach { print(format($0, json: json)) }
    guard flags.contains("--follow") else { return }

    var last = shown.last?.date ?? Date()
    var seen = Set(shown.suffix(50).map(\.line))
    while true {
        try? await Task.sleep(for: .seconds(1))
        for event in matching(since: last) where !seen.contains(event.line) {
            print(format(event, json: json))
            fflush(stdout)
            seen.insert(event.line)
            last = max(last, event.date)
        }
    }
}

/// `diagnose`: the snapshot as JSON (pipe it to jq).
func diagnose() {
    print(DiagnosticsReport.json(DiagnosticsReport.make()))
}

func format(_ event: Diagnostics.Event, json: Bool) -> String {
    if json { return event.line }
    let time = Diagnostics.timestampString(event.date)
    let fields = event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let parts = [time, event.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0),
                 "\(event.category)/\(event.event)", event.message, fields.isEmpty ? nil : fields, "[\(event.process)]"]
    return parts.compactMap { $0 }.joined(separator: "  ")
}

func parseDuration(_ text: String) -> TimeInterval? {
    guard let unit = text.last, let value = Double(text.dropLast()) else { return nil }
    switch unit {
    case "s": return value
    case "m": return value * 60
    case "h": return value * 3600
    case "d": return value * 86400
    default: return nil
    }
}
