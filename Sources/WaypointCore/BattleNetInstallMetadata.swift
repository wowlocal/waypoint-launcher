import Foundation
import Darwin

/// Battle.net's Locate reads a ProductInstall from `<root>/.product.db`.
/// Shared WoW roots still have just one such file; each edition needs its
/// own entry in the Agent's central database as well. Fill missing records
/// and synchronize completed HighRes selections without replacing other
/// state or unknown fields written by the Agent.
public enum BattleNetInstallMetadata {
    @discardableResult
    public static func repair(store: InstallStateStore = InstallStateStore(),
                              agentDatabase: URL = ProductDB.agentDatabaseURL) throws -> Int {
        try repair(installs: store.standaloneInstalls(), agentDatabase: agentDatabase,
                   ensureNotRunning: BattleNet.ensureNotRunning)
    }

    @discardableResult
    static func repair(installs: [ProductInstall], agentDatabase: URL,
                       ensureNotRunning: () throws -> Void) throws -> Int {
        try ensureNotRunning()
        // Do not create Battle.net infrastructure on Macs without the Agent.
        let original = FileManager.default.fileExists(atPath: agentDatabase.path) ? try Data(contentsOf: agentDatabase) : nil
        var registeredUIDs = Set(try original.map(ProductDB.parseDatabase)?.map(\.uid) ?? [])
        var database = original ?? Data()
        var added = 0
        for install in installs.sorted(by: { $0.uid < $1.uid }) {
            guard install.platform == .macOS, let product = InstallableProduct.forProduct(install.productCode),
                  product.supportedPlatforms.contains(.macOS),
                  let build = install.buildConfig, build.count == 32, build.allSatisfy(\.isHexDigit),
                  let version = install.version, !version.isEmpty,
                  GameCatalog.game(for: install).isInstalled else { continue }
            try install.platform.validate(install: install)
            let root = URL(fileURLWithPath: install.installPath)
            if !product.isContainerless {
                guard let text = try? String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8),
                      BPSV(text).rows.contains(where: {
                          $0["Product"] == install.productCode && $0["Build Key"] == build && $0["Active"] == "1"
                      }) else { continue }
            }
            let record = encode(install, subfolder: product.flavorFolder ?? "")
            try ensureNotRunning()
            if GameCatalog.family(for: install.productCode) == .worldOfWarcraft,
               try prepareDataDirectory(root.appendingPathComponent("Data")) { added += 1 }
            if try create(record, at: root.appendingPathComponent(".product.db")) {
                added += 1
                Log.notice(.install, "battlenet_folder_record_repaired", nil, ["uid": install.uid, "path": root.path])
            } else {
                let file = root.appendingPathComponent(".product.db")
                let before = try Data(contentsOf: file)
                let after = try updatingContentSelection(before, for: install)
                if after != before {
                    try ensureNotRunning()
                    guard try Data(contentsOf: file) == before else { throw UpdateError.storageChanged }
                    try after.write(to: file, options: .atomic)
                    added += 1
                }
            }
            if original != nil, registeredUIDs.insert(install.uid).inserted {
                var writer = ProtoWriter()
                writer.bytes(1, record)
                database.append(writer.data)
                added += 1
            }
            let updated = try updatingContentSelection(database, for: install)
            if updated != database { database = updated; added += 1 }
        }
        if let original, database != original {
            try ensureNotRunning()
            // Abort if another writer changed the database during validation.
            guard try Data(contentsOf: agentDatabase) == original else {
                throw TACTError.malformed("Battle.net installation records changed during repair; retry when Battle.net is closed")
            }
            try database.write(to: agentDatabase, options: .atomic)
            Log.notice(.install, "battlenet_install_list_repaired")
        }
        return added
    }

    /// Only a completed, matching build can advertise HighRes. The Agent
    /// derives its desired selection from UserSettings.additional_tags (9),
    /// not just the cached active_tag_string (17). Agent-written folder
    /// records can be Database envelopes containing several WoW editions.
    static func updatingContentSelection(_ data: Data, for completed: ProductInstall) throws -> Data {
        guard completed.platform == .macOS,
              GameCatalog.family(for: completed.productCode) == .worldOfWarcraft,
              !InstallContent.needsUpdate(completed), let tags = completed.tagString else { return data }
        func updateRecord(_ record: Data) throws -> Data {
            guard let current = try? ProductDB.parseInstallFile(record),
                  current.isSameInstallation(as: completed) else { return record }
            let settingsUpdated = try ProtoReader(record).mappingBytes(3) { settings in
                let additional = try ProtoReader(settings).fields()[9]?.first?.string ?? ""
                let selected = additional.split(whereSeparator: \.isWhitespace).contains { $0 == "HighRes" || $0 == "HighRes?" }
                let value = selected ? additional : additional + (additional.isEmpty ? "" : " ") + "HighRes"
                return try ProtoReader(settings).replacingBytes(9, with: Data(value.utf8))
            }
            // The Agent can still cache the previous build or languages.
            // Set its desired package now, but do not claim that its cached
            // active build already has the new selection.
            guard current.buildConfig == completed.buildConfig, let currentTags = current.tagString,
                  InstallContent.tags(for: current, from: currentTags) == tags else { return settingsUpdated }
            return try ProtoReader(settingsUpdated).mappingBytes(4) { cached in
                try ProtoReader(cached).mappingBytes(1) { state in
                    try ProtoReader(state).replacingBytes(17, with: Data(tags.utf8))
                }
            }
        }
        if (try? ProductDB.parseInstallFile(data)) != nil { return try updateRecord(data) }
        // Leave opaque or unfamiliar folder files untouched.
        guard (try? ProductDB.parseDatabase(data))?.isEmpty == false else { return data }
        return try ProtoReader(data).mappingBytes(1, updateRecord)
    }

    /// Match the Agent's own CASC folder mode. Its adoption pass applies a
    /// regular-file mode (0666) to existing 0755 data directories, stripping
    /// traversal and then requesting administrator access. Avoid that pass by
    /// using the native install mode throughout the data tree. Only change
    /// the two known legacy modes on directories owned by this user. Managed
    /// archives, indexes and shmem also need the Agent's 0666 file mode. Stop
    /// at symlinks, other owners and deliberately restricted directories;
    /// unrelated files and files outside the CASC data tree stay alone.
    @discardableResult
    static func prepareDataDirectory(_ directory: URL) throws -> Bool {
        var pending = [directory]
        var changed = false
        let storage = directory.appendingPathComponent("data").standardizedFileURL
        while let next = pending.popLast() {
            var info = stat()
            guard lstat(next.path, &info) == 0, info.st_uid == geteuid() else { continue }
            let mode = info.st_mode & 0o7777
            if info.st_mode & S_IFMT == S_IFREG {
                guard next.deletingLastPathComponent().standardizedFileURL == storage else { continue }
                let name = next.lastPathComponent
                let archive = name.wholeMatch(of: /data\.\d{3}/) != nil
                let index = name.count == 14 && name.hasSuffix(".idx") && name.prefix(10).allSatisfy(\.isHexDigit)
                // Atomic index/shmem writes use 0600; archive creation uses
                // 0644. Preserve restrictive archive modes and unrelated files.
                guard (archive && mode == 0o644)
                    || ((index || name == "shmem") && [mode_t(0o600), mode_t(0o644)].contains(mode)) else { continue }
                guard chmod(next.path, 0o666) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                changed = true
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard [mode_t(0o777), mode_t(0o755), mode_t(0o666)].contains(mode) else { continue }
            if mode != 0o777 {
                guard chmod(next.path, 0o777) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                changed = true
            }
            // Repair before enumerating: an Agent-modified 0666 directory
            // cannot be traversed until its execute bits are restored.
            pending += try FileManager.default.contentsOfDirectory(at: next, includingPropertiesForKeys: nil)
        }
        if changed { Log.notice(.install, "battlenet_data_directory_repaired", nil, ["path": directory.path]) }
        return changed
    }

    /// Called only after a completed install/update has been recorded. The
    /// startup repair also handles older installs and the shared Agent list.
    static func recordCompletedInstall(_ install: ProductInstall, build: InstalledBuild, store: InstallStateStore) {
        guard install.platform == .macOS else { return }
        do {
            try BattleNet.ensureNotRunning()
            guard let product = InstallableProduct.forProduct(install.productCode) else { return }
            var completed = install
            completed.version = build.version
            completed.buildConfig = build.buildConfig
            completed.tagString = build.tagString ?? install.tagString
            guard GameCatalog.game(for: completed).isInstalled,
                  let key = completed.buildConfig, key.count == 32, key.allSatisfy(\.isHexDigit) else { return }
            _ = try create(encode(completed, subfolder: product.flavorFolder ?? ""),
                           at: URL(fileURLWithPath: install.installPath).appendingPathComponent(".product.db"))
            // Isolated CLI/test stores must never export to the user's Agent.
            if store.file.standardizedFileURL == InstallStateStore().file.standardizedFileURL {
                try repair(store: store)
            }
        } catch {
            // A failed metadata export must not turn a completed download into
            // a failed job. Startup retries from the durable install record.
            Log.warning(.install, "battlenet_folder_record_failed", nil, ["uid": install.uid, "error": error])
        }
    }

    /// Publish a complete record atomically, without replacing an existing one.
    private static func create(_ data: Data, at destination: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".waypoint-metadata-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
        if errno == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// The on-disk Agent message, not the central Database envelope. Defaults
    /// match Agent-created macOS installations (language flags: text=2, speech=1).
    static func encode(_ install: ProductInstall, subfolder: String) -> Data {
        var writer = ProtoWriter()
        writer.string(1, install.uid)
        writer.string(2, install.productCode)
        writer.message(3) { settings in
            settings.string(1, install.installPath)
            settings.string(2, install.region ?? "us")
            settings.varint(3, 2)
            settings.varint(4, 2)
            settings.varint(5, 3)
            let text = install.textLanguage ?? "enUS", speech = install.speechLanguage ?? text
            settings.string(6, text)
            settings.string(7, speech)
            if GameCatalog.family(for: install.productCode) == .worldOfWarcraft, !InstallContent.needsUpdate(install) {
                settings.string(9, "HighRes")
            }
            for language in Set([text, speech]).sorted() {
                settings.message(8) {
                    $0.string(1, language)
                    $0.varint(2, (language == text ? 2 : 0) | (language == speech ? 1 : 0))
                }
            }
            settings.string(13, subfolder)
        }
        writer.message(4) { cached in
            cached.message(1) { state in
                state.varint(1, 1)
                state.varint(2, 1)
                state.varint(3, 1)
                state.varint(4, 0)
                state.varint(5, 0)
                state.string(7, install.version ?? "")
                state.string(10, "")
                state.string(12, install.buildConfig ?? "")
                state.string(14, install.buildConfig ?? "")
                state.string(17, install.tagString ?? "OSX")
                state.varint(21, 0)
            }
            cached.message(2) { backfill in
                backfill.fixed64(1, 0)
                backfill.varint(2, 0)
                backfill.varint(3, 0)
                backfill.varint(5, 0)
            }
            cached.message(3) { $0.fixed64(1, 0) }
            cached.message(4) { progress in
                progress.fixed64(2, Double(1).bitPattern)
                progress.varint(4, 0)
                progress.varint(5, 0)
                progress.message(6) { $0.string(1, install.buildConfig ?? "") }
            }
        }
        writer.string(6, GameCatalog.family(for: install.productCode) == .worldOfWarcraft ? "wow" : install.productCode)
        writer.varint(7, 0)
        writer.string(8, "{\"user_install_package_settings\":[]}")
        return writer.data
    }
}
