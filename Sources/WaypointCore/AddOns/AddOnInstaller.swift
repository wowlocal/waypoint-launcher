import Foundation

/// Swaps add-on folders in `Interface/AddOns`. Acts only on single folder
/// names directly inside that folder: no path it takes can reach `WTF` or
/// anything else.
struct AddOnInstaller: Sendable {
    let addOns: URL
    /// Moves an item to the Trash; returns where it went.
    var trash: @Sendable (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
    /// Test hook: fails a step to prove the rollback.
    var fault: @Sendable (Step) throws -> Void = { _ in }

    enum Step: CaseIterable, Sendable { case moveOut, moveIn }

    /// What to do: which folders on disk go (`remove`, their names as on
    /// disk), and which staged folders come in.
    struct Plan: Equatable, Sendable {
        var remove: [String]
        var install: [String]
        /// Of `remove`, the untouched copies of a release Waypoint installed:
        /// deleted. Everything else goes to the Trash.
        var deletes: Set<String> = []
    }

    /// Works out the plan from what's on disk now. `package` is the zip's
    /// folders, `target` the add-on being updated (nil for a new one),
    /// `others` every other add-on in the folder. `targetUntouched`: the
    /// target's folders are as Waypoint installed them. `mayAbsorb`: the zip
    /// is from a reviewed source, so it may take over another add-on it
    /// ships whole (Dominos' zip carries Masque_Dominos, which WoWInterface
    /// lists on its own).
    static func plan(package: [String], target: InstalledAddOn?, others: [InstalledAddOn],
                     onDisk: [InstalledFolder], targetUntouched: Bool, mayAbsorb: Bool) throws -> Plan {
        let disk = Dictionary(onDisk.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let mine = Set((target?.folders ?? []).map { $0.lowercased() })
        var owners: [String: InstalledAddOn] = [:]
        for other in others { for folder in other.folders { owners[folder.lowercased()] = other } }

        let packaged = Set(package.map { $0.lowercased() })
        var remove: [String] = []
        var deletes: Set<String> = []
        let recorded = Set((target?.record?.folders ?? []).map { $0.lowercased() })
        for folder in package {
            let key = folder.lowercased()
            // Something the scan doesn't list (a file, a folder without a
            // TOC) stops the swap before anything moves.
            guard let found = disk[key] else { continue }
            if found.kind == .link || found.kind == .developmentCopy || found.kind == .blizzard { throw AddOnError.notSafe(found.name) }
            if mine.contains(key) {
                remove.append(found.name)
                if targetUntouched, recorded.contains(key) { deletes.insert(found.name) }
                continue
            }
            // Another add-on Waypoint updates owns it: taken over only when
            // the zip is reviewed and carries all of that add-on; never a
            // folder of an add-on it ships only part of.
            if let other = owners[key], other.isManaged, other.id != target?.id {
                let whole = other.folders.allSatisfy { packaged.contains($0.lowercased()) }
                guard mayAbsorb, whole else { throw AddOnError.conflict(folder: found.name, owner: other.name) }
            }
            // Unmanaged: very likely this add-on, installed another way. Its
            // old copy goes to the Trash.
            remove.append(found.name)
        }
        // Folders the old version had and the new one doesn't: only when
        // Waypoint installed them.
        if let record = target?.record {
            let new = Set(package.map { $0.lowercased() })
            for folder in record.folders where !new.contains(folder.lowercased()) {
                if let found = disk[folder.lowercased()], found.kind != .link, found.kind != .developmentCopy, !remove.contains(found.name) {
                    remove.append(found.name)
                    if targetUntouched { deletes.insert(found.name) }
                }
            }
        }
        return Plan(remove: remove, install: package, deletes: deletes)
    }

    /// Moves the old folders out (into `old`, or the Trash), the staged ones
    /// in, and puts everything back if any move fails. One uninterrupted
    /// step: the caller holds the lock and has just looked at the disk.
    /// `gameFolder` (`_retail_`) must exist: `Interface/AddOns` is made in
    /// it if the game hasn't yet, but no game folder is ever made up.
    func swap(_ plan: Plan, staged: URL, old: URL, gameFolder: URL? = nil) throws {
        let fm = FileManager.default
        for name in plan.remove + plan.install { guard Self.isFolderName(name) else { throw AddOnError.notSafe(name) } }
        let leaving = Set(plan.remove.map { $0.lowercased() })
        for name in plan.install where !leaving.contains(name.lowercased()) {
            var info = stat()
            if lstat(addOns.appendingPathComponent(name).path, &info) == 0 { throw AddOnError.notSafe(name) }
        }
        var movedOut: [(name: String, to: URL)] = []
        var movedIn: [String] = []
        do {
            if !plan.deletes.isEmpty { try fm.createDirectory(at: old, withIntermediateDirectories: true) }
            for name in plan.remove {
                let source = addOns.appendingPathComponent(name, isDirectory: true)
                if plan.deletes.contains(name) {
                    let destination = old.appendingPathComponent(name, isDirectory: true)
                    try fm.moveItem(at: source, to: destination)
                    movedOut.append((name, destination))
                } else {
                    movedOut.append((name, try trash(source)))
                }
                try fault(.moveOut)
            }
            if !fm.fileExists(atPath: addOns.path) {
                let game = gameFolder ?? addOns.deletingLastPathComponent().deletingLastPathComponent()
                guard fm.fileExists(atPath: game.path) else { throw CocoaError(.fileNoSuchFile) }
                try fm.createDirectory(at: addOns, withIntermediateDirectories: true)
            }
            for name in plan.install {
                try fm.moveItem(at: staged.appendingPathComponent(name, isDirectory: true),
                                to: addOns.appendingPathComponent(name, isDirectory: true))
                movedIn.append(name)
                try fault(.moveIn)
            }
        } catch {
            var restored = true
            for name in movedIn.reversed() {
                do {
                    try fm.moveItem(at: addOns.appendingPathComponent(name, isDirectory: true),
                                    to: staged.appendingPathComponent(name, isDirectory: true))
                } catch { restored = false }
            }
            for (name, place) in movedOut.reversed() {
                do { try fm.moveItem(at: place, to: addOns.appendingPathComponent(name, isDirectory: true)) } catch { restored = false }
            }
            Log.error(.addOns, restored ? "swap_rolled_back" : "swap_rollback_failed", nil,
                      ["error": error, "moved_out": movedOut.map(\.name).joined(separator: ","),
                       "moved_in": movedIn.joined(separator: ",")])
            if !restored { throw AddOnError.incomplete(name: plan.install.first ?? "the add-on") }
            throw error
        }
    }

    /// To the Trash, every folder or none: a failure puts back the ones
    /// already moved.
    func remove(_ folders: [String]) throws {
        for name in folders { guard Self.isFolderName(name) else { throw AddOnError.notSafe(name) } }
        var moved: [(String, URL)] = []
        do {
            for name in folders {
                let url = addOns.appendingPathComponent(name, isDirectory: true)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw AddOnError.notSafe(name) }
                moved.append((name, try trash(url)))
                try fault(.moveOut)
            }
        } catch {
            for (name, place) in moved.reversed() {
                try? FileManager.default.moveItem(at: place, to: addOns.appendingPathComponent(name, isDirectory: true))
            }
            throw error
        }
    }

    /// One plain folder name: nothing that leaves `Interface/AddOns`.
    static func isFolderName(_ name: String) -> Bool {
        AddOnPackage.isSafeComponent(name) && !name.contains("/") && !name.hasPrefix(".")
    }
}
