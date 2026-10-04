import CryptoKit
import Darwin
import Foundation

public struct UpdateCheck: Sendable {
    public var installedBuild: String?
    public var installedVersion: String?
    public var latest: ProductVersion

    public var isUpdateAvailable: Bool {
        if let installedBuild { return installedBuild != latest.buildConfig }
        return installedVersion != latest.name
    }
}

public struct UpdatePlan: Sendable {
    public struct File: Sendable {
        public var path: String
        public var contentKey: Data
        public var encodedKey: Data
        public var size: UInt64
        /// nil when the file is stored loose on the CDN rather than in an archive.
        public var location: ArchiveLocation?
    }

    public var install: ProductInstall
    public var target: ProductVersion
    public var cdn: CDNClient
    public var files: [File]
    /// Files the old build had and the new one doesn't.
    public var deletions: [String]

    public var downloadSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { files.isEmpty && deletions.isEmpty }
}

public struct UpdateProgress: Sendable {
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    public var completedFiles: Int
    public var totalFiles: Int

    public var fraction: Double { totalBytes == 0 ? 1 : Double(completedBytes) / Double(totalBytes) }
}

public enum UpdateError: Error, CustomStringConvertible {
    case gameRunning
    case unsupported(String)
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case unsafePath(String)

    public var description: String {
        switch self {
        case .gameRunning: "Quit the game before updating"
        case .unsupported(let name): "Updating \(name) is not supported yet"
        case .notEnoughSpace(let needed, let available):
            "Not enough disk space: need \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file))"
        case .unsafePath(let path): "Refusing to write outside the game folder: \(path)"
        }
    }
}

/// Updates a game whose files are installed loose in its folder (Hearthstone),
/// the way the Battle.net Agent does: compare the old and new install
/// manifests, download what changed from the CDN, verify every file against
/// its content hash, then swap the files in.
///
/// WoW keeps its data in a CASC archive store instead, which this doesn't
/// write yet.
public struct GameUpdater: Sendable {
    public var install: ProductInstall
    public var versions: VersionService
    public var store: InstallStateStore
    public var concurrency: Int

    public init(install: ProductInstall, versions: VersionService = VersionService(),
                store: InstallStateStore = InstallStateStore(), concurrency: Int = 4) {
        self.install = install
        self.versions = versions
        self.store = store
        self.concurrency = concurrency
    }

    public static func canUpdate(_ family: GameFamily) -> Bool { family == .hearthstone }

    var region: Region { install.region.flatMap(Region.init(rawValue:)) ?? .us }
    var root: URL { URL(fileURLWithPath: install.installPath, isDirectory: true) }
    var stagingDirectory: URL { root.appendingPathComponent(".waypoint-staging", isDirectory: true) }

    public func check() async throws -> UpdateCheck {
        let latest = try await versions.latest(product: install.productCode, region: region)
        return UpdateCheck(installedBuild: install.buildConfig, installedVersion: install.version, latest: latest)
    }

