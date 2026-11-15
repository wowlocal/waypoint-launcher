import CryptoKit
import Foundation

/// An add-on Waypoint itself put on disk. Only those have records: every
/// other add-on is recognized again from its folders on each scan, so
/// losing the file loses nothing that matters.
public struct AddOnRecord: Codable, Equatable, Sendable {
    public var ref: AddOnRef
    public var name: String
    public var mainFolder: String
    /// Exactly what the zip installed.
    public var folders: [String]
    public var release: AddOnRelease
    /// Each folder's fingerprint as installed; equal later means nobody
    /// changed it. A folder someone deleted isn't a change: the next update
    /// puts it back.
    public var folderHashes: [String: String]
    /// The main TOC's version as installed: a different one later means
    /// something else updated the add-on, and the record no longer applies.
    public var tocVersion: String?
}

/// Records per AddOns folder, as one JSON file each in Application Support.
/// Nothing is written into the game's folder.
public struct AddOnStore: Sendable {
    public var directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint/AddOns", isDirectory: true)) {
        self.directory = directory
    }

    static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var addOns: String
        var records: [AddOnRecord]
        /// The person said so once (an Update or Install in the sheet):
        /// every add-on Waypoint recognizes here updates on its own.
        var keepsCurrent: Bool?
        /// Add-ons Waypoint recognizes but didn't install, as they were when
        /// first seen: the same version with other files means someone
        /// edited them, and they're left alone.
        var baselines: [String: AddOnBaseline]?
        /// Add-on id → a release an automatic update couldn't install and
        /// won't try again.
        var failedReleases: [String: String]?

        init(addOns: String) {
            (formatVersion, self.addOns, records) = (AddOnStore.formatVersion, addOns, [])
        }

        /// A record this Waypoint can't read is skipped, not the whole
        /// file: the rest, and the say-so, still count.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            addOns = try c.decode(String.self, forKey: .addOns)
            keepsCurrent = try c.decodeIfPresent(Bool.self, forKey: .keepsCurrent)
            records = (try c.decode([Lenient].self, forKey: .records)).compactMap(\.record)
            baselines = try? c.decodeIfPresent([String: AddOnBaseline].self, forKey: .baselines)
            failedReleases = try? c.decodeIfPresent([String: String].self, forKey: .failedReleases)
        }

        private struct Lenient: Decodable {
            var record: AddOnRecord?
            init(from decoder: Decoder) throws { record = try? AddOnRecord(from: decoder) }
        }

        var isEmpty: Bool {
            records.isEmpty && keepsCurrent != true && (baselines ?? [:]).isEmpty && (failedReleases ?? [:]).isEmpty
        }
    }

    static func key(for addOns: URL) -> String {
        let path = addOns.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func file(for addOns: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: addOns)).appendingPathExtension("json")
    }

    private static func path(_ addOns: URL) -> String { addOns.resolvingSymlinksInPath().standardizedFileURL.path }

    private func read(_ addOns: URL) -> File? {
        guard let data = try? Data(contentsOf: file(for: addOns)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.formatVersion == Self.formatVersion,
              file.addOns == Self.path(addOns) else { return nil }
        return file
    }

    /// Reads, changes and writes back the folder's file (removed when empty).
    private func change(_ addOns: URL, _ body: (inout File) -> Void) throws {
        var contents = read(addOns) ?? File(addOns: Self.path(addOns))
        body(&contents)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = file(for: addOns)
        if contents.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(contents).write(to: file, options: .atomic)
    }

    /// Empty when there's no file, or it's unreadable or from a newer Waypoint.
    public func load(for addOns: URL) -> [AddOnRecord] { read(addOns)?.records ?? [] }

    public func save(_ records: [AddOnRecord], for addOns: URL) throws {
        try change(addOns) { file in
            file.records = records
            // Waypoint's own install is the add-on's record now.
            for record in records { file.baselines?[record.ref.description] = nil }
        }
    }

    public func keepsCurrent(for addOns: URL) -> Bool { read(addOns)?.keepsCurrent == true }

    public func setKeepsCurrent(_ on: Bool, for addOns: URL) throws {
        try change(addOns) { $0.keepsCurrent = on ? true : nil }
    }

    public func baselines(for addOns: URL) -> [String: AddOnBaseline] { read(addOns)?.baselines ?? [:] }

    public func setBaselines(_ baselines: [String: AddOnBaseline], for addOns: URL) throws {
        try change(addOns) { $0.baselines = baselines.isEmpty ? nil : baselines }
    }

    public func failedReleases(for addOns: URL) -> [String: String] { read(addOns)?.failedReleases ?? [:] }

    public func setFailedRelease(_ release: String?, for id: String, in addOns: URL) throws {
        try change(addOns) { file in
            var failed = file.failedReleases ?? [:]
            failed[id] = release
            file.failedReleases = failed.isEmpty ? nil : failed
        }
    }

    /// Held while folders are swapped: another copy of Waypoint, or
    /// `waypoint-cli`, waits its turn rather than interleave.
    func lock(for addOns: URL) throws -> DownloadLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            return try DownloadLease(file: directory.appendingPathComponent(Self.key(for: addOns)).appendingPathExtension("lock"))
        } catch DownloadStoreError.inUse {
            throw AddOnError.busy
        }
    }
}

/// How an add-on Waypoint didn't install looked when first seen.
public struct AddOnBaseline: Codable, Equatable, Sendable {
    public var tocVersion: String?
    public var folderHashes: [String: String]
}

public enum AddOnError: Error, Equatable, LocalizedError {
    case busy
    case changedLocally
    case conflict(folder: String, owner: String)
    case notSafe(String)
    case notEnoughSpace
    case checksum
    case unknownGame
    /// The game is open or starting: automatic updates wait for it.
    case gameRunning
    /// Putting things back failed too; nothing more was moved.
    case incomplete(name: String)

    public var errorDescription: String? {
        switch self {
        case .busy: "Another copy of Waypoint is changing these add-ons. Try again in a moment."
        case .changedLocally: "You changed this add-on’s files."
        case .conflict(let folder, let owner): "It includes the folder “\(folder)”, which belongs to \(owner)."
        case .notSafe(let folder): "Waypoint doesn’t change “\(folder)”, which was put there by hand."
        case .notEnoughSpace: "There isn’t enough free space for this add-on."
        case .checksum: "The download was damaged. Try again."
        case .unknownGame: "Waypoint can’t update add-ons for this version of the game."
        case .gameRunning: "Waiting for the game to quit."
        case .incomplete(let name): "Couldn’t finish updating \(name). The previous version is in the Trash."
        }
    }
}
