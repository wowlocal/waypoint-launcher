import CryptoKit
import Foundation

/// One encoded file to put into local storage. Compact (32 bytes): a fresh
/// WoW install plans about 1.6 million of them.
public struct StorageItem: Sendable {
    public var key: Key16
    private var size32: UInt32
    /// Where it sits on the CDN: an index into the plan's `archives` and the
    /// offset there, or -1 when it's a file of its own.
    public var archive: Int32 = -1
    public var offset: UInt32 = 0
    private var flags: UInt8 = 0

    public init(key: Key16, size: UInt64, fullKey: Bool, kind: CDNClient.Kind = .data, isRaw: Bool = false) {
        self.key = key
        size32 = UInt32(clamping: size)
        flags = (fullKey ? 1 : 0) | (isRaw ? 2 : 0) | (kind == .patch ? 4 : 0)
    }

    /// Encoded (BLTE) size; 0 when only the download tells. Local storage
    /// can't hold a file of 4 GB or more anyway.
    public var size: UInt64 {
        get { UInt64(size32) }
        set { size32 = UInt32(clamping: newValue) }
    }

    public var encodedKey: Data { key.data }
    /// Build-config files get their whole key in the entry header, like the Agent writes them.
    public var fullKey: Bool { flags & 1 != 0 }
    /// Stored as is rather than BLTE (the patch manifest); checked by size.
    public var isRaw: Bool { flags & 2 != 0 }
    /// Where on the CDN it lives when it isn't in an archive.
    public var kind: CDNClient.Kind { flags & 4 != 0 ? .patch : .data }
    public var isInArchive: Bool { archive >= 0 }
}

public struct CASCInstallPlan: Sendable {
    public var install: ProductInstall
    public var product: InstallableProduct
    public var config: ProductConfig
    public var target: ProductVersion
    public var cdn: CDNClient
    public var buildConfig: Data
    public var cdnConfig: Data
    public var archives: [String]
    /// Sorted for downloading: by archive and offset, then files of their own.
    public var storage: [StorageItem]
    /// Loose files from the install manifest, rooted at the flavor folder.
    public var loose: UpdatePlan

    public var downloadSize: UInt64 { storage.reduce(0) { $0 + $1.size } + loose.downloadSize }
    /// Nothing to download or delete (configs and records may still change).
    public var isEmpty: Bool { storage.isEmpty && loose.isEmpty }
}

/// Installs or updates a game that keeps its data in local CASC storage (WoW,
/// StarCraft, Diablo III, Warcraft III, Heroes): the same pieces the Agent
/// lays down. An update is the same plan against what's already there: files
/// the storage holds are skipped, new ones are appended, and loose files are
/// diffed like Hearthstone's.
///
///   <root>/<data dir>/data      local storage: every download-manifest file
///                               for the install's tags, plus build-config files
///   <root>/<data dir>/config    build and CDN configs
///   <root>/<data dir>/indices   CDN archive indexes
///   <root>/<flavor>/…           loose files from the install manifest (the .app)
///   <root>/.build.info          which build is installed, one row per product
///   <root>/<flavor>/.flavor.info  which product the flavor folder holds
public struct CASCInstaller: Sendable {
    public var product: InstallableProduct
    public var install: ProductInstall
    public var config: ProductConfig
    public var versions: VersionService
    public var store: InstallStateStore
    public var concurrency = 8
    /// Biggest single range request when merging neighbouring blobs.
    public var maxBatchBytes: UInt64 = 32 << 20
    /// Merge blobs separated by at most this much unneeded data.
    public var maxGapBytes: UInt64 = 256 << 10

    public init(product: InstallableProduct, install: ProductInstall, config: ProductConfig,
                versions: VersionService = VersionService(), store: InstallStateStore = InstallStateStore()) {
        self.product = product
        self.install = install
        self.config = config
        self.versions = versions
        self.store = store
    }

    var region: Region { install.region.flatMap(Region.init(rawValue:)) ?? .us }
    var root: URL { URL(fileURLWithPath: install.installPath, isDirectory: true) }
    var dataRoot: URL { root.appendingPathComponent(config.dataDirectory, isDirectory: true) }
    var looseRoot: URL { config.subfolder.isEmpty ? root : root.appendingPathComponent(config.subfolder, isDirectory: true) }

    // MARK: Plan

