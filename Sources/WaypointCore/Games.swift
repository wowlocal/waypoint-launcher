import Foundation

public enum GameFamily: String, Sendable {
    case hearthstone
    case worldOfWarcraft
    case other
}

/// A launchable game on disk.
public struct Game: Identifiable, Equatable, Sendable {
    public var id: String { install.uid }
    public var install: ProductInstall
    public var family: GameFamily
    public var displayName: String
    /// The `.app` bundle to run, if we could find it.
    public var appURL: URL?
    public var architectures: Set<Architecture>

    public enum Architecture: String, Sendable {
        case arm64, x86_64
    }

    public var runsNatively: Bool { architectures.contains(.arm64) }

    /// Whether Waypoint knows how to log this game in without Battle.net.
    public var isSupported: Bool {
        family != .other && appURL != nil && runsNatively
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
        let family = family(for: install.productCode)
        let root = URL(fileURLWithPath: install.installPath, isDirectory: true)
        let appURL: URL?
        let name: String

        switch family {
        case .hearthstone:
            appURL = existing(root.appendingPathComponent("Hearthstone.app"), fileManager)
            name = install.productCode == "hsb" ? "Hearthstone" : "Hearthstone (\(install.productCode))"
        case .worldOfWarcraft:
            let folder = wowFlavorFolders[install.productCode] ?? "_\(install.productCode)_"
            appURL = firstApp(in: root.appendingPathComponent(folder), prefix: "World of Warcraft", fileManager)
            name = wowFlavorNames[install.productCode] ?? install.productCode
        case .other:
            appURL = ["", "_retail_", "_retail_/arm64", "_retail_/x86_64"].lazy
                .compactMap { firstApp(in: root.appendingPathComponent($0), prefix: nil, fileManager) }
                .first
            name = otherNames[install.productCode] ?? install.productCode
        }

        return Game(
            install: install,
            family: family,
            displayName: name,
            appURL: appURL,
            architectures: appURL.map(architectures(of:)) ?? []
        )
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

/// Finds installed games from every source we know about.
public struct GameLibrary {
    public var agentDatabase: URL
    /// Folders to scan for a `.product.db`, so games keep working after the
    /// Battle.net app is removed.
    public var searchRoots: [URL]
    public var fileManager: FileManager

    public static let defaultSearchRoots: [URL] = [
        "/Applications/Hearthstone",
        "/Applications/World of Warcraft",
        "/Applications/Warcraft III",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    public init(agentDatabase: URL = ProductDB.agentDatabaseURL,
                searchRoots: [URL] = GameLibrary.defaultSearchRoots,
                fileManager: FileManager = .default) {
        self.agentDatabase = agentDatabase
        self.searchRoots = searchRoots
        self.fileManager = fileManager
    }

    public func installs() -> [ProductInstall] {
        var byUID: [String: ProductInstall] = [:]
        var order: [String] = []
        func add(_ install: ProductInstall) {
            if byUID[install.uid] == nil { order.append(install.uid) }
            // Later sources only fill gaps; the Agent database is authoritative.
            byUID[install.uid] = byUID[install.uid] ?? install
        }

        if let installs = try? ProductDB.loadAgentDatabase(at: agentDatabase) {
            installs.forEach(add)
        }
        for root in searchRoots {
            let file = root.appendingPathComponent(".product.db")
            if let data = try? Data(contentsOf: file),
               let install = try? ProductDB.parseInstallFile(data) {
                add(install)
            }
        }
        return order.compactMap { byUID[$0] }
    }

    public func games() -> [Game] {
        installs().map { GameCatalog.game(for: $0, fileManager: fileManager) }
    }
}
