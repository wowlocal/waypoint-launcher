import CryptoKit
import Foundation

/// One encoded file to put into local storage.
public struct StorageItem: Sendable {
    public var encodedKey: Data
    /// Encoded (BLTE) size; 0 when only the download tells.
    public var size: UInt64
    public var location: ArchiveLocation?
    /// Build-config files get their whole key in the entry header, like the Agent writes them.
    public var fullKey: Bool
    /// Where on the CDN it lives when it isn't in an archive.
    public var kind: CDNClient.Kind = .data
    /// Stored as is rather than BLTE (the patch manifest); checked by size.
    public var isRaw = false
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
    public var storage: [StorageItem]
    /// Loose files from the install manifest, rooted at the flavor folder.
    public var loose: UpdatePlan

    public var downloadSize: UInt64 { storage.reduce(0) { $0 + $1.size } + loose.downloadSize }
}

/// Installs a game that keeps its data in local CASC storage (WoW, StarCraft,
/// Diablo III, Warcraft III, Heroes): the same pieces the Agent lays down.
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

    public func plan(target requested: ProductVersion? = nil, log: @Sendable (String) -> Void = { _ in }) async throws -> CASCInstallPlan {
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
        let looseEntries = try InstallManifest(BLTE.decode(try await cdn.cached(.data, installKey)))
            .select(tagString: tags)
            .map { entry -> InstallManifest.Entry in
                var e = entry
                e.path = e.path.replacingOccurrences(of: "\\", with: "/")
                return e
            }
        log("Build \(target.name): \(looseEntries.count) loose files")

        let downloadEntries = try DownloadManifest(BLTE.decode(try await cdn.cached(.data, downloadKey))).select(tagString: tags)
        log("\(downloadEntries.count) files for local storage")

        let rootKey = buildConfig["root"].first.flatMap { Data(hex: $0) }
        let encoding = try EncodingTable(BLTE.decode(try await cdn.cached(.data, encodingKey)),
                                         wanted: Set(looseEntries.map(\.contentKey) + (rootKey.map { [$0] } ?? [])))

        var looseFiles: [UpdatePlan.File] = try looseEntries.map { entry in
            guard let encoded = encoding.entries[entry.contentKey] else { throw TACTError.notFound("encoding entry for \(entry.path)") }
            return UpdatePlan.File(path: entry.path, contentKey: entry.contentKey, encodedKey: encoded.encodedKey, size: entry.size, location: nil)
        }
        let looseKeys = Set(looseFiles.map(\.encodedKey))

        // Build-config files (encoding, install, download, patch index, VFS)
        // live in storage with full keys in their headers; root too, but with
        // the short key like bulk content. The size manifest isn't stored.
        var storage: [StorageItem] = []
        var seen = Set<Data>()
        func isHash(_ s: String) -> Bool { s.count == 32 && s.allSatisfy(\.isHexDigit) }
        for (name, values) in buildConfig.values.sorted(by: { $0.key < $1.key })
        where name != "size" && values.count == 2 && isHash(values[0]) && isHash(values[1]) {
            guard let key = Data(hex: values[1]), seen.insert(key).inserted else { continue }
            let size = buildConfig["\(name)-size"].last.flatMap(UInt64.init) ?? 0
            storage.append(StorageItem(encodedKey: key, size: size, location: nil, fullKey: true))
        }
        // The patch manifest: a raw file on the CDN's patch path, stored as is
        // with its full key (matched against an Agent-written storage).
        if let patch = buildConfig["patch"].first, buildConfig["patch"].count == 1, let key = Data(hex: patch), seen.insert(key).inserted {
            let size = buildConfig["patch-size"].first.flatMap(UInt64.init) ?? 0
            storage.append(StorageItem(encodedKey: key, size: size, location: nil, fullKey: true, kind: .patch, isRaw: true))
        }
        if let rootKey, let rootEncoded = encoding.entries[rootKey], seen.insert(rootEncoded.encodedKey).inserted {
            storage.append(StorageItem(encodedKey: rootEncoded.encodedKey, size: 0, location: nil, fullKey: false))
        }
        for entry in downloadEntries where !looseKeys.contains(entry.encodedKey) && seen.insert(entry.encodedKey).inserted {
            storage.append(StorageItem(encodedKey: entry.encodedKey, size: entry.size, location: nil, fullKey: false))
        }

        let archives = cdnConfig["archives"]
        log("Locating \(storage.count + looseFiles.count) files in \(archives.count) CDN archives")
        let indexes = try await ArchiveIndexes.fetch(archives, cdn: cdn, localDirectory: dataRoot.appendingPathComponent("indices"))
        let locations = try ArchiveIndexes.locate(Set(storage.map(\.encodedKey)).union(looseKeys), in: indexes)
        for i in storage.indices {
            storage[i].location = locations[storage[i].encodedKey]
            if let location = storage[i].location { storage[i].size = location.size }
        }
        for i in looseFiles.indices { looseFiles[i].location = locations[looseFiles[i].encodedKey] }

        var looseInstall = install
        looseInstall.installPath = looseRoot.path
        let loose = UpdatePlan(install: looseInstall, target: target, cdn: cdn, files: looseFiles, deletions: [])
        let plan = CASCInstallPlan(install: install, product: product, config: config, target: target, cdn: cdn,
                                   buildConfig: buildConfigData, cdnConfig: cdnConfigData, archives: archives,
                                   storage: storage, loose: loose)
        Log.info(.install, "casc_plan_ready", nil, [
            "uid": install.uid, "version": target.name, "storage_files": storage.count,
            "storage_bytes": plan.storage.reduce(UInt64(0)) { $0 + $1.size }, "loose_files": looseFiles.count,
            "unlocated": storage.filter { $0.location == nil }.count, "archives": archives.count,
            "duration_ms": Int(Date().timeIntervalSince(started) * 1000),
        ])
        return plan
    }

    // MARK: Apply

    public func apply(_ plan: CASCInstallPlan, progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        let started = Date()
        let fm = FileManager.default
        guard RunningProcesses.inside(root).isEmpty else { throw UpdateError.gameRunning }
        let storageDir = dataRoot.appendingPathComponent("data", isDirectory: true)
        // A storage the Agent (or another product) already wrote: don't clobber it.
        let existingIndexes = ((try? fm.contentsOfDirectory(atPath: storageDir.path)) ?? []).filter { $0.hasSuffix(".idx") }
        if !existingIndexes.isEmpty, !fm.fileExists(atPath: storageDir.appendingPathComponent(CASCStorageWriter.journalName).path) {
            throw UpdateError.unsupported("adding \(product.displayName) to an existing \(config.dataDirectory) storage")
        }

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
            try write(try await plan.cdn.cached(.data, archive, suffix: ".index"), to: destination)
        }

        // Local storage.
        let writer = try CASCStorageWriter(directory: storageDir)
        let pending = plan.storage.filter { !writer.contains($0.encodedKey) }
        let looseBytes = plan.loose.downloadSize
        let counter = ByteCounter(total: total)
        counter.add(plan.storage.filter { writer.contains($0.encodedKey) }.reduce(0) { $0 + $1.size })
        if writer.count > 0 { Log.notice(.install, "resumed", nil, ["uid": install.uid, "already_stored": writer.count]) }

        let batches = Self.batches(pending, maxBytes: maxBatchBytes, maxGap: maxGapBytes)
        try await withThrowingTaskGroup(of: [(StorageItem, Data)].self) { group in
            var queue = batches.makeIterator()
            for _ in 0..<concurrency {
                guard let batch = queue.next() else { break }
                group.addTask { try await Self.fetch(batch, cdn: plan.cdn) }
            }
            while let results = try await group.next() {
                for (item, blob) in results {
                    try writer.append(encodedKey: item.encodedKey, blob: blob, fullKey: item.fullKey)
                    progress(counter.add(UInt64(blob.count)))
                }
                if let batch = queue.next() { group.addTask { try await Self.fetch(batch, cdn: plan.cdn) } }
            }
        }
        try writer.finish()
        Log.info(.install, "storage_written", nil, ["uid": install.uid, "files": writer.count])

        // Loose files (the game's .app and friends), verified like updates.
        try fm.createDirectory(at: looseRoot, withIntermediateDirectories: true)
        let base = counter.completed
        try await GameUpdater(install: plan.loose.install, versions: versions, store: store)
            .apply(plan.loose, record: false) { p in
                progress(UpdateProgress(completedBytes: base + p.completedBytes, totalBytes: total,
                                        completedFiles: p.completedFiles, totalFiles: p.totalFiles))
            }
        _ = looseBytes

        try writeBuildInfo(plan)
        if !config.subfolder.isEmpty {
            try write(Data("Product Flavor!STRING:0\n\(install.productCode)\n".utf8), to: looseRoot.appendingPathComponent(".flavor.info"))
        }
        var record = install
        record.tagString = install.tagString ?? config.tagString(region: region, language: install.textLanguage ?? "enUS")
        try store.record(uid: install.uid, InstalledBuild(buildConfig: plan.target.buildConfig, version: plan.target.name, install: record))
        Log.notice(.install, "casc_apply_finished", nil, ["uid": install.uid, "version": plan.target.name,
                                                          "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
    }

    // MARK: Pieces

    struct Batch: Sendable {
        var archive: String?
        var start: UInt64
        var end: UInt64
        var items: [StorageItem]
    }

    /// Groups blobs that sit close together in one CDN archive into single
    /// range requests; files outside archives are fetched one by one.
    static func batches(_ items: [StorageItem], maxBytes: UInt64, maxGap: UInt64) -> [Batch] {
        var result: [Batch] = []
        let located = items.filter { $0.location != nil }.sorted {
            ($0.location!.archive, $0.location!.offset) < ($1.location!.archive, $1.location!.offset)
        }
        for item in located {
            let loc = item.location!
            if var last = result.last, last.archive == loc.archive, loc.offset >= last.end,
               loc.offset - last.end <= maxGap, loc.offset + loc.size - last.start <= maxBytes {
                last.end = loc.offset + loc.size
                last.items.append(item)
                result[result.count - 1] = last
            } else {
                result.append(Batch(archive: loc.archive, start: loc.offset, end: loc.offset + loc.size, items: [item]))
            }
        }
        for item in items where item.location == nil {
            result.append(Batch(archive: nil, start: 0, end: 0, items: [item]))
        }
        return result
    }

    static func fetch(_ batch: Batch, cdn: CDNClient) async throws -> [(StorageItem, Data)] {
        let file: URL
        if let archive = batch.archive {
            file = try await cdn.download(.data, archive, range: batch.start...(batch.end - 1))
        } else {
            file = try await cdn.download(batch.items[0].kind, batch.items[0].encodedKey.hex)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return try batch.items.map { item in
            let blob: Data
            if let loc = item.location {
                let from = Int(loc.offset - batch.start)
                guard from + Int(loc.size) <= data.count else { throw TACTError.malformed("short range for \(item.encodedKey.hex)") }
                blob = data.subdata(in: from..<from + Int(loc.size))
            } else {
                blob = Data(data)
            }
            if item.isRaw {
                guard item.size == 0 || UInt64(blob.count) == item.size else { throw TACTError.malformed("size of \(item.encodedKey.hex)") }
            } else {
                try BLTE.verify(blob, encodedKey: item.encodedKey)
            }
            return (item, blob)
        }
    }

    private func configURL(_ hash: String) -> URL {
        dataRoot.appendingPathComponent("config/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
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

/// Downloads CDN archive indexes (cached) and finds where encoded files live.
public enum ArchiveIndexes {
    public static func fetch(_ archives: [String], cdn: CDNClient, localDirectory: URL?, concurrency: Int = 16) async throws -> [(String, Data)] {
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var results: [(String, Data)] = []
            results.reserveCapacity(archives.count)
            var pending = archives.makeIterator()
            func add(_ archive: String) {
                group.addTask {
                    (archive, try await cdn.cached(.data, archive, suffix: ".index",
                                                   localCopy: localDirectory?.appendingPathComponent("\(archive).index")))
                }
            }
            for _ in 0..<concurrency { if let a = pending.next() { add(a) } }
            while let result = try await group.next() {
                results.append(result)
                if let a = pending.next() { add(a) }
            }
            return results
        }
    }

    public static func locate(_ wanted: Set<Data>, in indexes: [(String, Data)]) throws -> [Data: ArchiveLocation] {
        var remaining = wanted
        var found: [Data: ArchiveLocation] = [:]
        for (archive, data) in indexes where !remaining.isEmpty {
            let hits = try ArchiveIndex.locate(remaining, in: data, archive: archive)
            found.merge(hits) { a, _ in a }
            remaining.subtract(hits.keys)
        }
        return found
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
