import Foundation

public enum GameInstallPlan: Sendable {
    /// Loose files only (Hearthstone): the updater against an empty folder.
    case loose(UpdatePlan)
    /// Local CASC storage plus loose files (everything else).
    case casc(CASCInstallPlan)

    public var downloadSize: UInt64 {
        switch self {
        case .loose(let plan): plan.downloadSize
        case .casc(let plan): plan.downloadSize
        }
    }

    public var version: String {
        switch self {
        case .loose(let plan): plan.target.name
        case .casc(let plan): plan.target.name
        }
    }
}

/// Installs any game in the catalog from scratch, following its product
/// config: Hearthstone as loose files, the rest into local CASC storage.
public struct GameInstaller: Sendable {
    public var product: InstallableProduct
    public var folder: URL
    public var region: Region
    public var language: String
    public var versions: VersionService
    public var store: InstallStateStore

    public init(product: InstallableProduct, folder: URL, region: Region, language: String,
                versions: VersionService = VersionService(), store: InstallStateStore = InstallStateStore()) {
        self.product = product
        self.folder = folder
        self.region = region
        self.language = language
        self.versions = versions
        self.store = store
    }

    /// `only` limits a loose-file install to some paths (tests, partial installs).
    public func plan(only: (@Sendable (String) -> Bool)? = nil, log: @Sendable (String) -> Void = { _ in }) async throws -> GameInstallPlan {
        let target = try await versions.latest(product: product.productCode, region: region)
        let config = try await versions.productConfig(product: product.productCode, region: region, version: target)
        let install = product.install(at: folder, region: region, language: language,
                                      tagString: config.tagString(region: region, language: language))
        Log.info(.install, "plan_started", nil, ["uid": product.uid, "version": target.name, "path": folder.path,
                                                 "containerless": config.isContainerless, "data_dir": config.dataDirectory,
                                                 "subfolder": config.subfolder, "tags": install.tagString ?? ""])
        if config.isContainerless {
            return .loose(try await GameUpdater(install: install, versions: versions, store: store)
                .plan(target: target, only: only, log: log))
        }
        return .casc(try await CASCInstaller(product: product, install: install, config: config, versions: versions, store: store)
            .plan(target: target, log: log))
    }

    public func apply(_ plan: GameInstallPlan, progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch plan {
        case .loose(let p):
            try await GameUpdater(install: p.install, versions: versions, store: store).apply(p, progress: progress)
        case .casc(let p):
            try await CASCInstaller(product: p.product, install: p.install, config: p.config, versions: versions, store: store)
                .apply(p, progress: progress)
        }
    }
}

public enum GameUpdatePlan: Sendable {
    /// Loose files only (Hearthstone).
    case loose(UpdatePlan)
    /// New files appended to local CASC storage, plus changed loose files.
    case casc(CASCInstallPlan)

    public var target: ProductVersion {
        switch self {
        case .loose(let plan): plan.target
        case .casc(let plan): plan.target
        }
    }

    public var downloadSize: UInt64 {
        switch self {
        case .loose(let plan): plan.downloadSize
        case .casc(let plan): plan.downloadSize
        }
    }

    /// Files to download (storage blobs plus loose files) and loose files to delete.
    public var fileCount: Int {
        switch self {
        case .loose(let plan): plan.files.count
        case .casc(let plan): plan.storage.count + plan.loose.files.count
        }
    }

    public var deletions: [String] {
        switch self {
        case .loose(let plan): plan.deletions
        case .casc(let plan): plan.loose.deletions
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .loose(let plan): plan.isEmpty
        case .casc(let plan): plan.isEmpty
        }
    }
}

/// Updates any game Waypoint knows: Hearthstone's loose files through
/// `GameUpdater`, everything else by adding the new build's files to its
/// local CASC storage. Works on installs Battle.net made too.
public struct GameUpdate: Sendable {
    public var install: ProductInstall
    public var versions: VersionService
    public var store: InstallStateStore

    public init(install: ProductInstall, versions: VersionService = VersionService(), store: InstallStateStore = InstallStateStore()) {
        self.install = install
        self.versions = versions
        self.store = store
    }

    public static func canUpdate(_ install: ProductInstall) -> Bool {
        GameCatalog.family(for: install.productCode) == .hearthstone || InstallableProduct.forProduct(install.productCode) != nil
    }

    var region: Region { install.region.flatMap(Region.init(rawValue:)) ?? .us }

    public func check() async throws -> UpdateCheck {
        try await GameUpdater(install: install, versions: versions, store: store).check()
    }

    /// With `verify`, loose files are hashed rather than trusted.
    public func plan(target requested: ProductVersion? = nil, verify: Bool = false,
                     log: @Sendable (String) -> Void = { _ in }) async throws -> GameUpdatePlan {
        let loose = GameUpdater(install: install, versions: versions, store: store)
        if GameCatalog.family(for: install.productCode) == .hearthstone {
            return .loose(try await loose.plan(target: requested, verify: verify, log: log))
        }
        guard let product = InstallableProduct.forProduct(install.productCode) else { throw UpdateError.unsupported(install.productCode) }
        let target: ProductVersion
        if let requested { target = requested } else { target = try await versions.latest(product: install.productCode, region: region) }
        let config = try await versions.productConfig(product: install.productCode, region: region, version: target)
        if config.isContainerless { return .loose(try await loose.plan(target: target, verify: verify, log: log)) }
        return .casc(try await CASCInstaller(product: product, install: install, config: config, versions: versions, store: store)
            .plan(target: target, verify: verify, log: log))
    }

    public func apply(_ plan: GameUpdatePlan, progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        switch plan {
        case .loose(let p):
            try await GameUpdater(install: install, versions: versions, store: store).apply(p, progress: progress)
        case .casc(let p):
            try await CASCInstaller(product: p.product, install: p.install, config: p.config, versions: versions, store: store)
                .apply(p, progress: progress)
        }
    }
}
