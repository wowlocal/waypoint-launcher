import Foundation

public enum GameFamily: String, Sendable {
    case hearthstone
    case worldOfWarcraft
    case other
}

/// A launchable game on disk.
public struct Game: Identifiable, Equatable, Sendable {
    public var id: String { install.key }
    public var install: ProductInstall
    public var family: GameFamily
    public var displayName: String
    /// The `.app` bundle to run, if we could find it.
    public var appURL: URL?
    public var architectures: Set<Architecture>
    /// On a remembered location's drive that isn't connected: it stays in
    /// the library, but can't be played, updated or verified.
    public var isOffline = false
    /// The remembered location (File ▸ Locate Installed Games) it is listed
    /// from, if any: Remove from Library forgets it there.
    public var locationID: String?
    /// A Windows game's program was in its folder when this was read, so
    /// asking whether it is installed doesn't read the disk again.
    var hasWindowsProgram = false

    public enum Architecture: String, Sendable {
        case arm64, x86_64
    }

    public var runsNatively: Bool { architectures.contains(.arm64) }

    /// Whether the library lists it: it's on disk, or on a remembered drive
    /// that isn't connected. Either way it isn't offered for download again.
    public var isListed: Bool { isInstalled || isOffline }

    /// As it was when the game was read (`GameCatalog.game`): never reads
    /// the disk, so a view may ask as often as it likes.
    public var isInstalled: Bool {
        install.platform == .windows ? hasWindowsProgram : appURL != nil
    }

    /// Whether Waypoint knows how to log this game in without Battle.net.
    /// Intel-only games run through Rosetta when it's installed.
    public var isSupported: Bool {
        if install.platform == .windows { return isInstalled && WindowsTitle.forInstall(install)?.isAvailable == true }
        return InstallableProduct.forProduct(install.productCode)?.supportedPlatforms.contains(.macOS) == true &&
            appURL != nil && (runsNatively || Rosetta.isInstalled)
    }

    /// What to select in the Finder to show where the game is: its app, a
    /// Windows game's program, or failing both the install folder.
    public var finderItem: URL {
        if let appURL { return appURL }
        let root = URL(fileURLWithPath: install.installPath, isDirectory: true)
        if let title = WindowsTitle.forInstall(install) {
            let program = root.appendingPathComponent(title.executablePath)
            if FileManager.default.fileExists(atPath: program.path) { return program }
        }
        return root
    }

    /// A World of Warcraft version's add-ons folder, once there is one: the
    /// game makes it the first time it runs.
    public var addOnsFolder: URL? {
        guard family == .worldOfWarcraft else { return nil }
        let folder = URL(fileURLWithPath: install.installPath, isDirectory: true)
            .appendingPathComponent(GameCatalog.wowFolder(for: install.productCode), isDirectory: true)
            .appendingPathComponent("Interface/AddOns", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : nil
    }
}

public enum GameCatalog {
    /// WoW keeps every flavor under one root; the product code picks the folder.
    static let wowFlavorFolders: [String: String] = [
        "wow": "_retail_",
        "wowt": "_ptr_",
        "wowxptr": "_xptr_",
        "wow_beta": "_beta_",
        "wow_classic": "_classic_",
        "wow_classic_ptr": "_classic_ptr_",
        "wow_classic_beta": "_classic_beta_",
        "wow_classic_era": "_classic_era_",
        "wow_classic_era_ptr": "_classic_era_ptr_",
        "wow_anniversary": "_anniversary_",
    ]

    static let wowFlavorNames: [String: String] = [
        "wow": "World of Warcraft",
        "wowt": "World of Warcraft PTR",
        "wowxptr": "World of Warcraft PTR 2",
        "wow_beta": "World of Warcraft Beta",
        "wow_classic": "WoW Classic",
        "wow_classic_ptr": "WoW Classic PTR",
        "wow_classic_beta": "WoW Classic Beta",
        "wow_classic_era": "WoW Classic Era",
        "wow_classic_era_ptr": "WoW Classic Era PTR",
        "wow_anniversary": "WoW Classic Anniversary",
    ]

    static let otherNames: [String: String] = [
        "w3": "Warcraft III",
        "s1": "StarCraft",
        "s2": "StarCraft II",
        "d3": "Diablo III",
        "pro": "Overwatch",
    ]

    public static func family(for productCode: String) -> GameFamily {
        if productCode.hasPrefix("hs") { return .hearthstone }
        if productCode.hasPrefix("wow") { return .worldOfWarcraft }
        return .other
    }

