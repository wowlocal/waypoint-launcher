import Foundation

/// An add-on as the list shows it: one row, though it may be several
/// folders (DBM-Core, DBM-GUI…).
public struct InstalledAddOn: Identifiable, Equatable, Sendable {
    /// Why Waypoint doesn't update it.
    public enum Unmanaged: Equatable, Sendable {
        /// From CurseForge or Wago (its TOC says so), which other apps can't
        /// download from.
        case curseForge(String), wago(String)
        case unknown
        case developmentCopy
        case link
        case notForThisVersion
    }

    /// The ref, or `folder:<main folder>`.
    public var id: String
    public var name: String
    /// The main folder first.
    public var folders: [String]
    public var version: String?
    public var author: String?
    /// Where Waypoint updates it from.
    public var ref: AddOnRef?
    public var unmanaged: Unmanaged?
    /// Only when Waypoint put these folders there.
    public var record: AddOnRecord?
    /// When the main TOC last changed.
    public var modified: Date?

    public var isManaged: Bool { ref != nil }
}

/// Works out which add-on each folder belongs to, from the folders alone:
/// what Waypoint installed, then IDs in the TOCs, then the index's folder
/// names. No guessing beyond that.
public struct AddOnMatcher: Sendable {
    public var index: AddOnIndex

    public init(index: AddOnIndex = .bundled) { self.index = index }

