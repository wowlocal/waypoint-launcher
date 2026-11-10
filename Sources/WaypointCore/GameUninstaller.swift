import Foundation

/// What uninstalling a game takes away. See `GameUninstaller`.
public struct UninstallPlan: Sendable, Equatable {
    /// The install folder.
    public var root: URL
    /// The whole folder goes to the Trash.
    public var removesFolder: Bool
    /// Otherwise, what goes, relative to `root`. It's gathered into one
    /// folder named after the game, and that goes to the Trash.
    public var items: [String]
    /// WoW add-ons, settings and screenshots in the version's folder,
    /// relative to `root`, whether or not they stay.
    public var userFiles: [String]
    /// Waypoint's Windows environment for a Windows game: its Wine prefix,
    /// which holds the game's saved games and settings (`Documents`,
    /// `Saved Games`), as Windows keeps them outside the game folder.
    public var windowsHome: URL?
    /// `userFiles` and `windowsHome` stay where they are.
    public var keepsUserFiles: Bool
    /// Other products share the folder and its storage: only this product's
    /// `.build.info` row goes, and the storage is cleaned afterwards.
    public var sharesStorage: Bool

    /// The user's own files: WoW add-ons, or a Windows game's saves.
    public var hasUserFiles: Bool { !userFiles.isEmpty || windowsHome != nil }

    /// What goes to the Trash.
    public var trashed: [URL] {
        (removesFolder ? [root] : items.map { root.appendingPathComponent($0) })
            + (keepsUserFiles ? [] : [windowsHome].compactMap { $0 })
    }
}

public enum UninstallError: Error, LocalizedError, Equatable {
    case folderMissing(String)
    /// The game, or (with `sharedFolder`) another game in its folder, is running.
    case gameRunning(sharedFolder: String?)
    case holdsOtherGames(String)
    case sharedFolder(String)
    case protectedFolder(String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let path): "The game’s folder is gone: \(path)"
        case .gameRunning(nil): "Quit the game before uninstalling it"
        case .gameRunning(let folder?): "Quit every game in “\(folder)” first: they share its files"
        case .holdsOtherGames(let path): "Other games are installed inside “\(path)”, so Waypoint won’t move it to the Trash"
        case .sharedFolder(let path): "Other games share “\(path)” in a way Waypoint doesn’t know. Uninstall this one in Battle.net"
        case .protectedFolder(let path): "The game is installed right in “\(path)”, so Waypoint won’t move that folder to the Trash"
        }
    }
}

/// Uninstalls a game as Battle.net does, except that its files go to the
/// Trash rather than being deleted, so a mistake can be undone.
///
/// A game alone in its folder goes to the Trash with the folder. WoW
/// versions share one folder and one local storage (`Data`): a version's
/// own folder (`_classic_era_`) goes, its `.build.info` row is dropped, and
/// `cleanSharedStorage` then deletes what no other version uses. That part
/// can't go to the Trash: it's inside archives the others use too.
///
/// A WoW version's add-ons, settings and screenshots (`Interface`, `WTF`,
/// `Fonts`, `Screenshots`) can stay where they are, as Battle.net leaves
/// them, and a reinstall into the same folder picks them up. Other
/// versions' folders are never touched, even ones left from an earlier
/// uninstall: their add-ons are in there. A Windows game's saved games and
/// settings live in Waypoint's Wine prefix for it; that stays too, or goes
/// to the Trash.
public struct GameUninstaller: Sendable {
    public var install: ProductInstall
    /// Names the folder that goes to the Trash when the install folder stays.
    public var displayName: String
    public var keepsUserFiles: Bool
    /// The other games installed. A folder holding one of them never goes whole.
    public var otherInstalls: [ProductInstall]
    public var store: InstallStateStore
    public var versions: VersionService
    var windowsSupport = WindowsRuntime.support
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Folders a WoW version keeps the user's own files in.
    static let userFolderNames: Set<String> = ["interface", "wtf", "fonts", "screenshots"]