    public static func game(for install: ProductInstall, fileManager: FileManager = .default) -> Game {
        let name = displayName(for: install)
        if install.platform == .windows {
            let program = WindowsTitle.forInstall(install).map {
                URL(fileURLWithPath: install.installPath).appendingPathComponent($0.executablePath).path
            }
            return Game(install: install, family: .other, displayName: name, appURL: nil, architectures: [.x86_64],
                        hasWindowsProgram: program.map(fileManager.fileExists(atPath:)) ?? false)
        }
        let family = family(for: install.productCode)
        let root = URL(fileURLWithPath: install.installPath, isDirectory: true)
        var appURL: URL?

        switch family {
        case .hearthstone:
            appURL = existing(root.appendingPathComponent("Hearthstone.app"), fileManager)
        case .worldOfWarcraft:
            let folder = wowFolder(for: install.productCode)
            appURL = firstApp(in: root.appendingPathComponent(folder), prefix: "World of Warcraft", fileManager)
        case .other:
            appURL = ["", "_retail_", "_retail_/arm64", "_retail_/x86_64"].lazy
                .compactMap { firstApp(in: root.appendingPathComponent($0), prefix: nil, fileManager) }
                .first
        }

        // Known products: the exact app the product config names.
        if let product = InstallableProduct.forProduct(install.productCode), product.supportedPlatforms.contains(.macOS),
           let exact = existing(root.appendingPathComponent(product.appPath), fileManager) {
            appURL = exact
        }

        return Game(
            install: install,
            family: family,
            displayName: name,
            appURL: appURL,
            architectures: appURL.map(architectures(of:)) ?? []
        )
    }

    /// A game whose drive isn't connected, made without touching any disk.
    public static func offlineGame(for install: ProductInstall) -> Game {
        Game(install: install, family: install.platform == .windows ? .other : family(for: install.productCode),
             displayName: displayName(for: install), appURL: nil, architectures: [], isOffline: true)
    }

    public static func displayName(for install: ProductInstall) -> String {
        if install.platform == .windows { return WindowsTitle.forInstall(install)?.displayName ?? install.productCode }
        if let product = InstallableProduct.forProduct(install.productCode), product.supportedPlatforms.contains(.macOS) {
            return product.displayName
        }
        switch family(for: install.productCode) {
        case .hearthstone: return install.productCode == "hsb" ? "Hearthstone" : "Hearthstone (\(install.productCode))"
        case .worldOfWarcraft: return wowFlavorNames[install.productCode] ?? install.productCode
        case .other: return otherNames[install.productCode] ?? install.productCode
        }
    }

    public static func architectures(of appURL: URL) -> Set<Game.Architecture> {
        guard let archs = Bundle(url: appURL)?.executableArchitectures else { return [] }
        var result: Set<Game.Architecture> = []
        for arch in archs.map(\.intValue) {
            if arch == NSBundleExecutableArchitectureARM64 { result.insert(.arm64) }
            if arch == NSBundleExecutableArchitectureX86_64 { result.insert(.x86_64) }
        }
        return result
    }

    static func wowFolder(for productCode: String) -> String {
        InstallableProduct.forProduct(productCode)?.flavorFolder ?? wowFlavorFolders[productCode] ?? "_\(productCode)_"
    }

    private static func existing(_ url: URL, _ fm: FileManager) -> URL? {
        fm.fileExists(atPath: url.path) ? url : nil
    }

    private static func firstApp(in dir: URL, prefix: String?, _ fm: FileManager) -> URL? {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items
            .filter { $0.pathExtension == "app" }
            .filter { prefix == nil || $0.lastPathComponent.hasPrefix(prefix!) }
            // Skip helper apps like "Warcraft III Launcher.app".
            .filter { !$0.lastPathComponent.localizedCaseInsensitiveContains("launcher") }
            .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            .first
    }
}

/// Finds installed games from every source we know about. It only reads, so
/// it may be used from any thread: the one member that isn't Sendable is the
/// file manager, and `FileManager.default` is safe to share.
public struct GameLibrary: @unchecked Sendable {
    public var agentDatabase: URL
    /// Folders to scan for a `.product.db`, so games keep working after the
    /// Battle.net app is removed.
    public var searchRoots: [URL] {
        get { explicitSearchRoots ?? Self.defaultSearchRoots }
        set { explicitSearchRoots = newValue }
    }
    private var explicitSearchRoots: [URL]?
    public var fileManager: FileManager
    public var stateStore: InstallStateStore
    /// Folders chosen with File ▸ Locate Installed Games, as last scanned
    /// (`LocatedGames.scan`, off the main thread): their games only fill in
    /// what the other sources don't have, or whose files are gone.
    public var located = LocatedGames.Scan()
    /// Whether games on a drive other than the startup disk are read there.
    /// Off on the main thread, which mustn't wait for a drive that is slow,
    /// asleep or being ejected: those games are as `otherDriveGames` has them.
    public var readsOtherDrives = true
    /// The games on other drives as last read (by a scan with
    /// `readsOtherDrives`), by `factsKey`; nil for one whose folder wasn't
    /// there. One not among them at all isn't listed until it is read.
    public var otherDriveGames: [String: Game?] = [:]
    /// Tells which paths are on another drive, by the volumes mounted when
    /// it is made. Tests stand in for drives with it.
    var otherDrives: @Sendable (FileManager) -> (String) -> Bool = { fm in
        let mounted = InstallVolume.mountedPaths(fileManager: fm)
        return { InstallVolume.isOnOtherDrive($0, mounted: mounted) }
    }

