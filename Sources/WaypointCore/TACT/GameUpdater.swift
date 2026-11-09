import CryptoKit
import Darwin
import Foundation

public struct UpdateCheck: Sendable {
    public var installedBuild: String?
    public var installedVersion: String?
    public var latest: ProductVersion

    /// Only a build change is an update. An installation whose build is the
    /// live one is up to date, whatever optional content it was installed
    /// with: Battle.net reports the same, and its own cleanup would discard
    /// packages the install's tags don't select.
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
    /// The install's languages are new (an install, or a language change).
    public var setsLanguages = false
    /// A language change: the tags it replaces.
    public var replacedTags: String?

    public var downloadSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { files.isEmpty && deletions.isEmpty }
}

public struct UpdateProgress: Sendable, Equatable, Codable {
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    public var completedFiles: Int
    public var totalFiles: Int

    public var fraction: Double { totalBytes == 0 ? 1 : Double(completedBytes) / Double(totalBytes) }
}

public enum UpdateError: Error, CustomStringConvertible {
    case gameRunning
    /// Battle.net (or, with `agentOnly`, just its background Agent) is running.
    case battleNetRunning(agentOnly: Bool)
    case unsupported(String)
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case unsafePath(String)
    /// Another install or update is writing to this local storage.
    case storageBusy(String)
    /// Another update wrote to the storage while it was being checked for cleaning.
    case storageChanged
    /// A journal appeared after planning; retrying the plan resumes its writer.
    case unfinishedStorage(String)
    /// Some indexes were deliberately left untouched because they could not be repaired safely.
    case indexRepairIncomplete(String, [String])

    public var description: String {
        switch self {
        case .gameRunning: "Quit the game before updating"
        case .battleNetRunning(agentOnly: false):
            "Quit Battle.net first, so the two don't write to the same game files at the same time"
        case .battleNetRunning(agentOnly: true):
            "Battle.net's Agent is still running in the background. Try again once it has quit (Activity Monitor shows it as “Agent”)"
        case .unsupported(let name): "Updating \(name) is not supported yet"
        case .notEnoughSpace(let needed, let available):
            "Not enough disk space: need \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file))"
        case .unsafePath(let path): "Refusing to write outside the game folder: \(path)"
        case .storageBusy(let path): "Another install or update is writing to \(path). Try again once it has finished"
        case .storageChanged: "Another update changed the game data while it was being checked"
        case .unfinishedStorage(let path): "An unfinished install or update needs to finish in \(path). Resume it or try Verify Files again"
        case .indexRepairIncomplete(let path, let files):
            "Could not repair \(files.count) storage index file(s) in \(path). Use Battle.net's Scan and Repair"
        }
    }
}