    public init(install: ProductInstall, displayName: String, keepsUserFiles: Bool, otherInstalls: [ProductInstall],
                store: InstallStateStore = InstallStateStore(), versions: VersionService = VersionService()) {
        self.install = install
        self.displayName = displayName
        self.keepsUserFiles = keepsUserFiles
        self.otherInstalls = otherInstalls
        self.store = store
        self.versions = versions
    }

    var root: URL { URL(fileURLWithPath: install.installPath, isDirectory: true).standardizedFileURL }
    var isWoW: Bool { GameCatalog.family(for: install.productCode) == .worldOfWarcraft }

    /// The folder inside `root` that holds this product's own files, when
    /// the product has one (`_retail_`, `_classic_era_`).
    var flavorFolder: String? {
        if isWoW { return GameCatalog.wowFolder(for: install.productCode) }
        return InstallableProduct.forProduct(install.productCode)?.flavorFolder
    }

    // MARK: Plan

    public func plan() throws -> UninstallPlan {
        let fm = FileManager.default
        let root = root
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UninstallError.folderMissing(root.path)
        }
        let resolved = root.resolvingSymlinksInPath().path
        let others = otherInstalls.filter { $0.key != install.key }.map {
            URL(fileURLWithPath: $0.installPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard !others.contains(where: { $0.hasPrefix(resolved + "/") }) else { throw UninstallError.holdsOtherGames(root.path) }
        let mine: Set = [install.productCode, install.uid]
        let sharesStorage = others.contains(resolved) ||
            Self.buildInfoProducts(in: root).contains { !mine.contains($0) && Self.isPresent($0, in: root) }

        let flavor = flavorFolder
        var userFiles: [String] = []
        if isWoW, let flavor {
            userFiles = Self.names(in: root.appendingPathComponent(flavor, isDirectory: true))
                .filter { Self.userFolderNames.contains($0.lowercased()) }.map { "\(flavor)/\($0)" }
        }
        let home = windowsHome
        let keeps = keepsUserFiles && (!userFiles.isEmpty || home != nil)
        let keepsAddOns = keeps && !userFiles.isEmpty
        var plan = UninstallPlan(root: root, removesFolder: false, items: [], userFiles: userFiles, windowsHome: home,
                                 keepsUserFiles: keeps, sharesStorage: sharesStorage)
        // The version's own folder: all of it, or all but the user's files.
        func flavorItems() -> [String] {
            guard let flavor, fm.fileExists(atPath: root.appendingPathComponent(flavor).path) else { return [] }
            guard keepsAddOns else { return [flavor] }
            return Self.names(in: root.appendingPathComponent(flavor, isDirectory: true)).map { "\(flavor)/\($0)" }
                .filter { !userFiles.contains($0) }
        }

        if sharesStorage {
            guard flavor != nil else { throw UninstallError.sharedFolder(root.path) }
            plan.items = flavorItems()
            return plan
        }
        guard !Self.isProtected(root) else { throw UninstallError.protectedFolder(root.path) }
        let otherFlavors = isWoW ? Self.names(in: root).filter { $0 != flavor && Self.isFlavorFolder($0, in: root) } : []
        if keepsAddOns || !otherFlavors.isEmpty {
            plan.items = Self.names(in: root).filter { $0 != flavor && !otherFlavors.contains($0) } + flavorItems()
        } else {
            plan.removesFolder = true
        }
        return plan
    }

    /// Waypoint's Windows environment for a Windows game, unless another
    /// install of the same game still uses it.
    var windowsHome: URL? {
        guard let title = WindowsTitle.forInstall(install),
              !otherInstalls.contains(where: { $0.installPath != install.installPath && WindowsTitle.forInstall($0) == title })
        else { return nil }
        let home = windowsSupport.appendingPathComponent("Windows/\(title.prefixFolder)", isDirectory: true)
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    // MARK: Remove

    /// Plans afresh, then moves the game to the Trash and forgets it. If
    /// moving fails, everything is put back as it was.
    @discardableResult
    public func remove() async throws -> UninstallPlan {
        // Not while Battle.net's records are being repaired: a repair that
        // had already listed this game would write its records again.
        try BattleNetInstallMetadata.exclusively {
            let plan = try plan()
            guard RunningProcesses.inside(plan.root).isEmpty else {
                throw UninstallError.gameRunning(sharedFolder: plan.sharesStorage ? plan.root.lastPathComponent : nil)
            }
            try BattleNet.ensureNotRunning()
            try carryOut(plan)
            return plan
        }
    }

    func carryOut(_ plan: UninstallPlan) throws {
        let started = Date()
        if plan.removesFolder {
            try trash(plan.root)
        } else {
            try trashItems(plan)
        }
        do {
            try store.remove(install)
        } catch {
            Log.warning(.install, "uninstall_record_kept", nil, ["uid": install.key, "error": error])
        }
        if let home = plan.windowsHome, !plan.keepsUserFiles { trashWindowsHome(home) }
        Log.notice(.install, "uninstalled", nil, ["uid": install.key, "path": plan.root.path, "whole_folder": plan.removesFolder,
                                                  "items": plan.items.count, "kept": plan.keepsUserFiles ? plan.userFiles.count : 0,
                                                  "shared_storage": plan.sharesStorage,
                                                  "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
    }

    /// Gathers the items into one folder in `root`, named after the game, and
    /// moves that to the Trash. The app goes last, so a failure before it
    /// leaves a game that still runs; a failure undoes every move.
    private func trashItems(_ plan: UninstallPlan) throws {
        let fm = FileManager.default
        let buildInfo = plan.root.appendingPathComponent(".build.info")
        guard !plan.items.isEmpty else {
            if plan.sharesStorage { _ = try Self.dropBuildInfoRows(buildInfo, products: [install.productCode, install.uid]) }
            return
        }
        let bin = Self.unusedURL(in: plan.root, named: displayName)
        try fm.createDirectory(at: bin, withIntermediateDirectories: false)
        var moved: [(from: URL, to: URL)] = []
        var originalBuildInfo: Data?
        do {
            for item in plan.items.filter({ !$0.hasSuffix(".app") }) + plan.items.filter({ $0.hasSuffix(".app") }) {
                let from = plan.root.appendingPathComponent(item), to = bin.appendingPathComponent(item)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            }
            if plan.sharesStorage {
                originalBuildInfo = try Self.dropBuildInfoRows(buildInfo, products: [install.productCode, install.uid])
            }
            try trash(bin)
        } catch {
            if let originalBuildInfo { try? originalBuildInfo.write(to: buildInfo, options: .atomic) }
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            Self.removeEmptyFolders(bin)
            Log.warning(.install, "uninstall_undone", nil, ["uid": install.key, "moved": moved.count, "error": error])
            throw error
        }
    }

    /// Moves the game's Windows environment (its Wine prefix, with its
    /// saves) to the Trash, named for it there rather than `pro` or `osi`.
    /// Holds the game's launch lock meanwhile; another Windows game may run.
    /// The game is gone by now, so a failure only leaves the saves in place.
    private func trashWindowsHome(_ home: URL) {
        let fm = FileManager.default
        do {
            let lease = try PrefixLease(file: home.appendingPathComponent("launch.lock"))
            defer { lease.release() }
            let named = Self.unusedURL(in: home.deletingLastPathComponent(), named: "\(displayName) saved games and settings")
            try fm.moveItem(at: home, to: named)
            do {
                try trash(named)
            } catch {
                try? fm.moveItem(at: named, to: home)
                throw error
            }
        } catch {
            Log.warning(.install, "windows_home_kept", nil, ["uid": install.key, "path": home.path, "error": error])
        }
    }

    // MARK: Shared storage

    /// After a WoW version left a shared folder, deletes what only it used
    /// from the storage and gives the space back. Reads the remaining
    /// versions' build configs and encoding tables, so it needs the network;
    /// if it fails, the next update of one of them does it.
    public func cleanSharedStorage() async throws -> CASCStorageCleaner.Result {
        // The versions still installed first: the one that's gone may no longer be served.
        let candidates = Self.buildInfoProducts(in: root) + [install.productCode]
        guard let product = candidates.lazy.compactMap(InstallableProduct.forProduct).first else {
            throw UpdateError.unsupported(install.productCode)
        }
        let region = install.region.flatMap(Region.init(rawValue:)) ?? .us
        let owner = ProductInstall(uid: product.uid, productCode: product.productCode, installPath: install.installPath,
                                   region: install.region, platform: install.platform)
        let config = try await versions.productConfig(product: product.productCode, region: region, platform: install.platform)
        return try await CASCInstaller(product: product, install: owner, config: config, versions: versions, store: store).cleanStorage()
    }

    // MARK: Pieces

    /// What `.build.info` lists as installed in `root`.
    static func buildInfoProducts(in root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8) else { return [] }
        return BPSV(text).rows.compactMap { $0["Product"]?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether a product `.build.info` lists is on disk: a WoW version
    /// whose app is there, or another product whose folder says it holds
    /// it (`_ptr_/.flavor.info`). Anything else is a row left behind.
    static func isPresent(_ product: String, in root: URL) -> Bool {
        if GameCatalog.family(for: product) == .worldOfWarcraft {
            return GameCatalog.game(for: ProductInstall(uid: product, productCode: product, installPath: root.path)).appURL != nil
        }
        return names(in: root).contains { name in
            guard isFlavorFolder(name, in: root),
                  let text = try? String(contentsOf: root.appendingPathComponent("\(name)/.flavor.info"), encoding: .utf8)
            else { return false }
            return BPSV(text).rows.contains { $0["Product Flavor"]?.trimmingCharacters(in: .whitespaces) == product }
        }
    }

    /// Rewrites `.build.info` without the products' rows, keeping every
    /// other line as it was. Returns what was there, to undo it.
    static func dropBuildInfoRows(_ url: URL, products: Set<String>) throws -> Data {
        let original = try Data(contentsOf: url)
        let lines = String(decoding: original, as: UTF8.self).components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return original }
        guard let column = lines[header].split(separator: "|", omittingEmptySubsequences: false)
            .firstIndex(where: { $0.split(separator: "!").first == "Product" })
        else { throw TACTError.malformed(".build.info without a Product column") }
        let kept = lines.enumerated().filter { index, line in
            guard index > header, !line.hasPrefix("#") else { return true }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            return column >= cells.count || !products.contains(cells[column].trimmingCharacters(in: .whitespacesAndNewlines))
        }.map(\.element)
        try Data(kept.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        return original
    }

    /// Folders a game must never be uninstalled from whole: the system's,
    /// the home folder and its standard folders, and volumes.
    static func isProtected(_ folder: URL) -> Bool {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let standard = ["Applications", "Desktop", "Documents", "Downloads", "Games", "Library", "Movies", "Music", "Pictures", "Public"]
        let protected = Set(["/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes", "/private", home]
            + standard.map { "\(home)/\($0)" })
        if protected.contains(path) || path.split(separator: "/").count < 2 { return true }
        return (try? folder.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// `_retail_`, `_classic_era_`: a WoW version's folder.
    static func isFlavorFolder(_ name: String, in root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return name.count > 2 && name.hasPrefix("_") && name.hasSuffix("_") &&
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// `name` in `parent`, or `name 2`, `name 3`… if taken.
    static func unusedURL(in parent: URL, named name: String) -> URL {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while (try? FileManager.default.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = parent.appendingPathComponent("\(base) \(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    /// Removes `folder` and the folders in it, as long as they hold no files.
    static func removeEmptyFolders(_ folder: URL) {
        let inside = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in inside.sorted(by: { $0.path.count > $1.path.count }) + [folder] { rmdir(url.path) }
    }

    /// Disk space the items take (allocated, so a storage's freed holes
    /// don't count).
    public static func allocatedSize(of items: [URL]) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        func size(_ url: URL) -> UInt64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return UInt64(values.totalFileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        for item in items {
            total += size(item)
            guard let files = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys)) else { continue }
            for case let file as URL in files {
                if Task.isCancelled { return total }
                total += size(file)
            }
        }
        return total
    }
}