    public func match(_ folders: [InstalledFolder], records: [AddOnRecord]) -> [InstalledAddOn] {
        let byName = Dictionary(folders.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var owner: [String: String] = [:]          // lowercased folder → add-on id
        var rows: [String: InstalledAddOn] = [:]
        var order: [String] = []

        func add(_ folder: InstalledFolder, to id: String, make: () -> InstalledAddOn) {
            if rows[id] == nil { rows[id] = make(); order.append(id) }
            if !rows[id]!.folders.contains(folder.name) { rows[id]!.folders.append(folder.name) }
            owner[folder.name.lowercased()] = id
        }

        // 1. What Waypoint installed is its own, whatever the folders say.
        for record in records {
            for name in record.folders {
                guard let folder = byName[name.lowercased()], owner[name.lowercased()] == nil else { continue }
                add(folder, to: record.ref.description) {
                    InstalledAddOn(id: record.ref.description, name: record.name, folders: [], ref: record.ref, record: record)
                }
            }
        }

        // 2–5. IDs in the TOC, then the index's folder names.
        for folder in folders where folder.kind == .addOn && owner[folder.name.lowercased()] == nil {
            guard let (ref, entry) = identify(folder) else { continue }
            add(folder, to: ref.description) {
                InstalledAddOn(id: ref.description, name: entry?.name ?? folder.toc?.title ?? folder.name, folders: [], ref: ref)
            }
        }

        // Folders left over join an add-on when the TOC says they belong to
        // it; the rest are add-ons of their own.
        let rest = folders.filter { owner[$0.name.lowercased()] == nil && $0.kind != .blizzard }
        func parent(of folder: InstalledFolder) -> String? {
            guard folder.kind == .addOn || folder.kind == .notForThisVersion, let toc = folder.toc else { return nil }
            let candidates = ([toc.group].compactMap { $0 } + toc.dependencies).filter { $0.lowercased() != folder.name.lowercased() }
            for name in candidates {
                guard let other = byName[name.lowercased()], other.kind != .link else { continue }
                let isGroup = toc.group?.lowercased() == name.lowercased()
                guard isGroup || Self.sharesFamily(folder.name, other.name) else { continue }
                // Its own different ID makes it an add-on of its own.
                if let otherTOC = other.toc, Self.hasOwnID(toc, comparedWith: otherTOC) { continue }
                return other.name
            }
            return nil
        }
        var attached: [String: String] = [:]
        for folder in rest { if let name = parent(of: folder) { attached[folder.name] = name } }
        func root(_ name: String) -> String {
            var current = name, steps = 0
            while let next = attached[current], steps < 8 { current = next; steps += 1 }
            return current
        }
        for folder in rest where attached[folder.name] == nil {
            add(folder, to: "folder:\(folder.name)") {
                InstalledAddOn(id: "folder:\(folder.name)", name: folder.toc?.title ?? folder.name, folders: [],
                               unmanaged: Self.reason(folder))
            }
        }
        for folder in rest where attached[folder.name] != nil {
            let top = root(folder.name)
            guard let id = owner[top.lowercased()] else {
                // A loop: keep the folder visible on its own.
                add(folder, to: "folder:\(folder.name)") {
                    InstalledAddOn(id: "folder:\(folder.name)", name: folder.toc?.title ?? folder.name, folders: [], unmanaged: Self.reason(folder))
                }
                continue
            }
            add(folder, to: id) { rows[id]! }
        }

        // The main folder names the row and gives its version.
        return order.compactMap { id -> InstalledAddOn? in
            guard var row = rows[id] else { return nil }
            let entry = row.ref.flatMap(index.entry(for:))
            let main = row.record.map(\.mainFolder).flatMap { m in row.folders.first { $0.lowercased() == m.lowercased() } }
                ?? entry?.folders.lazy.compactMap { m in row.folders.first { $0.lowercased() == m.lowercased() } }.first
                ?? row.folders.filter { byName[$0.lowercased()]?.toc?.isLoadOnDemand != true }.min { $0.count < $1.count }
                ?? row.folders.min { $0.count < $1.count }!
            row.folders = [main] + row.folders.filter { $0 != main }.sorted()
            let folder = byName[main.lowercased()]
            row.version = folder?.toc?.version
            row.author = folder?.toc?.author ?? entry?.author
            row.modified = folder?.tocModified
            if row.ref != nil, row.record == nil { row.name = entry?.name ?? folder?.toc?.title ?? row.name }
            else if row.ref == nil { row.name = folder?.toc?.title ?? main }
            return row
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Steps 2–5 of the order: Tukui, the index by ID, WoWInterface by ID,
    /// the index by folder name.
    func identify(_ folder: InstalledFolder) -> (AddOnRef, AddOnIndex.Entry?)? {
        let toc = folder.toc
        if let tukui = toc?.tukuiID.flatMap({ ["-1": "tukui", "-2": "elvui"][$0] }) ?? ["elvui": "elvui", "tukui": "tukui"][folder.name.lowercased()] {
            let ref = AddOnRef(.tukui, tukui)
            return (ref, index.entry(for: ref))
        }
        if let toc, let entry = index.entry(curse: toc.curseID, wago: toc.wagoID, wowi: toc.wowiID) { return (entry.source, entry) }
        if let wowi = toc?.wowiID, toc?.isLoadOnDemand != true { return (AddOnRef(.wowInterface, wowi), nil) }
        if let entry = index.entry(folder: folder.name, toc: toc) { return (entry.source, entry) }
        return nil
    }

    /// DBM-Brawlers and DBM-Core: the part before the first `-` or `_`.
    static func sharesFamily(_ a: String, _ b: String) -> Bool {
        func family(_ name: String) -> String {
            String(name.lowercased().prefix { $0 != "-" && $0 != "_" })
        }
        return family(a) == family(b) && !family(a).isEmpty
    }

    static func hasOwnID(_ toc: AddOnTOC, comparedWith other: AddOnTOC) -> Bool {
        func differs(_ a: String?, _ b: String?) -> Bool { a != nil && a != b }
        return differs(toc.curseID, other.curseID) || differs(toc.wagoID, other.wagoID) ||
            differs(toc.wowiID, other.wowiID) || differs(toc.tukuiID, other.tukuiID)
    }

    static func reason(_ folder: InstalledFolder) -> InstalledAddOn.Unmanaged {
        switch folder.kind {
        case .link: return .link
        case .developmentCopy: return .developmentCopy
        case .notForThisVersion: return .notForThisVersion
        case .addOn, .blizzard: break
        }
        if let curse = folder.toc?.curseID { return .curseForge(curse) }
        if let wago = folder.toc?.wagoID { return .wago(wago) }
        return .unknown
    }
}