    /// Works out what to download and delete. With `verify`, every file is
    /// hashed instead of trusting the installed build's manifest (a repair).
    /// `only` limits the plan to some paths (for partial downloads and tests).
    public func plan(target requested: ProductVersion? = nil, verify: Bool = false,
                     only: (@Sendable (String) -> Bool)? = nil,
                     log: @Sendable (String) -> Void = { _ in }) async throws -> UpdatePlan {
        guard GameUpdater.canUpdate(GameCatalog.family(for: install.productCode)) else {
            throw UpdateError.unsupported(install.productCode)
        }
        let started = Date()
        let target: ProductVersion
        if let given = requested {
            target = given
        } else {
            target = try await versions.latest(product: install.productCode, region: region)
        }
        let cdn = try await versions.cdn(product: install.productCode, region: region)
        let tags = install.tagString ?? "OSX \(region.launchOptionValue) \(install.textLanguage ?? "enUS")"

        let buildConfig = try await config(target.buildConfig, cdn)
        let cdnConfig = try await config(target.cdnConfig, cdn)
        let wanted = try await installManifest(buildConfig, cdn).select(tagString: tags)
            .filter { only?($0.path) ?? true }
        log("Build \(target.name): \(wanted.count) files for this install")
        Log.info(.gameUpdate, "plan_started", nil, ["uid": install.uid, "path": install.installPath, "from": install.version ?? "none",
                                                     "to": target.name, "verify": verify, "files": wanted.count, "filtered": only != nil])

        // What the installed build had, so unchanged files can be skipped without hashing.
        var previous: [String: Data]?
        if !verify, let installed = install.buildConfig {
            if installed == target.buildConfig {
                previous = Dictionary(wanted.map { ($0.path, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
            } else if let oldConfig = try? await config(installed, cdn),
                      let oldManifest = try? await installManifest(oldConfig, cdn) {
                previous = Dictionary(oldManifest.select(tagString: tags).filter { only?($0.path) ?? true }
                                        .map { ($0.path, $0.contentKey) },
                                      uniquingKeysWith: { a, _ in a })
            } else {
                log("Installed build's manifest is gone from the CDN; checking files by hash")
                Log.warning(.gameUpdate, "old_manifest_missing", "falling back to hashing local files", ["uid": install.uid, "build_config": installed])
            }
        }

        let fm = FileManager.default
        let (changed, deletions) = try Self.diff(
            wanted: wanted,
            previous: previous,
            localSize: { path in
                guard let url = try? safeURL(path) else { return nil }
                return (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
            },
            localHash: { path, index in
                if index % 250 == 0 { log("Checking files: \(index)/\(wanted.count)") }
                return try Self.md5(of: try safeURL(path))
            })

        guard !changed.isEmpty else {
            Log.info(.gameUpdate, "plan_ready", "nothing to download", ["uid": install.uid, "to": target.name, "deletions": deletions.count,
                                                                       "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
            return UpdatePlan(install: install, target: target, cdn: cdn, files: [], deletions: deletions)
        }

        log("Resolving \(changed.count) files")
        guard let encodingKey = buildConfig.encodedKey("encoding") else { throw TACTError.malformed("build config (no encoding)") }
        let encoding = try EncodingTable(BLTE.decode(try await cdn.cached(.data, encodingKey)),
                                         wanted: Set(changed.map(\.contentKey)))
        var files: [UpdatePlan.File] = try changed.map { entry in
            guard let encoded = encoding.entries[entry.contentKey] else { throw TACTError.notFound("encoding entry for \(entry.path)") }
            return UpdatePlan.File(path: entry.path, contentKey: entry.contentKey, encodedKey: encoded.encodedKey,
                                   size: entry.size, location: nil)
        }

        let locations = try await locate(Set(files.map(\.encodedKey)), archives: cdnConfig["archives"], cdn)
        for i in files.indices { files[i].location = locations[files[i].encodedKey] }
        let plan = UpdatePlan(install: install, target: target, cdn: cdn, files: files, deletions: deletions)
        Log.info(.gameUpdate, "plan_ready", nil, ["uid": install.uid, "to": target.name, "files": files.count, "bytes": plan.downloadSize,
                                                 "in_archives": locations.count, "deletions": deletions.count,
                                                 "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
        return plan
    }

    /// Downloads and installs a plan. Nothing in the game folder changes until
    /// every file has been downloaded and verified; interrupted runs resume.
    /// `record: false` leaves the install records alone (CASC installs use this
    /// for their loose files and record the whole install themselves).
    public func apply(_ plan: UpdatePlan, record: Bool = true,
                      progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        let started = Date()
        guard RunningProcesses.inside(root).isEmpty else {
            Log.warning(.gameUpdate, "apply_refused", "game is running", ["uid": install.uid])
            throw UpdateError.gameRunning
        }
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        Log.info(.gameUpdate, "apply_started", nil, ["uid": install.uid, "to": plan.target.name, "files": plan.files.count,
                                                    "bytes": plan.downloadSize, "deletions": plan.deletions.count])

        // Several paths can share one content key; download it once.
        let unique = Dictionary(plan.files.map { ($0.contentKey, $0) }, uniquingKeysWith: { a, _ in a })
        let total = unique.values.reduce(UInt64(0)) { $0 + $1.size }
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage).flatMap { $0 }.map { UInt64($0) } ?? .max
        guard available > total + 512 * 1024 * 1024 else {
            Log.error(.gameUpdate, "not_enough_space", nil, ["uid": install.uid, "needed": total, "available": available])
            throw UpdateError.notEnoughSpace(needed: total, available: available)
        }

        let counter = ProgressCounter(total: total, files: unique.count, uid: install.uid, report: progress)
        counter.report()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = unique.values.makeIterator()
            for _ in 0..<concurrency {
                guard let file = pending.next() else { break }
                group.addTask { try await self.stage(file, cdn: plan.cdn); counter.add(file.size) }
            }
            while try await group.next() != nil {
                if let file = pending.next() {
                    group.addTask { try await self.stage(file, cdn: plan.cdn); counter.add(file.size) }
                }
            }
        }

        // Everything is verified; swap it in.
        guard RunningProcesses.inside(root).isEmpty else { throw UpdateError.gameRunning }
        var remainingUses = Dictionary(plan.files.map { ($0.contentKey, 1) }, uniquingKeysWith: +)
        for file in plan.files {
            let staged = stagedURL(file.contentKey)
            let destination = try safeURL(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let uses = remainingUses[file.contentKey, default: 1]
            remainingUses[file.contentKey] = uses - 1
            let source: URL
            if uses > 1 {
                // APFS clones this instead of copying the bytes.
                source = stagingDirectory.appendingPathComponent(UUID().uuidString)
                try fm.copyItem(at: staged, to: source)
            } else {
                source = staged
            }
            try Self.setPermissions(of: source, replacing: destination)
            guard rename(source.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                               NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        }
        for path in plan.deletions {
            try? fm.removeItem(at: try safeURL(path))
        }
        if record {
            try store.record(uid: install.uid, InstalledBuild(buildConfig: plan.target.buildConfig, version: plan.target.name,
                                                              install: plan.install))
        }
        try? fm.removeItem(at: stagingDirectory)
        Log.notice(.gameUpdate, "apply_finished", nil, ["uid": install.uid, "version": plan.target.name, "files": plan.files.count,
                                                       "deletions": plan.deletions.count, "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
    }

    /// Decides what to download and what to delete.
    ///
    /// - A file whose size on disk is wrong (or that is missing) is downloaded.
    /// - With the installed build's manifest (`previous`), a file is
    ///   downloaded when its content key changed, without hashing anything.
    /// - Without it, local files are hashed and compared.
    /// - Files the installed build had and the new one doesn't are deleted
    ///   (only known when `previous` is available).
    static func diff(wanted: [InstallManifest.Entry], previous: [String: Data]?,
                     localSize: (String) -> UInt64?,
                     localHash: (String, Int) throws -> Data) throws -> (changed: [InstallManifest.Entry], deletions: [String]) {
        var changed: [InstallManifest.Entry] = []
        for (index, entry) in wanted.enumerated() {
            if localSize(entry.path) != entry.size {
                changed.append(entry)
            } else if let previous {
                if previous[entry.path] != entry.contentKey { changed.append(entry) }
            } else if try localHash(entry.path, index) != entry.contentKey {
                changed.append(entry)
            }
        }
        let keep = Set(wanted.map(\.path))
        let deletions = (previous.map { Array($0.keys) } ?? [])
            .filter { !keep.contains($0) && localSize($0) != nil }
            .sorted()
        return (changed, deletions)
    }

    // MARK: - Pieces

    private func stagedURL(_ contentKey: Data) -> URL {
        stagingDirectory.appendingPathComponent(contentKey.hex)
    }

    private func stage(_ file: UpdatePlan.File, cdn: CDNClient) async throws {
        let staged = stagedURL(file.contentKey)
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: staged.path)[.size] as? UInt64, size == file.size,
           (try? Self.md5(of: staged)) == file.contentKey {
            return // left over from an interrupted run
        }

        let blob: URL
        if let location = file.location {
            blob = try await cdn.download(.data, location.archive, range: location.offset...(location.offset + location.size - 1))
        } else {
            blob = try await cdn.download(.data, file.encodedKey.hex)
        }
        defer { try? fm.removeItem(at: blob) }

        let partial = staged.appendingPathExtension("part")
        fm.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        let md5: Data
        do {
            md5 = try BLTE.decode(file: blob, to: output)
            try output.close()
        } catch {
            try? output.close()
            try? fm.removeItem(at: partial)
            throw error
        }
        guard md5 == file.contentKey else {
            try? fm.removeItem(at: partial)
            Log.error(.gameUpdate, "checksum_mismatch", nil, ["path": file.path, "expected": file.contentKey.hex, "got": md5.hex,
                                                             "archive": file.location?.archive ?? "loose"])
            throw TACTError.checksumMismatch(file.path)
        }
        _ = try? fm.removeItem(at: staged)
        try fm.moveItem(at: partial, to: staged)
    }

    private func config(_ hash: String, _ cdn: CDNClient) async throws -> TACTConfig {
        // Battle.net keeps the configs it used next to the game; reuse them.
        let local = root.appendingPathComponent("Data/config/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
        return TACTConfig(String(decoding: try await cdn.cached(.config, hash, localCopy: local), as: UTF8.self))
    }

    private func installManifest(_ buildConfig: TACTConfig, _ cdn: CDNClient) async throws -> InstallManifest {
        guard let key = buildConfig.encodedKey("install") else { throw TACTError.malformed("build config (no install)") }
        return try InstallManifest(BLTE.decode(try await cdn.cached(.data, key)))
    }

    private func locate(_ wanted: Set<Data>, archives: [String], _ cdn: CDNClient) async throws -> [Data: ArchiveLocation] {
        let localIndexes = root.appendingPathComponent("Data/indices")
        // Fetch indexes in parallel (they're ~100 KB each), then scan them.
        let indexes = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var results: [(String, Data)] = []
            var pending = archives.makeIterator()
            for _ in 0..<8 {
                guard let archive = pending.next() else { break }
                group.addTask {
                    (archive, try await cdn.cached(.data, archive, suffix: ".index",
                                                   localCopy: localIndexes.appendingPathComponent("\(archive).index")))
                }
            }
            while let result = try await group.next() {
                results.append(result)
                if let archive = pending.next() {
                    group.addTask {
                        (archive, try await cdn.cached(.data, archive, suffix: ".index",
                                                       localCopy: localIndexes.appendingPathComponent("\(archive).index")))
                    }
                }
            }
            return results
        }
        var remaining = wanted
        var found: [Data: ArchiveLocation] = [:]
        for (archive, data) in indexes where !remaining.isEmpty {
            let hits = try ArchiveIndex.locate(remaining, in: data, archive: archive)
            found.merge(hits) { a, _ in a }
            remaining.subtract(hits.keys)
        }
        return found
    }

    /// Resolves a manifest path inside the game folder, rejecting anything
    /// that would escape it.
    func safeURL(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw UpdateError.unsafePath(path)
        }
        return root.appendingPathComponent(path)
    }

    static func md5(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            md5.update(data: chunk)
        }
        return Data(md5.finalize())
    }

    /// Manifests don't carry permissions. Keep the old file's mode; new files
    /// are executable if they're Mach-O binaries or scripts.
    static func setPermissions(of file: URL, replacing destination: URL) throws {
        let fm = FileManager.default
        let mode: Int
        if let existing = try? fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int {
            mode = existing
        } else {
            let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 4)
            } ?? Data()
            let executableMagics: [[UInt8]] = [
                [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], // Mach-O 64/32
                [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca], // universal
            ]
            let isExecutable = executableMagics.contains { Array(head) == $0 } || head.starts(with: Data("#!".utf8))
            mode = isExecutable ? 0o755 : 0o644
        }
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
}

/// Thread-safe byte counter for progress reporting.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var files = 0
    private var loggedDecile = 0
    private let total: UInt64
    private let totalFiles: Int
    private let uid: String
    private let callback: @Sendable (UpdateProgress) -> Void

    init(total: UInt64, files: Int, uid: String, report: @escaping @Sendable (UpdateProgress) -> Void) {
        self.total = total
        self.totalFiles = files
        self.uid = uid
        self.callback = report
    }

    func add(_ size: UInt64) {
        lock.lock()
        bytes += size
        files += 1
        // Log every 10%, not every file.
        let decile = total == 0 ? 10 : Int(bytes * 10 / total)
        let logDecile = decile > loggedDecile
        if logDecile { loggedDecile = decile }
        let (doneBytes, doneFiles) = (bytes, files)
        lock.unlock()
        if logDecile {
            Log.info(.gameUpdate, "progress", nil, ["uid": uid, "percent": decile * 10, "bytes": doneBytes, "files": doneFiles])
        }
        report()
    }

    func report() {
        lock.lock()
        let snapshot = UpdateProgress(completedBytes: bytes, totalBytes: total, completedFiles: files, totalFiles: totalFiles)
        lock.unlock()
        callback(snapshot)
    }
}

/// Which processes are running from inside a folder, without AppKit.
public enum RunningProcesses {
    public static func inside(_ folder: URL) -> [pid_t] {
        let prefix = folder.standardizedFileURL.path + "/"
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path.hasPrefix(prefix)
        }
    }
}

/// Waypoint's own record of builds it installed. Battle.net's product.db is
/// left alone; this overrides it when newer. For games Waypoint installed
/// itself it's the only record, so it also keeps where and how.
public struct InstalledBuild: Codable, Sendable, Equatable {
    public var buildConfig: String
    public var version: String
    public var productCode: String?
    public var installPath: String?
    public var region: String?
    public var textLanguage: String?
    public var tagString: String?

    public init(buildConfig: String, version: String, install: ProductInstall? = nil) {
        self.buildConfig = buildConfig
        self.version = version
        productCode = install?.productCode
        installPath = install?.installPath
        region = install?.region
        textLanguage = install?.textLanguage
        tagString = install?.tagString
    }

    /// The install this record describes, if it has enough to stand alone.
    func install(uid: String) -> ProductInstall? {
        guard let productCode, let installPath else { return nil }
        return ProductInstall(uid: uid, productCode: productCode, installPath: installPath, region: region,
                              textLanguage: textLanguage, version: version, buildConfig: buildConfig,
                              tagString: tagString)
    }
}

public struct InstallStateStore: Sendable {
    public var file: URL

    public init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint/installs.json")) {
        self.file = file
    }

    public func load() -> [String: InstalledBuild] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: InstalledBuild].self, from: data)) ?? [:]
    }

    public func record(uid: String, _ build: InstalledBuild) throws {
        var all = load()
        all[uid] = build
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
    }

    /// Games Waypoint installed itself, which Battle.net doesn't know about.
    public func standaloneInstalls() -> [ProductInstall] {
        load().sorted { $0.key < $1.key }.compactMap { uid, build in build.install(uid: uid) }
    }

    /// Applies what Waypoint installed on top of what Battle.net recorded,
    /// unless Battle.net has since installed something newer.
    public func apply(to install: ProductInstall) -> ProductInstall {
        guard let build = load()[install.uid] else { return install }
        if let theirs = install.version, Self.compare(theirs, build.version) == .orderedDescending { return install }
        var updated = install
        updated.buildConfig = build.buildConfig
        updated.version = build.version
        return updated
    }

    /// Compares dotted version strings numerically (`36.6.3.253932`).
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