/// Updates a game whose files are installed loose in its folder (Hearthstone),
/// the way the Battle.net Agent does: compare the old and new install
/// manifests, download what changed from the CDN, verify every file against
/// its content hash, then swap the files in.
///
/// Games that keep their data in local CASC storage go through `GameUpdate`,
/// which uses this for their loose files.
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
    /// With `languages`, the install switches to them: their files come, the
    /// old languages' go. `only` limits the plan to some paths (for partial
    /// downloads and tests).
    public func plan(target requested: ProductVersion? = nil, verify: Bool = false, languages: GameLanguages? = nil,
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
        try install.platform.validate(install: install)
        let installedTags = install.tagString ?? TagLanguages.replacing(in: "\(install.platform.manifestTag) \(region.launchOptionValue)", with: install.languages)
        let planned = languages.map { install.with($0, tags: installedTags) } ?? install
        let tags = planned.tagString ?? installedTags

        let buildConfig = try await config(target.buildConfig, cdn)
        let cdnConfig = try await config(target.cdnConfig, cdn)
        let manifest = try await installManifest(buildConfig, cdn)
        let wanted = manifest.select(tagString: tags).filter { only?($0.path) ?? true }
        log("Build \(target.name): \(wanted.count) files for this install")
        Log.info(.gameUpdate, "plan_started", nil, ["uid": install.uid, "path": install.installPath, "from": install.version ?? "none",
                                                     "to": target.name, "verify": verify, "files": wanted.count, "filtered": only != nil])

        // What the installed build had in the installed languages, so
        // unchanged files can be skipped without hashing.
        var previous: [String: Data]?
        if !verify, let installed = install.buildConfig {
            if installed == target.buildConfig, tags == installedTags {
                previous = Dictionary(wanted.map { ($0.path, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
            } else {
                do {
                    let oldManifest = try await installed == target.buildConfig ? manifest : installManifest(config(installed, cdn), cdn)
                    previous = Dictionary(oldManifest.select(tagString: installedTags).filter { only?($0.path) ?? true }
                                            .map { ($0.path, $0.contentKey) },
                                          uniquingKeysWith: { a, _ in a })
                } catch {
                    if NetworkRetry.isCancellation(error) { throw error }
                    try Task.checkCancellation()
                    log("Installed build's manifest is gone from the CDN; checking files by hash")
                    Log.warning(.gameUpdate, "old_manifest_missing", "falling back to hashing local files", ["uid": install.uid, "build_config": installed])
                }
            }
        }

        try Task.checkCancellation()
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
            return UpdatePlan(install: planned, target: target, cdn: cdn, files: [], deletions: deletions,
                              setsLanguages: tags != installedTags || install.buildConfig == nil,
                              replacedTags: tags != installedTags ? installedTags : nil)
        }

        log("Resolving \(changed.count) files")
        guard let encodingKey = buildConfig.encodedKey("encoding") else { throw TACTError.malformed("build config (no encoding)") }
        let encoding = try EncodingTable(try await cdn.decoded(encodingKey), wanted: Set(changed.map(\.contentKey)))
        var files: [UpdatePlan.File] = try changed.map { entry in
            guard let encoded = encoding.entries[entry.contentKey] else { throw TACTError.notFound("encoding entry for \(entry.path)") }
            return UpdatePlan.File(path: entry.path, contentKey: entry.contentKey, encodedKey: encoded.encodedKey,
                                   size: entry.size, location: nil)
        }

        let locations = try await locate(Set(files.map(\.encodedKey)), archives: cdnConfig["archives"], cdn)
        for i in files.indices { files[i].location = locations[files[i].encodedKey] }
        let plan = UpdatePlan(install: planned, target: target, cdn: cdn, files: files, deletions: deletions,
                              setsLanguages: tags != installedTags || install.buildConfig == nil,
                              replacedTags: tags != installedTags ? installedTags : nil)
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
        guard plan.install.isSameInstallation(as: install) else { throw TACTError.malformed("Update plan belongs to another installation") }
        try Task.checkCancellation()
        let started = Date()
        guard RunningProcesses.inside(root).isEmpty else {
            Log.warning(.gameUpdate, "apply_refused", "game is running", ["uid": install.uid])
            throw UpdateError.gameRunning
        }
        try BattleNet.ensureNotRunning()
        let fm = FileManager.default
        try install.platform.claim(install: install)
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

        // Everything is verified; swap it in (unless Battle.net started meanwhile:
        // the staged files stay, and the next try picks them up).
        // Observe pause here, then finish the synchronous commit as a whole.
        try Task.checkCancellation()
        guard RunningProcesses.inside(root).isEmpty else { throw UpdateError.gameRunning }
        try BattleNet.ensureNotRunning()
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
            try store.record(install: plan.install, InstalledBuild(buildConfig: plan.target.buildConfig, version: plan.target.name,
                                                              install: plan.install, chosenLanguages: plan.setsLanguages,
                                                              replacedTags: plan.replacedTags))
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
            if index % 256 == 0 { try Task.checkCancellation() }
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
        try Task.checkCancellation()
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
        return try InstallManifest(try await cdn.decoded(key))
    }

    private func locate(_ wanted: Set<Data>, archives: [String], _ cdn: CDNClient) async throws -> [Data: ArchiveLocation] {
        let files = try await ArchiveIndexes.fetch(archives, cdn: cdn, localDirectory: root.appendingPathComponent("Data/indices"), concurrency: 8)
        let found = try ArchiveIndexes.locate(Set(wanted.compactMap(Key16.init)), archives: archives, indexFiles: files)
        return Dictionary(uniqueKeysWithValues: found.map { ($0.key.data, $0.value) })
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
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
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
        let prefix = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return executables().filter { process in
            if URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path.hasPrefix(prefix) { return true }
            guard WineProcesses.isLoader(process.path), let cwd = WineProcesses.currentDirectory(of: process.pid) else { return false }
            let path = cwd.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            return path.hasPrefix(prefix)
        }.map(\.pid)
    }

    /// Every process's executable path (those we're allowed to see).
    public static func executables() -> [(pid: pid_t, path: String)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return (pid, String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}

/// Waypoint's own record of builds it installed. This overrides Battle.net's
/// build details when newer and keeps the paths and install options, so the
/// library remains available independently of the Agent's database.
public struct InstalledBuild: Codable, Sendable, Equatable {
    /// Omitted by older/native records; those are macOS installations.
    public var platform: InstallPlatform?
    public var buildConfig: String
    public var version: String
    public var productCode: String?
    public var installPath: String?
    public var region: String?
    public var textLanguage: String?
    public var speechLanguage: String?
    public var tagString: String?
    /// Compatibility name: Waypoint picked these tags (languages or content),
    /// so they win over what Battle.net recorded for the same build…
    public var chosenLanguages: Bool?
    /// …as long as Battle.net's records still show the tags they replaced
    /// (or none): a language picked in Battle.net afterwards wins.
    public var replacedTags: String?

    public init(buildConfig: String, version: String, install: ProductInstall? = nil,
                chosenLanguages: Bool = false, replacedTags: String? = nil) {
        self.buildConfig = buildConfig
        platform = install?.platform == .windows ? .windows : nil
        self.version = version
        self.chosenLanguages = chosenLanguages ? true : nil
        self.replacedTags = chosenLanguages ? replacedTags : nil
        productCode = install?.productCode
        installPath = install?.installPath
        region = install?.region
        textLanguage = install?.textLanguage
        speechLanguage = install?.speechLanguage
        tagString = install?.tagString
    }

    /// The install this record describes, if it has enough to stand alone.
    public func install(uid: String) -> ProductInstall? {
        guard let productCode, let installPath else { return nil }
        let platform = platform ?? (uid.hasSuffix("@windows") ? .windows : .macOS)
        let uid = platform == .windows && uid.hasSuffix("@windows") ? String(uid.dropLast(8)) : uid
        return ProductInstall(uid: uid, productCode: productCode, installPath: installPath, region: region,
                              textLanguage: textLanguage, speechLanguage: speechLanguage, version: version,
                              buildConfig: buildConfig, tagString: tagString, platform: platform)
    }
}

public struct InstallStateStore: Sendable {
    public var file: URL
    /// Older Waypoint versions can rewrite the native file. Keep Windows
    /// records out of that file so a downgrade cannot reinterpret their paths.
    public var windowsFile: URL { file.deletingPathExtension().appendingPathExtension("windows.json") }

    public init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint/installs.json")) {
        self.file = file
    }

    public func load() -> [String: InstalledBuild] {
        func read(_ url: URL) -> [String: InstalledBuild] {
            guard let data = try? Data(contentsOf: url),
                  let records = try? JSONDecoder().decode([String: InstalledBuild].self, from: data)
            else { return [:] }
            return records
        }
        var all = read(file)
        // Up to 0.4.9 Waypoint filed HotS, D3 and Anniversary under their
        // product code, not Battle.net's uid, so a game Battle.net also
        // knew showed up twice. The next write saves the new key.
        for (uid, build) in all {
            guard let code = build.productCode, uid == code,
                  let product = InstallableProduct.forProduct(code), product.uid != uid,
                  all[product.uid] == nil
            else { continue }
            all[product.uid] = build
            all[uid] = nil
        }
        for (key, var build) in read(windowsFile) {
            build.platform = .windows
            let uid = key.hasSuffix("@windows") ? String(key.dropLast(8)) : key
            all[InstallPlatform.windows.installKey(uid: uid)] = build
        }
        return all
    }

    /// Compatibility API for existing native callers. Windows writers must
    /// supply an installation, rather than guess its platform from a bare uid.
    public func record(uid: String, _ build: InstalledBuild) throws {
        guard !uid.contains("@"), build.platform != .windows,
              InstallPlatform.from(tags: build.tagString) != .windows
        else { throw TACTError.malformed("Windows build records require their installation identity") }
        try record(key: uid, platform: .macOS, build)
    }

    public func record(install: ProductInstall, _ build: InstalledBuild) throws {
        guard !install.uid.contains("@") else { throw TACTError.malformed("Invalid install uid") }
        var build = build
        build.platform = install.platform == .windows ? .windows : nil
        build.productCode = install.productCode
        build.installPath = install.installPath
        build.region = build.region ?? install.region
        build.textLanguage = build.textLanguage ?? install.textLanguage
        build.speechLanguage = build.speechLanguage ?? install.speechLanguage
        build.tagString = build.tagString ?? install.tagString
        try record(key: install.key, platform: install.platform, build)
        BattleNetInstallMetadata.recordCompletedInstall(install, build: build, store: self)
    }

    /// Writers load, change and save the files: one at a time, or a download
    /// finishing during an uninstall could lose the other's change.
    private static let writeLock = NSLock()

    private func record(key uid: String, platform: InstallPlatform, _ build: InstalledBuild) throws {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        var all = load()
        var build = build
        if let old = all[uid], old.chosenLanguages == true {
            if build.chosenLanguages == true {
                // Changed again: Battle.net's records still show what they did.
                build.replacedTags = old.replacedTags
            } else if old.tagString == build.tagString {
                // An update in the same languages keeps them Waypoint's choice.
                build.chosenLanguages = true
                build.replacedTags = old.replacedTags
            }
        }
        all[uid] = build
        try save(all, platform: platform)
    }

    /// Forgets an uninstalled game. A record of another copy elsewhere (a
    /// test install) stays.
    public func remove(_ install: ProductInstall) throws {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        var all = load()
        guard let build = all[install.key], (build.platform ?? .macOS) == install.platform else { return }
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        if let path = build.installPath, standardized(path) != standardized(install.installPath) { return }
        all[install.key] = nil
        try save(all, platform: install.platform)
    }

    /// Writes one platform's file with that platform's records.
    private func save(_ records: [String: InstalledBuild], platform: InstallPlatform) throws {
        let destination = platform == .windows ? windowsFile : file
        let records = records.filter { ($0.value.platform ?? .macOS) == platform }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: destination, options: .atomic)
    }

    /// Games Waypoint installed itself, which Battle.net doesn't know about.
    public func standaloneInstalls() -> [ProductInstall] {
        load().sorted { $0.key < $1.key }.compactMap { uid, build in build.install(uid: uid) }
    }

    /// Applies what Waypoint installed on top of what Battle.net recorded,
    /// unless Battle.net has since installed something newer: the build, and
    /// the languages when Waypoint changed them.
    public func apply(to install: ProductInstall) -> ProductInstall {
        guard let build = load()[install.key], (build.platform ?? .macOS) == install.platform else { return install }
        // Another copy of the same game (a test install elsewhere) isn't this one.
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        if let path = build.installPath, standardized(path) != standardized(install.installPath) { return install }
        if let theirs = install.version, Self.compare(theirs, build.version) == .orderedDescending { return install }
        var updated = install
        updated.buildConfig = build.buildConfig
        updated.version = build.version
        if build.chosenLanguages == true, let tags = build.tagString,
           install.tagString == nil || install.tagString == build.replacedTags {
            updated.tagString = tags
            updated.textLanguage = build.textLanguage ?? updated.textLanguage
            updated.speechLanguage = build.speechLanguage ?? updated.speechLanguage
        }
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
