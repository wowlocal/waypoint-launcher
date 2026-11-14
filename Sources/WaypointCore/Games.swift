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

    public enum Architecture: String, Sendable {
        case arm64, x86_64
    }

    public var runsNatively: Bool { architectures.contains(.arm64) }

    /// Whether the library lists it: it's on disk, or on a remembered drive
    /// that isn't connected. Either way it isn't offered for download again.
    public var isListed: Bool { isInstalled || isOffline }

    public var isInstalled: Bool {
        if install.platform == .windows {
            guard let title = WindowsTitle.forInstall(install) else { return false }
            return FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: install.installPath).appendingPathComponent(title.executablePath).path)
        }
        return appURL != nil
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
            return Game(install: install, family: .other, displayName: name, appURL: nil, architectures: [.x86_64])
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

    static func displayName(for install: ProductInstall) -> String {
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
        entries().map { entry in
            var game = entry.offline ? GameCatalog.offlineGame(for: entry.install)
                : GameCatalog.game(for: entry.install, fileManager: fileManager)
            game.locationID = entry.location
            return game
        }
    }

    /// Each install found, with the remembered location it is listed from
    /// (or, offline, the one whose drive it is on).
    private func entries() -> [(install: ProductInstall, location: String?, offline: Bool)] {
        var byUID: [String: ProductInstall] = [:]
        var order: [String] = []
        var locations: [String: String] = [:]
        let offline = located.offline
        // What was removed from the library there isn't kept as offline.
        func offlineLocation(_ install: ProductInstall) -> String? {
            offline.first { $0.contains(install.installPath) && !$0.removedKeys.contains(install.key) }?.id
        }
        // A game on a drive that isn't connected isn't looked for there.
        func isOnDisk(_ install: ProductInstall) -> Bool {
            offlineLocation(install) == nil && GameCatalog.game(for: install, fileManager: fileManager).isInstalled
        }
        func add(_ install: ProductInstall, location: String? = nil) {
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

        if let installs = try? ProductDB.loadAgentDatabase(at: agentDatabase) {
            installs.forEach { add($0) }
        }
        for root in searchRoots {
            let file = root.appendingPathComponent(".product.db")
            if let data = try? Data(contentsOf: file),
               let installs = try? ProductDB.parseFolderInstalls(data) {
                installs.forEach { add($0) }
            }
        }
        // Games Waypoint installed, as long as their folder is still there
        // (or on a remembered drive that isn't connected).
        for install in stateStore.standaloneInstalls()
        where offlineLocation(install) != nil || fileManager.fileExists(atPath: install.installPath) {
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
        return order.compactMap { key in
            guard let install = byUID[key] else { return nil }
            let offlineID = offlineLocation(install)
            return (stateStore.apply(to: install), locations[key] ?? offlineID, offlineID != nil)
        }
    }
}

public enum Rosetta {
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }
}
