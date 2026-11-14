import Foundation

/// Read-only discovery at a user-chosen location. Never follows metadata paths
/// from another Mac: the folder holding the record is the installation root.
public enum LocatedGames {
    /// A folder chosen with File ▸ Locate Installed Games: one installed
    /// game's (or a WoW root's). Remembered with an ordinary bookmark, so a
    /// drive that is renamed or mounts as "Ext 1" still resolves, and with the
    /// games last found there, which stay in the library while its drive
    /// isn't connected.
    public struct Location: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// Where it was when last found; the fallback when the bookmark doesn't resolve.
        public var path: String
        public var bookmark: Data?
        /// The volume it is on, to tell without touching any disk whether
        /// that volume is mounted. Nil for one saved without it (or a volume
        /// that has none, such as some network shares): its path tells.
        public var volumeUUID: String?
        /// The games last found here (`ProductInstall.key`s in `installs`).
        public var installs: [ProductInstall]
        /// Games removed from the library (Remove from Library): not listed
        /// from here again, unless the folder is located again.
        public var removedKeys: [String]

        public init(id: String = UUID().uuidString, path: String, bookmark: Data? = nil, volumeUUID: String? = nil,
                    installs: [ProductInstall] = [], removedKeys: [String] = []) {
            self.id = id
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.bookmark = bookmark
            self.volumeUUID = volumeUUID
            self.installs = installs
            self.removedKeys = removedKeys
        }

        private enum CodingKeys: String, CodingKey { case id, path, bookmark, volumeUUID, installs, removedKeys }

