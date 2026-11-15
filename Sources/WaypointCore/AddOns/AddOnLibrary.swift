import CryptoKit
import Foundation

/// Whether an add-on has an update.
public enum AddOnUpdate: Equatable, Sendable {
    case current(AddOnRelease)
    case available(AddOnRelease)
    case unavailable(AddOnSourceError)

    public var release: AddOnRelease? {
        switch self {
        case .current(let release), .available(let release): release
        case .unavailable: nil
        }
    }
}

/// A search result: an add-on Waypoint can install.
public struct AddOnSearchResult: Equatable, Sendable, Identifiable {
    public var ref: AddOnRef
    public var name: String
    public var author: String?
    public var id: String { ref.description }
}

/// One `Interface/AddOns` folder: all disk and network work on it, off the
/// main thread, one change at a time.
public actor AddOnLibrary {
    public nonisolated let addOns: URL
    public nonisolated let flavor: WoWFlavor?
    let interface: Int?
    let store: AddOnStore
    let sources: [AddOnSourceID: any AddOnSource]
    let matcher: AddOnMatcher
    let http: AddOnHTTP
    var installer: AddOnInstaller
    /// A same-volume folder for one install, removed after.
    let staging: @Sendable (URL) throws -> URL
    let cache: URL
    let now: @Sendable () -> Date

    private var wowInterfaceList: [WoWInterfaceAddOnSource.ListEntry]?

    public init(addOns: URL, flavor: WoWFlavor?, interface: Int?, store: AddOnStore = AddOnStore(),
                http: AddOnHTTP = .live, sources: [any AddOnSource]? = nil, index: AddOnIndex = .bundled,
                cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Waypoint/AddOns", isDirectory: true),
                staging: @escaping @Sendable (URL) throws -> URL = AddOnLibrary.replacementDirectory,
                trash: (@Sendable (URL) throws -> URL)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.addOns = addOns
        self.flavor = flavor
        self.interface = interface
        self.store = store
        self.http = http
        self.sources = Dictionary((sources ?? AddOnSources.live(http: http)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        matcher = AddOnMatcher(index: index)
        var installer = AddOnInstaller(addOns: addOns)
        if let trash { installer.trash = trash }
        self.installer = installer
        self.staging = staging
        self.cache = cache
        self.now = now
    }

    /// For a game: its AddOns folder and the flavor it is.
    public init?(game: Game) {
        guard game.family == .worldOfWarcraft, game.install.platform == .macOS, let folder = game.addOnsLocation else { return nil }
        self.init(addOns: folder, flavor: WoWFlavor.of(game.install), interface: WoWFlavor.interface(version: game.install.version))
    }

    /// `.itemReplacementDirectory` next to the game: same volume, so the
    /// swap is renames; outside the game folder, so the game never sees it;
    /// and macOS clears it if Waypoint doesn't.
    public static let replacementDirectory: @Sendable (URL) throws -> URL = { addOns in
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: existingAncestor(of: addOns), create: true)
    }

    /// The game's own folder (`_retail_`), which holds `Interface/AddOns`.
    nonisolated var gameFolder: URL { addOns.deletingLastPathComponent().deletingLastPathComponent() }

    // MARK: Scan

    /// What's installed, as list rows. Reads only, apart from dropping
    /// records that no longer apply.
    public func scan() throws -> [InstalledAddOn] {
        let folders = try AddOnScanner().scan(addOns, flavor: flavor)
        return matcher.match(folders, records: try upkeep(folders))
    }

    /// A record goes when its main folder is there with another version:
    /// something else updated the add-on. A missing folder keeps it (someone
    /// moved Interface aside to test without add-ons, or the drive went).
    private func upkeep(_ folders: [InstalledFolder]) throws -> [AddOnRecord] {
        let records = store.load(for: addOns)
        let byName = Dictionary(folders.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let kept = records.filter { record in
            guard let main = byName[record.mainFolder.lowercased()] else { return true }
            return main.toc?.version == record.tocVersion
        }
        if kept != records {
            Log.info(.addOns, "records_dropped", nil, ["count": records.count - kept.count])
            try store.save(kept, for: addOns)
        }
        return kept
    }

    // MARK: Check

    /// The update state of each managed add-on, by id.
    public func check(_ installed: [InstalledAddOn]) async -> [String: AddOnUpdate] {
        guard let flavor else { return [:] }
        let managed = installed.filter(\.isManaged)
        var latest: [AddOnRef: Result<AddOnRelease, AddOnSourceError>] = [:]
        for (sourceID, addOns) in Dictionary(grouping: managed, by: { $0.ref!.source }) {
            guard let source = sources[sourceID] else { continue }
            let refs = Array(Set(addOns.map { $0.ref! }))
            latest.merge(await source.latest(refs, flavor: flavor, interface: interface)) { first, _ in first }
        }
        var updates: [String: AddOnUpdate] = [:]
        for addOn in managed {
            switch latest[addOn.ref!] {
            case .success(let release): updates[addOn.id] = Self.decide(addOn, latest: release) ? .available(release) : .current(release)
            case .failure(let error): updates[addOn.id] = .unavailable(error)
            case nil: updates[addOn.id] = .unavailable(.unavailable)
            }
        }
        Log.info(.addOns, "checked", nil, ["flavor": flavor.rawValue, "managed": managed.count,
                                            "updates": updates.values.filter { if case .available = $0 { true } else { false } }.count])
        return updates
    }

    /// Whether `latest` is an update. For what Waypoint installed: a
    /// different release that isn't older (Tukui dates only by the day, so
    /// a second release that day counts). For anything else: different
    /// versions, and the release more than an hour newer than the files on
    /// disk. Files are never older than the release they came from, so a
    /// source whose newest release is older than them is behind: no
    /// "update" to an old copy, and nothing downloaded again.
    static func decide(_ addOn: InstalledAddOn, latest: AddOnRelease) -> Bool {
        if let record = addOn.record {
            guard latest.id != record.release.id else { return false }
            if let new = latest.date, let old = record.release.date { return new >= old }
            return true
        }
        if let version = addOn.version, normalized(version) == normalized(latest.version) { return false }
        guard let released = latest.date, let installed = addOn.modified else { return false }
        return released > installed.addingTimeInterval(3600)
    }

    static func normalized(_ version: String) -> String {
        var text = version.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        return text
    }

    // MARK: Install

    /// Downloads, checks and swaps in `release`. `replacing` is the row
    /// being updated; nil installs a new add-on. A Waypoint-installed add-on
    /// whose files someone changed is left alone unless `evenIfChanged`.
    /// `holds`, asked again just before the swap, stops it with
    /// `gameRunning`: automatic updates pass one that's true while the game
    /// is open or starting.
    public func install(_ release: AddOnRelease, name: String, replacing: InstalledAddOn?, evenIfChanged: Bool = false,
                        holds: (@Sendable () -> Bool)? = nil,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let flavor else { throw AddOnError.unknownGame }
        // The game's folder must be there: Waypoint never makes one up.
        guard FileManager.default.fileExists(atPath: gameFolder.path) else { throw CocoaError(.fileNoSuchFile) }
        if holds?() == true { throw AddOnError.gameRunning }
        // Checked before downloading, and again at the swap.
        if let record = replacing?.record, !evenIfChanged, AddOnContentHash.changed(record, in: addOns) {
            throw AddOnError.changedLocally
        }
        let zip = try await http.download(release.download, 1 << 30, progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        if let md5 = release.md5 {
            let digest = Insecure.MD5.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == md5 else { throw AddOnError.checksum }
        }
        let package = try AddOnPackage(zip: zip, flavor: flavor)
        if let free = try? InstallVolume.read(at: Self.existingAncestor(of: addOns))?.availableCapacity,
           free < package.uncompressedBytes + 100_000_000 {
            throw AddOnError.notEnoughSpace
        }
        let work = try staging(addOns)
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try package.extract(to: staged)

        // From here to the record, no suspension: a fresh look at the disk,
        // then the swap.
        if holds?() == true { throw AddOnError.gameRunning }
        let lock = try store.lock(for: addOns)
        defer { withExtendedLifetime(lock) {} }
        let folders = try AddOnScanner().scan(addOns, flavor: flavor)
        let rows = matcher.match(folders, records: try upkeep(folders))
        let target = rows.first { $0.ref == release.ref } ?? replacing.flatMap { r in rows.first { $0.id == r.id } }
        var untouched = false
        if let record = target?.record {
            untouched = !AddOnContentHash.changed(record, in: addOns)
            if !untouched && !evenIfChanged { throw AddOnError.changedLocally }
        }
        let plan = try AddOnInstaller.plan(package: package.folders, target: target,
                                           others: rows.filter { $0.id != target?.id }, onDisk: folders,
                                           targetUntouched: untouched, mayAbsorb: release.ref.source != .wowInterface)
        try installer.swap(plan, staged: staged, old: work.appendingPathComponent("old", isDirectory: true),
                           gameFolder: gameFolder)

        // Remember what Waypoint put there.
        let installedFolders = try AddOnScanner().scan(addOns, flavor: flavor).filter { f in package.folders.contains(f.name) }
        let entry = matcher.index.entry(for: release.ref)
        let main = entry?.folders.first { package.folders.contains($0) }
            ?? installedFolders.filter { $0.toc?.isLoadOnDemand != true && $0.kind == .addOn }.map(\.name).min { $0.count < $1.count }
            ?? package.folders.min { $0.count < $1.count }!
        let record = AddOnRecord(ref: release.ref, name: name, mainFolder: main, folders: package.folders, release: release,
                                 folderHashes: AddOnContentHash.of(package.folders, in: addOns),
                                 tocVersion: installedFolders.first { $0.name == main }?.toc?.version)
        var records = store.load(for: addOns).filter { existing in
            existing.ref != release.ref && !existing.folders.contains { f in package.folders.contains { $0.lowercased() == f.lowercased() } }
        }
        records.append(record)
        try store.save(records, for: addOns)
        Log.info(.addOns, "installed", nil, ["ref": release.ref.description, "version": release.version,
                                              "folders": package.folders.count, "replaced": plan.remove.count])
    }

    /// The latest release for this game, then `install`.
    public func install(_ ref: AddOnRef, name: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard FileManager.default.fileExists(atPath: gameFolder.path) else { throw CocoaError(.fileNoSuchFile) }
        guard let flavor else { throw AddOnError.unknownGame }
        guard let source = sources[ref.source] else { throw AddOnSourceError.unavailable }
        switch await source.latest([ref], flavor: flavor, interface: interface)[ref] {
        case .success(let release):
            let current = try scan().first { $0.ref == ref }
            try await install(release, name: name, replacing: current, progress: progress)
        case .failure(let error): throw error
        case nil: throw AddOnSourceError.unavailable
        }
    }

    // MARK: Remove

    /// Every folder of an add-on Waypoint updates, to the Trash. Its saved
    /// settings (in WTF) stay, as with every add-on manager.
    public func remove(_ addOn: InstalledAddOn) throws {
        guard addOn.isManaged else { throw AddOnError.notSafe(addOn.folders.first ?? addOn.name) }
        let lock = try store.lock(for: addOns)
        defer { withExtendedLifetime(lock) {} }
        let folders = try AddOnScanner().scan(addOns, flavor: flavor)
        let current = matcher.match(folders, records: try upkeep(folders)).first { $0.id == addOn.id }
        guard let current else { return }
        for name in current.folders {
            if let folder = folders.first(where: { $0.name == name }), folder.kind == .link || folder.kind == .developmentCopy {
                throw AddOnError.notSafe(name)
            }
        }
        try installer.remove(current.folders)
        try store.save(store.load(for: addOns).filter { $0.ref != current.ref }, for: addOns)
        Log.info(.addOns, "removed", nil, ["ref": current.ref?.description ?? "-", "folders": current.folders.count])
    }

    // MARK: Search

    /// The index's matches first, then WoWInterface's, without duplicates;
    /// at most 30.
    public func search(_ text: String) async throws -> [AddOnSearchResult] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var results = matcher.index.search(text).map { AddOnSearchResult(ref: $0.source, name: $0.name, author: $0.author) }
        let known = Set(matcher.index.entries.compactMap(\.wowi))
        if let flavor {
            let list = try await wowInterfaceEntries()
            let date = now()
            let matches = list.filter { entry in
                !known.contains(entry.UID) && entry.suits(flavor, now: date) &&
                    words.allSatisfy { "\(entry.UIName) \(entry.UIAuthorName ?? "")".lowercased().contains($0) }
            }
            .sorted { a, b in
                let (ra, rb) = (AddOnIndex.rank(a.UIName, words), AddOnIndex.rank(b.UIName, words))
                return ra != rb ? ra < rb : a.downloads > b.downloads
            }
            results += matches.prefix(30).map { AddOnSearchResult(ref: AddOnRef(.wowInterface, $0.UID), name: $0.UIName, author: $0.UIAuthorName) }
        }
        return Array(results.prefix(30))
    }

    /// WoWInterface's whole list, from a day-old cache or the network. Kept
    /// in memory only while this library is. One fetch serves every search:
    /// a search given up on (the next keystroke) doesn't stop it.
    private func wowInterfaceEntries() async throws -> [WoWInterfaceAddOnSource.ListEntry] {
        if let wowInterfaceList { return wowInterfaceList }
        if let listFetch { return try await listFetch.value }
        let fetch = Task { try await self.fetchWoWInterfaceList() }
        listFetch = fetch
        do {
            let list = try await fetch.value
            wowInterfaceList = list
            listFetch = nil
            return list
        } catch {
            listFetch = nil
            throw error
        }
    }

    private var listFetch: Task<[WoWInterfaceAddOnSource.ListEntry], Error>?

    private func fetchWoWInterfaceList() async throws -> [WoWInterfaceAddOnSource.ListEntry] {
        let file = cache.appendingPathComponent("wowinterface-filelist.json")
        let decoder = JSONDecoder()
        if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           now().timeIntervalSince(modified) < 86400,
           let list = try? decoder.decode([WoWInterfaceAddOnSource.ListEntry].self, from: Data(contentsOf: file)) {
            return list
        }
        let response = try await http.get(WoWInterfaceAddOnSource.listURL)
        guard response.status == 200 else { throw HTTPFailure(status: response.status, url: WoWInterfaceAddOnSource.listURL) }
        let list = try decoder.decode([WoWInterfaceAddOnSource.ListEntry].self, from: response.data)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? response.data.write(to: file, options: .atomic)
        return list
    }

    static func existingAncestor(of url: URL) -> URL {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        return existing
    }
}