    /// With `verify`, loose files are hashed instead of trusting the installed
    /// build's manifest (a repair).
    public func plan(target requested: ProductVersion? = nil, verify: Bool = false,
                     log: @Sendable (String) -> Void = { _ in }) async throws -> CASCInstallPlan {
        let started = Date()
        let target: ProductVersion
        if let requested { target = requested } else { target = try await versions.latest(product: install.productCode, region: region) }
        let cdn = try await versions.cdn(product: install.productCode, region: region)
        let tags = install.tagString ?? config.tagString(region: region, language: install.textLanguage ?? "enUS")

        let buildConfigData = try await cdn.cached(.config, target.buildConfig)
        let cdnConfigData = try await cdn.cached(.config, target.cdnConfig)
        let buildConfig = TACTConfig(String(decoding: buildConfigData, as: UTF8.self))
        let cdnConfig = TACTConfig(String(decoding: cdnConfigData, as: UTF8.self))
        guard let installKey = buildConfig.encodedKey("install"), let downloadKey = buildConfig.encodedKey("download"),
              let encodingKey = buildConfig.encodedKey("encoding")
        else { throw TACTError.malformed("build config") }

        // Loose files, with Windows-style paths (Diablo III) normalized.
        let looseEntries = try InstallManifest(try await cdn.decoded(installKey))
            .select(tagString: tags)
            .map { entry -> InstallManifest.Entry in
                var e = entry
                e.path = e.path.replacingOccurrences(of: "\\", with: "/")
                return e
            }
        log("Build \(target.name): \(looseEntries.count) loose files")

        let rootKey = buildConfig["root"].first.flatMap { Data(hex: $0) }
        let encoding = try EncodingTable(try await cdn.decoded(encodingKey),
                                         wanted: Set(looseEntries.map(\.contentKey) + (rootKey.map { [$0] } ?? [])))

        // Every loose file's encoded key stays out of storage, changed or not.
        let looseKeys = Set(try looseEntries.map { entry -> Key16 in
            guard let encoded = encoding.entries[entry.contentKey], let key = Key16(encoded.encodedKey) else {
                throw TACTError.notFound("encoding entry for \(entry.path)")
            }
            return key
        })
        var looseInstall = install
        looseInstall.installPath = looseRoot.path
        let (changed, deletions) = try await looseChanges(looseEntries, target: target, cdn: cdn, tags: tags,
                                                          verify: verify, looseInstall: looseInstall, log: log)
        var looseFiles: [UpdatePlan.File] = changed.compactMap { entry in
            encoding.entries[entry.contentKey].map {
                UpdatePlan.File(path: entry.path, contentKey: entry.contentKey, encodedKey: $0.encodedKey, size: entry.size, location: nil)
            }
        }

        // Build-config files (encoding, install, download, patch index, VFS)
        // live in storage with full keys in their headers; root too, but with
        // the short key like bulk content. The size manifest isn't stored.
        var storage: [StorageItem] = []
        func isHash(_ s: String) -> Bool { s.count == 32 && s.allSatisfy(\.isHexDigit) }
        for (name, values) in buildConfig.values.sorted(by: { $0.key < $1.key })
        where name != "size" && values.count == 2 && isHash(values[0]) && isHash(values[1]) {
            guard let key = Data(hex: values[1]).flatMap(Key16.init) else { continue }
            let size = buildConfig["\(name)-size"].last.flatMap(UInt64.init) ?? 0
            storage.append(StorageItem(key: key, size: size, fullKey: true))
        }
        // The patch manifest: a raw file on the CDN's patch path, stored as is
        // with its full key (matched against an Agent-written storage).
        if let patch = buildConfig["patch"].first, buildConfig["patch"].count == 1, let key = Data(hex: patch).flatMap(Key16.init) {
            let size = buildConfig["patch-size"].first.flatMap(UInt64.init) ?? 0
            storage.append(StorageItem(key: key, size: size, fullKey: true, kind: .patch, isRaw: true))
        }
        if let rootKey, let rootEncoded = encoding.entries[rootKey].flatMap({ Key16($0.encodedKey) }) {
            storage.append(StorageItem(key: rootEncoded, size: 0, fullKey: false))
        }
        let special = Set(storage.map(\.key))

        // The download manifest's files for this install's tags, read in
        // place from the mapped manifest; on an update, minus what the
        // storage already holds.
        let download = try DownloadManifest(try await cdn.decoded(downloadKey))
        let selected = download.selectionMask(tagString: tags)
        let present = try StoredKeys.load(dataRoot.appendingPathComponent("data", isDirectory: true))
        // Sized once: growing an array of a million items copies it over and over.
        storage.reserveCapacity(storage.count + selected.reduce(0) { $0 + $1.nonzeroBitCount })
        var listed = 0
        for i in 0..<download.count where selected[i / 8] & (0x80 >> UInt8(i % 8)) != 0 {
            listed += 1
            let key = download.key(at: i)
            if looseKeys.contains(key) || special.contains(key) { continue }
            storage.append(StorageItem(key: key, size: download.size(at: i), fullKey: false))
        }
        log("\(listed) files for local storage")
        if let present {
            let total = storage.count
            storage.removeAll { present.contains($0.key) }
            log("\(total - storage.count) of \(total) storage files already there")
        }
        // By key, without duplicates: what locating needs.
        storage.sort { $0.key < $1.key }
        var unique = 0
        for i in storage.indices where unique == 0 || storage[unique - 1].key != storage[i].key {
            storage[unique] = storage[i]
            unique += 1
        }
        storage.removeLast(storage.count - unique)

        let archives = cdnConfig["archives"]
        log("Locating \(storage.count + looseFiles.count) files in \(archives.count) CDN archives")
        let indexFiles = try await ArchiveIndexes.fetch(archives, cdn: cdn, localDirectory: dataRoot.appendingPathComponent("indices"))
        try ArchiveIndexes.locate(&storage, indexFiles: indexFiles)
        let looseLocations = try ArchiveIndexes.locate(Set(looseFiles.compactMap { Key16($0.encodedKey) }), archives: archives, indexFiles: indexFiles)
        for i in looseFiles.indices { looseFiles[i].location = Key16(looseFiles[i].encodedKey).flatMap { looseLocations[$0] } }
        // Files outside archives: the CDN's file index knows their sizes.
        if let fileIndex = cdnConfig["file-index"].first, storage.contains(where: { !$0.isInArchive }),
           let file = try? await cdn.cachedFile(.data, fileIndex, suffix: ".index", localCopy: dataRoot.appendingPathComponent("indices/\(fileIndex).index")),
           let data = try? Data(contentsOf: file, options: .alwaysMapped) {
            try? ArchiveIndex.scan(data, archive: fileIndex) { key, keySize, size, _ in
                guard keySize >= 16 else { return false }
                if let i = ArchiveIndexes.index(of: Key16(key), in: storage), !storage[i].isInArchive { storage[i].size = size }
                return true
            }
        }
        // Download order: archive by archive, front to back; loose CDN files last.
        storage.sort { a, b in
            let x = a.archive < 0 ? Int32.max : a.archive, y = b.archive < 0 ? Int32.max : b.archive
            return x != y ? x < y : a.offset < b.offset
        }

        let loose = UpdatePlan(install: looseInstall, target: target, cdn: cdn, files: looseFiles, deletions: deletions)
        let plan = CASCInstallPlan(install: install, product: product, config: config, target: target, cdn: cdn,
                                   buildConfig: buildConfigData, cdnConfig: cdnConfigData, archives: archives,
                                   storage: storage, loose: loose)
        Log.info(.install, "casc_plan_ready", nil, [
            "uid": install.uid, "version": target.name, "storage_files": storage.count,
            "storage_bytes": plan.storage.reduce(UInt64(0)) { $0 + $1.size }, "loose_files": looseFiles.count,
            "loose_deletions": deletions.count, "update": present != nil, "from": install.version ?? "none",
            "unlocated": storage.reduce(0) { $0 + ($1.isInArchive ? 0 : 1) }, "archives": archives.count,
            "footprint_mb": ProcessMemory.footprintMB,
            "duration_ms": Int(Date().timeIntervalSince(started) * 1000),
        ])
        return plan
    }

