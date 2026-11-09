import Foundation

/// The durable intent of a job. Plans, closures and network tasks are rebuilt
/// from this after a restart; verified staged files remain the source of truth.
public struct DownloadRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case install, update, languages }

    public var kind: Kind
    public var install: ProductInstall
    /// Snapshot for installs, including products missing from the offline catalog.
    public var product: InstallableProduct?
    public var target: ProductVersion?
    public var languages: GameLanguages?
    public var verify: Bool
    public var key: String { install.key }
    public var category: Diagnostics.Category { kind == .install ? .install : .gameUpdate }

    public init(kind: Kind, install: ProductInstall, product: InstallableProduct? = nil,
                target: ProductVersion? = nil, languages: GameLanguages? = nil, verify: Bool = false) {
        self.kind = kind
        self.install = install
        self.product = product
        self.target = target
        self.languages = languages
        self.verify = verify
    }

    public func perform(progress: @escaping DownloadJob.Progress) async throws {
        try BattleNet.ensureNotRunning()
        switch kind {
        case .install:
            guard let product, product.uid == install.uid, product.productCode == install.productCode,
                  let region = install.region.flatMap(Region.init(rawValue:)) else {
                throw TACTError.malformed("unfinished install request")
            }
            try await ProductCatalog.shared.validateDownload(product, region: region, platform: install.platform)
            let installer = GameInstaller(product: product, folder: URL(fileURLWithPath: install.installPath),
                                          region: region, languages: install.languages, platform: install.platform)
            let plan = try await installer.plan()
            try await installer.apply(plan, progress: progress)
            Log.notice(.install, "finished", nil, ["uid": install.uid, "version": plan.version, "path": install.installPath])
        case .update, .languages:
            let updater = GameUpdate(install: install)
            let plan = try await updater.plan(target: target, verify: verify, languages: languages)
            if kind == .languages || !plan.isEmpty || plan.target.buildConfig != install.buildConfig {
                try await updater.apply(plan, progress: progress)
            } else {
                // Up to date and nothing to download: still give the game the
                // index-file room an older Waypoint may have left out, which
                // is what makes "Verify Files" fix such an install (issue #3).
                try updater.repairIndexes(plan)
            }
        }
    }
}

public struct UnfinishedDownload: Codable, Sendable, Equatable {
    public var formatVersion = 1
    public var request: DownloadRequest
    public var progress: UpdateProgress?
    public var keepsMacAwake: Bool
    public var failure: String?

    public init(request: DownloadRequest, progress: UpdateProgress? = nil, keepsMacAwake: Bool = false, failure: String? = nil) {
        self.request = request
        self.progress = progress
        self.keepsMacAwake = keepsMacAwake
        self.failure = failure
    }
}
