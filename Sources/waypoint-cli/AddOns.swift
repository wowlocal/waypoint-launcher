import Foundation
import WaypointCore

/// `waypoint-cli addons [uid] [--path AddOnsFolder --flavor mainline] [--update]`:
/// the add-ons of each installed WoW version (or one), what Waypoint makes
/// of them, and whether each has an update. Changes nothing unless
/// `--update`, which installs every update the app would.
func addOnsCommand(_ args: [String]) async {
    var uid: String?, path: String?, flavorName: String?, updates = false
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--path": path = rest.popFirst()
        case "--flavor": flavorName = rest.popFirst()
        case "--update": updates = true
        default: uid = arg
        }
    }
    var libraries: [(String, AddOnLibrary)] = []
    if let path {
        let flavor = flavorName.flatMap(WoWFlavor.init(rawValue:)) ?? .mainline
        libraries = [(path, AddOnLibrary(addOns: URL(fileURLWithPath: path, isDirectory: true), flavor: flavor, interface: nil))]
    } else {
        for game in GameLibrary().games() where uid == nil || game.install.uid == uid {
            if let library = AddOnLibrary(game: game) { libraries.append((game.displayName, library)) }
        }
    }
    guard !libraries.isEmpty else { fail("No World of Warcraft version found\(uid.map { " for \($0)" } ?? "").") }
    for (name, library) in libraries {
        print("\(name) — \(library.flavor?.rawValue ?? "unknown game") — \(library.addOns.path)")
        do {
            var rows = try await library.scan()
            var states = await library.check(rows)
            if updates {
                for row in rows {
                    guard case .available(let release) = states[row.id] else { continue }
                    do {
                        try await library.install(release, name: row.name, replacing: row)
                        print("  updated \(row.name) to \(release.version)")
                    } catch {
                        print("  couldn’t update \(row.name): \(errorMessage(error))")
                    }
                }
                rows = try await library.scan()
                states = await library.check(rows)
            }
            for row in rows {
                let state: String
                switch states[row.id] {
                case .available(let release): state = "update \(release.version)"
                case .current: state = "current"
                case .unavailable(let error): state = "unavailable: \(error)"
                case nil:
                    switch row.unmanaged {
                    case .curseForge(let id): state = "not updated (CurseForge \(id))"
                    case .wago(let id): state = "not updated (Wago \(id))"
                    case .unknown: state = "not updated"
                    case .developmentCopy: state = "not updated (development copy)"
                    case .link: state = "not updated (link)"
                    case .notForThisVersion: state = "not for this version"
                    case nil: state = "-"
                    }
                }
                let source = row.ref.map { " [\($0)]" } ?? ""
                let installed = row.record != nil ? " (installed by Waypoint)" : ""
                print("  \(row.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \((row.version ?? "-").padding(toLength: 16, withPad: " ", startingAt: 0)) \(state)\(source)\(installed)")
                if row.folders.count > 1 { print("      folders: \(row.folders.joined(separator: ", "))") }
            }
        } catch {
            print("  \(errorMessage(error))")
        }
    }
}