    /// What tells one game's files from another's: the install, and where it is.
    public static func factsKey(_ install: ProductInstall) -> String {
        install.key + "|" + URL(fileURLWithPath: install.installPath).standardizedFileURL.path
    }

    /// Every supported game's default folder: Battle.net can forget a game
    /// (it lost HotS once), and Waypoint should still find it there rather
    /// than offer a fresh install.
    public static var defaultSearchRoots: [URL] { InstallableProduct.native.map(\.folderName)
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0, isDirectory: true) }
        + WindowsTitle.enabled.map {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/" + $0.folderName + " (Windows)", isDirectory: true)
        }
    }

    public init(agentDatabase: URL = ProductDB.agentDatabaseURL,
                searchRoots: [URL]? = nil,
                fileManager: FileManager = .default,
                stateStore: InstallStateStore = InstallStateStore()) {
        self.agentDatabase = agentDatabase
        self.explicitSearchRoots = searchRoots
        self.fileManager = fileManager
        self.stateStore = stateStore
    }

    public func installs() -> [ProductInstall] { entries().map(\.install) }

    public func games() -> [Game] {
        var skipped = OtherDrives()
        return games(otherDrives: &skipped)
    }

    /// What `games` didn't read on other drives (see `readsOtherDrives`).
    public struct OtherDrives: Sendable {
        /// Whether any game is on another drive: what is known about it
        /// may be out of date.
        public var skipped = false
        /// The uids of the games there that haven't been read at all, and
        /// aren't listed until they are.
        public var unread: Set<String> = []
        /// With `readsOtherDrives`: what was read there, found or not, for
        /// `otherDriveGames`.
        public var read: [String: Game?] = [:]

        public init() {}
    }

    /// `games`, and what of them wasn't read on other drives.
    public func games(otherDrives: inout OtherDrives) -> [Game] {
        let read = GameReader(self)
        defer {
            otherDrives = OtherDrives()
            otherDrives.skipped = read.skipped
            otherDrives.unread = read.unread
            otherDrives.read = read.otherDrives
        }
        return entries(read).compactMap { entry in
            guard var game = entry.offline ? GameCatalog.offlineGame(for: entry.install) : read.game(for: entry.install) else { return nil }
            game.install = entry.install
            game.locationID = entry.location
            return game
        }
    }

    /// One game, read as `games` reads it. On another drive and not read
    /// there yet (see `readsOtherDrives`): as if not installed.
    public func game(for install: ProductInstall) -> Game {
        var game = GameReader(self).game(for: install) ?? GameCatalog.offlineGame(for: install)
        game.install = install
        game.isOffline = false
        return game
    }

    /// Battle.net's own records of its games: the Agent's database, then the
    /// folders of the built-in locations. Reads only those.
    public func battleNetInstalls() -> [ProductInstall] {
        var installs = (try? ProductDB.loadAgentDatabase(at: agentDatabase)) ?? []
        for root in searchRoots {
            if let data = try? Data(contentsOf: root.appendingPathComponent(".product.db")),
               let found = try? ProductDB.parseFolderInstalls(data) {
                installs += found
            }
        }
        return installs
    }

    /// Reads each game's files once (`GameCatalog.game`); on another drive,
    /// only with `readsOtherDrives`.
    private final class GameReader {
        let library: GameLibrary
        /// Whether what is at a path is on another drive, and not read.
        let isOnOtherDrive: (String) -> Bool
        var read: [String: Game?] = [:]
        private(set) var skipped = false
        private(set) var unread: Set<String> = []
        /// What was read on other drives, found or not (`readsOtherDrives`).
        private(set) var otherDrives: [String: Game?] = [:]

        init(_ library: GameLibrary) {
            self.library = library
            isOnOtherDrive = library.otherDrives(library.fileManager)
        }

        /// Whether what is at a path is on another drive, and not read.
        func isSkipped(_ path: String) -> Bool {
            !library.readsOtherDrives && isOnOtherDrive(path)
        }

        /// Whether Waypoint's record of `install` is of a folder that is
        /// there (on another drive, as last read).
        func hasFolder(_ install: ProductInstall) -> Bool {
            if isSkipped(install.installPath) { return game(for: install) != nil }
            let exists = library.fileManager.fileExists(atPath: install.installPath)
            if !exists, library.readsOtherDrives, isOnOtherDrive(install.installPath) {
                let key = GameLibrary.factsKey(install)
                if otherDrives[key] == nil { otherDrives[key] = .some(nil) }
            }
            return exists
        }

        /// Nil: on another drive, and not read there yet.
        func game(for install: ProductInstall) -> Game? {
            let key = GameLibrary.factsKey(install)
            if let game = read[key] { return game }
            let game: Game?
            if isSkipped(install.installPath) {
                skipped = true
                if let known = library.otherDriveGames[key] { game = known } else {
                    game = nil
                    unread.insert(install.uid)
                }
            } else {
                game = GameCatalog.game(for: install, fileManager: library.fileManager)
                if library.readsOtherDrives, isOnOtherDrive(install.installPath) { otherDrives[key] = game }
            }
            read[key] = game
            return game
        }
    }

    /// Each install found, with the remembered location it is listed from
    /// (or, offline, the one whose drive it is on).
    private func entries(_ read: GameReader? = nil) -> [(install: ProductInstall, location: String?, offline: Bool)] {
        let read = read ?? GameReader(self)
        var byUID: [String: ProductInstall] = [:]
        var order: [String] = []
        var locations: [String: String] = [:]
        let offline = located.offline
        // Only what was found there when its drive was last connected is
        // kept as offline: not a game deleted meanwhile, nor one removed
        // from the library there.
        func offlineLocation(_ install: ProductInstall) -> String? {
            offline.first { $0.contains(install.installPath) && $0.listedInstalls.contains { $0.key == install.key } }?.id
        }
        // A game on a drive that isn't connected isn't looked for there.
        func isOnDisk(_ install: ProductInstall) -> Bool {
            offlineLocation(install) == nil && read.game(for: install)?.isInstalled == true
        }
        // Removed from the library where it is: whatever else has a record
        // of it there (Battle.net's, Waypoint's) doesn't list it again, nor
        // does Battle.net installing it there again. Waypoint installing it
        // there, or locating the folder, lists it again.
        func isRemoved(_ install: ProductInstall) -> Bool {
            located.locations.contains { $0.removedKeys.contains(install.key) && $0.contains(install.installPath) }
        }
        func add(_ install: ProductInstall, location: String? = nil) {
            guard !isRemoved(install) else { return }
            guard let earlier = byUID[install.key] else {
                order.append(install.key)
                byUID[install.key] = install
                locations[install.key] = location
                return
            }
            // Later sources only fill gaps; the Agent database is authoritative,
            // unless its copy's files are gone (uninstalled in Waypoint, or
            // moved to the Trash) and this one's are there.
            if !isOnDisk(earlier), isOnDisk(install) {
                byUID[install.key] = install
                locations[install.key] = location
            }
        }

        battleNetInstalls().forEach { add($0) }
        // Games Waypoint installed, as long as their folder is still there
        // (or on a remembered drive that isn't connected; on another drive,
        // as last read there).
        for install in stateStore.standaloneInstalls()
        where offlineLocation(install) != nil || read.hasFolder(install) {
            add(install)
        }
        // Located folders come last: a backup copy found there never
        // replaces the real install, nor a richer record of the same folder.
        for location in located.connected {
            for install in location.listedInstalls { add(install, location: location.id) }
        }
        // A drive that isn't connected: its games stay listed as they were
        // last found, unless a copy elsewhere is on disk.
        for location in offline {
            for install in location.listedInstalls {
                if let earlier = byUID[install.key] {
                    // A richer record of the same folder (Battle.net's) stays.
                    if isOnDisk(earlier) || offlineLocation(earlier) != nil { continue }
                } else {
                    order.append(install.key)
                }
                byUID[install.key] = install
                locations[install.key] = location.id
            }
        }
        // A remembered folder's game found through another record of it
        // (Battle.net's, or Waypoint's of installing it there) is listed
        // from that folder too, so it can be removed from the library.
        func connectedLocation(_ install: ProductInstall) -> String? {
            located.connected.first { $0.contains(install.installPath) && $0.listedInstalls.contains { $0.key == install.key } }?.id
        }
        return order.compactMap { key in
            guard let install = byUID[key] else { return nil }
            let offlineID = offlineLocation(install)
            return (stateStore.apply(to: install), locations[key] ?? offlineID ?? connectedLocation(install), offlineID != nil)
        }
    }
}

public enum Rosetta {
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }
}