        /// Only the path is required: a location saved by another version
        /// still reads.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let path = try container.decode(String.self, forKey: .path)
            self.init(id: try container.decodeIfPresent(String.self, forKey: .id) ?? path, path: path,
                      bookmark: try? container.decodeIfPresent(Data.self, forKey: .bookmark),
                      volumeUUID: try? container.decodeIfPresent(String.self, forKey: .volumeUUID),
                      installs: (try? container.decodeIfPresent([ProductInstall].self, forKey: .installs)) ?? [],
                      removedKeys: (try? container.decodeIfPresent([String].self, forKey: .removedKeys)) ?? [])
        }

        /// A location for `url`, which is read (a bookmark, the volume): off
        /// the main thread.
        public init(at url: URL, installs: [ProductInstall]) {
            self.init(path: url.path, installs: installs)
            refreshIdentity(at: url)
        }

        /// The folder of a game Waypoint installed there: what it holds,
        /// and `install` even before its records are read back. Reads the
        /// disk: off the main thread.
        public init(installedAt url: URL, install: ProductInstall) {
            let found = LocatedGames.installs(at: url)
            self.init(at: url, installs: found.contains { $0.key == install.key } ? found : found + [install])
        }

        mutating func refreshIdentity(at url: URL) {
            path = url.standardizedFileURL.path
            // Not security-scoped: Waypoint isn't sandboxed.
            bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            volumeUUID = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }

        /// The games listed from here.
        public var listedInstalls: [ProductInstall] { installs.filter { !removedKeys.contains($0.key) } }

        /// Whether `path` is this folder or inside it.
        public func contains(_ path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return path == self.path || path.hasPrefix(self.path.hasSuffix("/") ? self.path : self.path + "/")
        }
    }

    /// The remembered locations, in the user's defaults. Read and written on
    /// one thread (the main one); scanning them is `scan`'s job.
    public struct Store {
        public static let key = "locatedGameFolders"
        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        public func locations() -> [Location] {
            switch defaults.object(forKey: Self.key) {
            case let data as Data:
                return (try? JSONDecoder().decode([Location].self, from: data)) ?? []
            case let paths as [String]:
                // The first version kept bare paths. Their bookmark, volume
                // and games are filled in (and saved) the first time each is
                // scanned; the path is the id until then.
                return paths.map { Location(id: $0, path: $0) }
            default:
                return []
            }
        }

        private func save(_ locations: [Location]) {
            guard let data = try? JSONEncoder().encode(locations) else { return }
            defaults.set(data, forKey: Self.key)
        }

        /// Remembers `new` first. One for a folder already remembered
        /// replaces it, and lists what it removed from the library again.
        public func add(_ new: [Location]) {
            let paths = Set(new.map(\.path))
            save(new + locations().filter { !paths.contains($0.path) })
        }

        /// Remembers the folder of a game Waypoint installed (see
        /// `Location(installedAt:install:)`), whose key is `installed`. One
        /// already remembered there keeps its id and the other games found
        /// there, and lists that game again; others removed from the library
        /// stay removed.
        public func record(_ new: Location, installed: String?) {
            var all = locations()
            guard let index = all.firstIndex(where: { $0.path == new.path }) else {
                save([new] + all)
                return
            }
            var merged = new
            merged.id = all[index].id
            let keys = Set(new.installs.map(\.key))
            merged.installs = new.installs + all[index].installs.filter { !keys.contains($0.key) }
            merged.removedKeys = all[index].removedKeys.filter { $0 != installed }
            all[index] = merged
            save(all)
        }

        /// Forgets a game that was uninstalled from `path`, and the folder
        /// it was in once nothing else was found there. Returns whether
        /// anything was forgotten.
        @discardableResult
        public func forget(key: String, at path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            let all = locations()
            let kept: [Location] = all.compactMap { location in
                guard location.contains(path) else { return location }
                var location = location
                location.installs.removeAll { $0.key == key && URL(fileURLWithPath: $0.installPath).standardizedFileURL.path == path }
                location.removedKeys.removeAll { $0 == key }
                return location.path == path && location.installs.isEmpty ? nil : location
            }
            guard kept != all else { return false }
            save(kept)
            return true
        }

        /// Forgets the whole location.
        public func remove(id: String) {
            save(locations().filter { $0.id != id })
        }

        /// Forgets one game listed from a location, and the location once
        /// nothing else is listed from it. Never touches the game's files.
        public func remove(key: String, from id: String) {
            var all = locations()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            if !all[index].removedKeys.contains(key) { all[index].removedKeys.append(key) }
            if all[index].listedInstalls.isEmpty { all.remove(at: index) }
            save(all)
        }

        /// Takes what a scan found out (where a location is now, the games
        /// there) for the locations still remembered. What was removed from
        /// the library meanwhile stays removed.
        public func update(with scanned: [Location]) {
            let scanned = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let all = locations()
            let updated = all.map { location in
                guard var found = scanned[location.id] else { return location }
                found.removedKeys = location.removedKeys
                return found
            }
            if updated != all { save(updated) }
        }
    }

    /// The remembered locations as last scanned: where each is now and the
    /// games there, and which are on a drive that isn't connected (their
    /// games are the ones last found there).
    public struct Scan: Equatable, Sendable {
        public var locations: [Location]
        public var disconnected: Set<String>

        public init(locations: [Location] = [], disconnected: Set<String> = []) {
            self.locations = locations
            self.disconnected = disconnected
        }

        /// The remembered locations before they are scanned: reads only the
        /// list of mounted volumes, so it may be used on the main thread. A
        /// location whose volume can't be told from its path counts as connected.
        public static func unscanned(_ locations: [Location], fileManager fm: FileManager = .default) -> Scan {
            let mounted = Set((fm.mountedVolumeURLs(includingResourceValuesForKeys: [], options: []) ?? []).map(\.standardizedFileURL.path))
            return Scan(locations: locations,
                        disconnected: Set(locations.filter { !isMounted(path: $0.path, mounted: mounted) }.map(\.id)))
        }

        public var connected: [Location] { locations.filter { !disconnected.contains($0.id) } }
        public var offline: [Location] { locations.filter { disconnected.contains($0.id) } }
    }

    /// A path under `/Volumes/<name>` is on that volume; any other is on
    /// the startup disk, which is always there.
    static func isMounted(path: String, mounted: Set<String>) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return mounted.contains("/Volumes/" + parts[2])
    }

    /// Finds where each location is now and reads the games there. One on a
    /// volume that isn't mounted isn't touched: its games are those last
    /// found there. Reads every connected location: off the main thread.
    public static func scan(_ locations: [Location], fileManager fm: FileManager = .default) -> Scan {
        guard !locations.isEmpty else { return Scan() }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        let mountedPaths = Set(volumes.map(\.standardizedFileURL.path))
        let mountedUUIDs = Set(volumes.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
        var scan = Scan()
        for var location in locations {
            let mounted = location.volumeUUID.map(mountedUUIDs.contains) ?? isMounted(path: location.path, mounted: mountedPaths)
            guard mounted else {
                scan.locations.append(location)
                scan.disconnected.insert(location.id)
                continue
            }
            var stale = false
            let resolved = location.bookmark.flatMap {
                try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            let url = resolved ?? URL(fileURLWithPath: location.path, isDirectory: true)
            // The path is only a fallback on the same drive: another one by
            // that name may be mounted there now.
            let sameVolume = resolved != nil || location.volumeUUID == nil ||
                (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == location.volumeUUID
            var isDirectory: ObjCBool = false
            // A bookmark follows a folder into the Trash (uninstalled, or
            // dragged there): it's gone all the same.
            if sameVolume, !isInTrash(url), fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                var found = installs(at: url, fileManager: fm)
                // A game known here whose files are still here stays, though
                // its records aren't (Battle.net's isn't written while it runs).
                let rebased = location.installs.filter { known in !found.contains { $0.key == known.key } }.map { known in
                    var known = known; known.installPath = url.standardizedFileURL.path; return known
                }
                found += rebased.filter { GameCatalog.game(for: $0, fileManager: fm).isInstalled }
                location.installs = found
                if resolved == nil || stale || location.volumeUUID == nil || url.standardizedFileURL.path != location.path {
                    location.refreshIdentity(at: url)
                }
            } else {
                // Its drive is there but the folder isn't: the games are
                // gone, and aren't kept as if their drive were away. The
                // location stays, should the folder come back.
                location.installs = []
            }
            scan.locations.append(location)
        }
        return scan
    }

    /// The folders of `installs` (Waypoint's own records) that are outside
    /// the built-in ones, on a connected drive, and not remembered yet: an
    /// earlier version installed them there without remembering them. Only
    /// what is on disk now, so a stale record never shows up as a game on
    /// a drive that isn't connected. Reads the disk: off the main thread.
    public static func unremembered(_ installs: [ProductInstall], known: [Location],
                                    chosen: InstallLocations, fileManager fm: FileManager = .default) -> [Location] {
        var found: [Location] = []
        for install in installs where chosen.isChosen(installPath: install.installPath) {
            let url = URL(fileURLWithPath: install.installPath, isDirectory: true).standardizedFileURL
            guard !(known + found).contains(where: { $0.contains(url.path) }),
                  InstallVolume.missingDrive(for: url.path, fileManager: fm) == nil,
                  !isInTrash(url),
                  GameCatalog.game(for: install, fileManager: fm).isInstalled else { continue }
            found.append(Location(installedAt: url, install: install))
        }
        return found
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// The locations in or around `selection` that have supported installed
    /// games: the folder itself, the WoW root above an edition folder or app,
    /// or the game folders in a folder of games. Each is read once, and comes
    /// with its bookmark: off the main thread.
    public static func locate(at selection: URL, fileManager fm: FileManager = .default) -> [Location] {
        let selected = selection.standardizedFileURL
        var candidates = [selected]
        // Accept a WoW edition folder (or app) as well as its shared root.
        candidates.append(selected.deletingLastPathComponent())
        if selected.pathExtension == "app" { candidates.append(selected.deletingLastPathComponent().deletingLastPathComponent()) }
        // A games collection folder is convenient; do not crawl entire drives.
        if selected.pathExtension != "app", let children = try? fm.contentsOfDirectory(at: selected,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            candidates += children.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.resolvingSymlinksInPath().path).inserted else { return nil }
            let found = installs(at: candidate, fileManager: fm)
            return found.isEmpty ? nil : Location(at: candidate, installs: found)
        }
    }

    public static func installs(at root: URL, fileManager fm: FileManager = .default) -> [ProductInstall] {
        let rootPath = root.standardizedFileURL.path
        var found: [ProductInstall] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent(".product.db")),
           let records = try? ProductDB.parseFolderInstalls(data) {
            found = records.map { record in
                var local = record; local.installPath = rootPath; return local
            }
        }
        // Shared WoW roots sometimes have only one .product.db entry. Its
        // active build rows identify the other installed editions accurately.
        if let text = try? String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8) {
            let rows = BPSV(text).rows.filter { $0["Active"] == "1" }
            for row in rows {
                guard let code = row["Product"], let product = InstallableProduct.forProduct(code),
                      let tags = row["Tags"], let platform = InstallPlatform.from(tags: tags),
                      product.supportedPlatforms.contains(platform) else { continue }
                let matchingRows = rows.filter { $0["Product"] == code && InstallPlatform.from(tags: $0["Tags"]) == platform }
                let knownRegion = found.first { $0.productCode == code && $0.platform == platform }?.region
                if matchingRows.count > 1 {
                    guard let knownRegion, row["Branch"] == knownRegion,
                          matchingRows.filter({ $0["Branch"] == knownRegion }).count == 1 else { continue }
                }
                let branch = row["Branch"].flatMap(Region.init(rawValue:))?.rawValue
                if let knownRegion, let branch, knownRegion != branch { continue }
                let install = ProductInstall(uid: product.uid, productCode: code, installPath: rootPath,
                    region: branch, version: row["Version"], buildConfig: row["Build Key"], tagString: tags, platform: platform)
                if let index = found.firstIndex(where: { $0.key == install.key }) {
                    found[index].region = branch ?? found[index].region
                    found[index].version = install.version
                    found[index].buildConfig = install.buildConfig
                    found[index].tagString = install.tagString
                } else { found.append(install) }
            }
        }
        return found.filter { install in
            guard let product = InstallableProduct.forProduct(install.productCode),
                  product.supportedPlatforms.contains(install.platform),
                  (try? install.platform.validate(install: install, fileManager: fm)) != nil else { return false }
            return GameCatalog.game(for: install, fileManager: fm).isInstalled
        }
    }
}