    // MARK: Apply

    public func apply(_ plan: CASCInstallPlan, progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        let started = Date()
        let fm = FileManager.default
        guard RunningProcesses.inside(root).isEmpty else { throw UpdateError.gameRunning }
        try BattleNet.ensureNotRunning()
        let storageDir = dataRoot.appendingPathComponent("data", isDirectory: true)
        // An update (or another product joining a shared storage): afterwards,
        // drop what no installed build needs any more.
        let storageExisted = (try? CASC.scanStorage(storageDir)) != nil

        let total = plan.downloadSize
        let available = (try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).flatMap { $0 }.map { UInt64($0) } ?? .max
        guard available > total + (1 << 30) else { throw UpdateError.notEnoughSpace(needed: total, available: available) }
        Log.notice(.install, "casc_apply_started", nil, ["uid": install.uid, "bytes": total, "path": root.path])

        // Configs and CDN indexes, as the Agent keeps them.
        try write(plan.buildConfig, to: configURL(plan.target.buildConfig))
        try write(plan.cdnConfig, to: configURL(plan.target.cdnConfig))
        let indexDir = dataRoot.appendingPathComponent("indices", isDirectory: true)
        try fm.createDirectory(at: indexDir, withIntermediateDirectories: true)
        for archive in plan.archives {
            let destination = indexDir.appendingPathComponent("\(archive).index")
            if fm.fileExists(atPath: destination.path) { continue }
            try copy(try await plan.cdn.cachedFile(.data, archive, suffix: ".index"), to: destination)
        }
        // The CDN config's other indexes, as the Agent keeps them. The game
        // can fetch these itself, so a missing one is logged, not fatal.
        // (archive-group and patch-archive-group aren't on the CDN; the Agent
        // builds them locally from the archive indexes. Not written yet.)
        let cdnConfig = TACTConfig(String(decoding: plan.cdnConfig, as: UTF8.self))
        var extraIndexes: [(CDNClient.Kind, String)] = cdnConfig["patch-archives"].map { (.patch, $0) }
        if let fileIndex = cdnConfig["file-index"].first { extraIndexes.append((.data, fileIndex)) }
        if let patchFileIndex = cdnConfig["patch-file-index"].first { extraIndexes.append((.patch, patchFileIndex)) }
        for (kind, hash) in extraIndexes {
            let destination = indexDir.appendingPathComponent("\(hash).index")
            if fm.fileExists(atPath: destination.path) { continue }
            do {
                try copy(try await plan.cdn.cachedFile(kind, hash, suffix: ".index"), to: destination)
            } catch {
                Log.warning(.install, "index_unavailable", nil, ["uid": install.uid, "index": hash, "kind": kind.rawValue, "error": error])
            }
        }
        // The group indexes the Agent builds from those (not on the CDN).
        // The game would otherwise merge them itself at startup, so a failure
        // here is logged, not fatal.
        for (list, group) in [("archives", "archive-group"), ("patch-archives", "patch-archive-group")] {
            guard let name = cdnConfig[group].first else { continue }
            let files = cdnConfig[list].map { indexDir.appendingPathComponent("\($0).index") }
            guard !files.isEmpty, files.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { continue }
            do {
                let started = Date()
                let built = try ArchiveGroup.build(indexFiles: files, expected: name, in: indexDir)
                Log.info(.install, built ? "archive_group_built" : "archive_group_mismatch", nil,
                         ["uid": install.uid, "group": group, "archives": files.count, "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
            } catch {
                Log.warning(.install, "archive_group_failed", nil, ["uid": install.uid, "group": group, "error": error])
            }
        }

        // Local storage: a new one, or new files appended to the existing one
        // (an update, or another product sharing the folder).
        let counter = ByteCounter(total: total)
        let resuming = fm.fileExists(atPath: storageDir.appendingPathComponent(CASCStorageWriter.journalName).path)
        if !plan.storage.isEmpty || resuming {
            try await writeStorage(plan, to: storageDir, counter: counter, progress: progress)
        }

        // Loose files (the game's .app and friends), verified like updates.
        try fm.createDirectory(at: looseRoot, withIntermediateDirectories: true)
        if !plan.loose.isEmpty {
            let base = counter.completed
            try await GameUpdater(install: plan.loose.install, versions: versions, store: store)
                .apply(plan.loose, record: false) { p in
                    progress(UpdateProgress(completedBytes: base + p.completedBytes, totalBytes: total,
                                            completedFiles: p.completedFiles, totalFiles: p.totalFiles))
                }
        }

        try writeBuildInfo(plan)
        if !config.subfolder.isEmpty {
            try write(Data("Product Flavor!STRING:0\n\(install.productCode)\n".utf8), to: looseRoot.appendingPathComponent(".flavor.info"))
        }
        var record = install
        record.tagString = install.tagString ?? config.tagString(region: region, language: install.textLanguage ?? "enUS")
        try store.record(uid: install.uid, InstalledBuild(buildConfig: plan.target.buildConfig, version: plan.target.name, install: record))
        if storageExisted {
            // Best effort: the update itself is done either way.
            do {
                _ = try await cleanStorage()
            } catch {
                Log.warning(.install, "storage_clean_skipped", nil, ["uid": install.uid, "error": error])
            }
        }
        Log.notice(.install, "casc_apply_finished", nil, ["uid": install.uid, "version": plan.target.name,
                                                          "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
    }

    /// Removes from the storage what none of the builds in `.build.info`
    /// needs (old builds' files) and gives the space back; see
    /// `CASCStorageCleaner`. A key stays if any listed build's encoding table
    /// or build config names it, which covers every file of those builds
    /// whatever their tags. Nothing is removed unless every build loads.
    public func cleanStorage(dryRun: Bool = false, log: @Sendable (String) -> Void = { _ in }) async throws -> CASCStorageCleaner.Result {
        guard RunningProcesses.inside(root).isEmpty else { throw UpdateError.gameRunning }
        try BattleNet.ensureNotRunning()
        let storageDir = dataRoot.appendingPathComponent("data", isDirectory: true)
        guard let stored = try StoredKeys.load(storageDir) else { return .init() }
        let buildInfo = try String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8)
        let rows = BPSV(buildInfo).rows
        guard !rows.isEmpty else { throw TACTError.malformed(".build.info") }

        var live = stored.buckets.map { [Bool](repeating: false, count: $0.count) }
        func mark(_ key: Key16) {
            let key9 = key.prefix9
            if let i = stored.position(of: key9) { live[key9.bucket][i] = true }
        }
        for row in rows {
            guard let product = row["Product"], !product.isEmpty else { throw TACTError.malformed(".build.info row without a product") }
            let rowRegion = row["Branch"].flatMap { Region(rawValue: $0.lowercased()) } ?? region
            let cdn = try await versions.cdn(product: product, region: rowRegion)
            // The installed build, and one the Agent may be downloading ahead.
            for buildKey in [row["Build Key"], row["BGDL Key"]].compactMap({ $0 }).filter({ $0.count == 32 }) {
                let configData = try await cdn.cached(.config, buildKey, localCopy: configURL(buildKey))
                let config = String(decoding: configData, as: UTF8.self)
                for word in config.split(whereSeparator: { $0 == " " || $0.isNewline }) where word.count == 32 {
                    if let key = Data(hex: String(word)).flatMap(Key16.init) { mark(key) }
                }
                guard let encodingKey = TACTConfig(config).encodedKey("encoding") else { throw TACTError.malformed("build config \(buildKey)") }
                let encodingFile = try await cdnDecodedPath(cdn, encodingKey)
                try autoreleasepool {
                    try EncodingTable.forEachEncodedKey(try Data(contentsOf: encodingFile, options: .alwaysMapped), mark)
                }
                log("\(product) build \(buildKey.prefix(8)): checked")
            }
        }
        var result = try CASCStorageCleaner.clean(storageDir, dryRun: dryRun) { key in
            stored.position(of: key).map { live[key.bucket][$0] } ?? false
        }
        result.removedIndexBytes = try await removeStaleIndexes(rows, dryRun: dryRun)
        log("\(dryRun ? "Would remove" : "Removed") \(result.removedFiles) files no installed build uses (\(result.removedBytes) bytes); \(result.reclaimedBytes) bytes of disk given back; \(result.removedIndexBytes) bytes of old CDN indexes")
        return result
    }

    /// CDN indexes in `Data/indices` that none of the installed builds' CDN
    /// configs names any more (every CDN config change brings new archives
    /// and a new group index, 130 MB for WoW). Kept unless every config loads.
    private func removeStaleIndexes(_ rows: [[String: String]], dryRun: Bool) async throws -> UInt64 {
        let fm = FileManager.default
        let indexDir = dataRoot.appendingPathComponent("indices", isDirectory: true)
        var referenced = Set<String>()
        for row in rows {
            guard let product = row["Product"], let cdnKey = row["CDN Key"], cdnKey.count == 32 else {
                throw TACTError.malformed(".build.info row without a CDN config")
            }
            let rowRegion = row["Branch"].flatMap { Region(rawValue: $0.lowercased()) } ?? region
            let cdn = try await versions.cdn(product: product, region: rowRegion)
            let config = String(decoding: try await cdn.cached(.config, cdnKey, localCopy: configURL(cdnKey)), as: UTF8.self)
            for word in config.split(whereSeparator: { $0 == " " || $0.isNewline }) where word.count == 32 {
                referenced.insert(word.lowercased())
            }
        }
        var removed: UInt64 = 0
        for file in (try? fm.contentsOfDirectory(atPath: indexDir.path)) ?? [] {
            guard file.hasSuffix(".index"), file.count == 38, !referenced.contains(String(file.prefix(32)).lowercased()) else { continue }
            let url = indexDir.appendingPathComponent(file)
            removed += (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if !dryRun { try? fm.removeItem(at: url) }
        }
        return removed
    }

    /// The decoded encoding table on disk (downloading and decoding it if needed).
    private func cdnDecodedPath(_ cdn: CDNClient, _ key: String) async throws -> URL {
        _ = try await cdn.decoded(key)
        return cdn.cacheDirectory.appendingPathComponent(cdn.relativePath(.data, key, suffix: ".decoded"))
    }

    private func writeStorage(_ plan: CASCInstallPlan, to storageDir: URL, counter: ByteCounter,
                              progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        let writer = try CASCStorageWriter(directory: storageDir, allowExisting: true)
        let storage = plan.storage
        var stored: UInt64 = 0
        let batches = Self.batches(storage, maxBytes: maxBatchBytes, maxGap: maxGapBytes) { item in
            guard writer.contains(item.key) else { return false }
            stored += item.size
            return true
        }
        counter.add(stored)
        Log.notice(.install, writer.isUpdate ? "storage_update" : "storage_new", nil,
                   ["uid": install.uid, "batches": batches.count, "already_stored_bytes": stored])

        try await withThrowingTaskGroup(of: [(StorageItem, Data)].self) { group in
            var queue = batches.makeIterator()
            func next() {
                guard let batch = queue.next() else { return }
                let items = batch.items.map { storage[Int($0)] }
                let archive = batch.archive >= 0 ? plan.archives[Int(batch.archive)] : nil
                group.addTask { try await Self.fetch(items, archive: archive, start: batch.start, end: batch.end, cdn: plan.cdn) }
            }
            for _ in 0..<concurrency { next() }
            while let results = try await group.next() {
                try autoreleasepool {
                    for (item, blob) in results {
                        try writer.append(key: item.key, blob: blob, fullKey: item.fullKey)
                        progress(counter.add(UInt64(blob.count)))
                    }
                }
                next()
            }
        }
        // Battle.net may have started during a long download: leave the index
        // files alone then; the journal keeps what was downloaded for next time.
        try BattleNet.ensureNotRunning()
        try writer.finish()
        Log.info(.install, "storage_written", nil, ["uid": install.uid, "files": writer.count, "update": writer.isUpdate])
    }

    /// Which loose files to download and delete. A fresh install downloads
    /// all of them; an update compares the installed build's install manifest
    /// (or, without it or with `verify`, hashes the files on disk).
    private func looseChanges(_ wanted: [InstallManifest.Entry], target: ProductVersion, cdn: CDNClient, tags: String,
                              verify: Bool, looseInstall: ProductInstall,
                              log: @Sendable (String) -> Void) async throws -> (changed: [InstallManifest.Entry], deletions: [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: looseRoot.path) else { return (wanted, []) }
        var previous: [String: Data]?
        if !verify, let installed = install.buildConfig {
            if installed == target.buildConfig {
                previous = Dictionary(wanted.map { ($0.path, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
            } else if let oldConfig = try? await cdn.cached(.config, installed, localCopy: configURL(installed)),
                      let oldInstallKey = TACTConfig(String(decoding: oldConfig, as: UTF8.self)).encodedKey("install"),
                      let oldManifest = try? InstallManifest(BLTE.decode(try await cdn.cached(.data, oldInstallKey))) {
                previous = Dictionary(oldManifest.select(tagString: tags).map {
                    ($0.path.replacingOccurrences(of: "\\", with: "/"), $0.contentKey)
                }, uniquingKeysWith: { a, _ in a })
            } else {
                log("Installed build's manifest is gone from the CDN; checking files by hash")
            }
        }
        let updater = GameUpdater(install: looseInstall, versions: versions, store: store)
        return try GameUpdater.diff(
            wanted: wanted, previous: previous,
            localSize: { path in
                guard let url = try? updater.safeURL(path) else { return nil }
                return (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
            },
            localHash: { path, _ in try GameUpdater.md5(of: try updater.safeURL(path)) })
    }

    // MARK: Pieces

    /// One download: a range of one CDN archive holding several wanted
    /// blobs (indices into the plan's storage), or a file of its own.
    struct Batch: Sendable {
        var archive: Int32
        var start: UInt64
        var end: UInt64
        var items: [Int32]
    }

    /// Groups blobs that sit close together in one CDN archive into single
    /// range requests; files outside archives are fetched one by one. Items
    /// `skip` returns true for (already stored) are left out.
    static func batches(_ items: [StorageItem], maxBytes: UInt64, maxGap: UInt64,
                        skip: (StorageItem) -> Bool = { _ in false }) -> [Batch] {
        var order = items.indices.filter { items[$0].isInArchive }.map { Int32($0) }
        order.sort { (items[Int($0)].archive, items[Int($0)].offset) < (items[Int($1)].archive, items[Int($1)].offset) }
        var result: [Batch] = []
        for index in order {
            let item = items[Int(index)]
            if skip(item) { continue }
            let start = UInt64(item.offset), end = UInt64(item.offset) + item.size
            if var last = result.last, last.archive == item.archive, start >= last.end,
               start - last.end <= maxGap, end - last.start <= maxBytes {
                last.end = end
                last.items.append(index)
                result[result.count - 1] = last
            } else {
                result.append(Batch(archive: item.archive, start: start, end: end, items: [index]))
            }
        }
        for (index, item) in items.enumerated() where !item.isInArchive && !skip(item) {
            result.append(Batch(archive: -1, start: 0, end: 0, items: [Int32(index)]))
        }
        return result
    }

    /// Downloads one batch and checks every blob. Blobs are slices of the
    /// memory-mapped download, not copies.
    static func fetch(_ items: [StorageItem], archive: String?, start: UInt64, end: UInt64, cdn: CDNClient) async throws -> [(StorageItem, Data)] {
        let file: URL
        if let archive {
            file = try await cdn.download(.data, archive, range: start...(end - 1))
        } else {
            file = try await cdn.download(items[0].kind, items[0].key.hex)
        }
        defer { try? FileManager.default.removeItem(at: file) } // the mapping outlives the name
        return try autoreleasepool { try check(items, in: file, start: start) }
    }

    private static func check(_ items: [StorageItem], in file: URL, start: UInt64) throws -> [(StorageItem, Data)] {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return try items.map { item in
            let blob: Data
            if item.isInArchive {
                let from = Int(UInt64(item.offset) - start)
                guard from + Int(item.size) <= data.count else { throw TACTError.malformed("short range for \(item.key.hex)") }
                blob = data[data.startIndex + from..<data.startIndex + from + Int(item.size)]
            } else {
                blob = data
            }
            if item.isRaw {
                guard item.size == 0 || UInt64(blob.count) == item.size else { throw TACTError.malformed("size of \(item.key.hex)") }
            } else {
                try BLTE.verify(blob, encodedKey: item.encodedKey)
            }
            return (item, blob)
        }
    }

    private func configURL(_ hash: String) -> URL {
        dataRoot.appendingPathComponent("config/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
    }

    /// Copies (on APFS: clones) a cached file into the game folder.
    private func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.appendingPathExtension("\(UUID().uuidString).part")
        try fm.copyItem(at: source, to: temp)
        _ = try fm.replaceItemAt(destination, withItemAt: temp)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// `.build.info`: one row per installed product; WoW flavors share it.
    private func writeBuildInfo(_ plan: CASCInstallPlan) throws {
        let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0"
        let tags = install.tagString ?? config.tagString(region: region, language: install.textLanguage ?? "enUS")
        let row = [region.rawValue, "1", plan.target.buildConfig, plan.target.cdnConfig, "", "", plan.cdn.path,
                   plan.cdn.hosts.joined(separator: " "), plan.cdn.serversField, tags, "", "", plan.target.name,
                   plan.target.keyRing ?? "", install.productCode].joined(separator: "|")
        let url = root.appendingPathComponent(".build.info")
        var rows: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            rows = existing.split(separator: "\n").dropFirst().map(String.init)
                .filter { !$0.hasPrefix("#") && $0.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) != install.productCode }
        }
        rows.append(row)
        try write(Data(([header] + rows).joined(separator: "\n").appending("\n").utf8), to: url)
    }
}

/// CDN archive indexes, kept on disk and read memory-mapped one at a time:
/// WoW's 1,400 indexes are hundreds of megabytes together.
public enum ArchiveIndexes {
    /// Each archive's `.index` file on disk, in the order given: the game's
    /// own copy (`Data/indices`) when there is one, else the cache.
    public static func fetch(_ archives: [String], cdn: CDNClient, localDirectory: URL?, concurrency: Int = 16) async throws -> [URL] {
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var results = [URL?](repeating: nil, count: archives.count)
            var pending = archives.enumerated().makeIterator()
            func add() {
                guard let (i, archive) = pending.next() else { return }
                group.addTask {
                    (i, try await cdn.cachedFile(.data, archive, suffix: ".index",
                                                 localCopy: localDirectory?.appendingPathComponent("\(archive).index")))
                }
            }
            for _ in 0..<concurrency { add() }
            while let (i, url) = try await group.next() {
                results[i] = url
                add()
            }
            return results.map { $0! }
        }
    }

    /// Fills in where each item sits. `items` must be sorted by key; the
    /// first archive (in `indexFiles` order) holding a key wins.
    static func locate(_ items: inout [StorageItem], indexFiles: [URL]) throws {
        var remaining = items.reduce(0) { $0 + ($1.isInArchive ? 0 : 1) }
        for (archive, file) in indexFiles.enumerated() where remaining > 0 {
            try autoreleasepool { // unmaps each index as soon as it's scanned
                let data = try Data(contentsOf: file, options: .alwaysMapped)
                try ArchiveIndex.scan(data, archive: file.lastPathComponent) { key, keySize, size, offset in
                    guard keySize >= 16 else { return false }
                    if let i = index(of: Key16(key), in: items), !items[i].isInArchive {
                        items[i].archive = Int32(archive)
                        items[i].offset = UInt32(truncatingIfNeeded: offset)
                        items[i].size = size
                        remaining -= 1
                    }
                    return remaining > 0
                }
            }
        }
    }

    /// Where a few keys sit (loose files, changed Hearthstone files).
    public static func locate(_ wanted: Set<Key16>, archives: [String], indexFiles: [URL]) throws -> [Key16: ArchiveLocation] {
        var remaining = wanted
        var found: [Key16: ArchiveLocation] = [:]
        for (archive, file) in zip(archives, indexFiles) where !remaining.isEmpty {
            try autoreleasepool {
                let data = try Data(contentsOf: file, options: .alwaysMapped)
                try ArchiveIndex.scan(data, archive: archive) { key, keySize, size, offset in
                    guard keySize >= 16 else { return false }
                    let k = Key16(key)
                    if remaining.remove(k) != nil { found[k] = ArchiveLocation(archive: archive, offset: offset, size: size) }
                    return !remaining.isEmpty
                }
            }
        }
        return found
    }

    /// Bisection in items sorted by key.
    static func index(of key: Key16, in items: [StorageItem]) -> Int? {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].key < key { low = mid + 1 } else { high = mid }
        }
        return low < items.count && items[low].key == key ? low : nil
    }
}

/// Thread-safe running total for progress.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var files = 0
    private var loggedDecile = 0
    let total: UInt64

    init(total: UInt64) { self.total = total }

    var completed: UInt64 { lock.lock(); defer { lock.unlock() }; return bytes }

    @discardableResult
    func add(_ size: UInt64) -> UpdateProgress {
        lock.lock()
        bytes += size
        files += 1
        let decile = total == 0 ? 10 : Int(min(bytes, total) * 10 / total)
        let logIt = decile > loggedDecile
        if logIt { loggedDecile = decile }
        let snapshot = UpdateProgress(completedBytes: bytes, totalBytes: total, completedFiles: files, totalFiles: 0)
        lock.unlock()
        if logIt { Log.info(.install, "progress", nil, ["percent": decile * 10, "bytes": snapshot.completedBytes]) }
        return snapshot
    }
}
