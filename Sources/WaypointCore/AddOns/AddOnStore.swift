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
    }

    static func key(for addOns: URL) -> String {
        let path = addOns.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func file(for addOns: URL) -> URL {
        directory.appendingPathComponent(Self.key(for: addOns)).appendingPathExtension("json")
    }

    /// Empty when there's no file, or it's unreadable or from a newer Waypoint.
    public func load(for addOns: URL) -> [AddOnRecord] {
        guard let data = try? Data(contentsOf: file(for: addOns)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.formatVersion == Self.formatVersion,
              file.addOns == addOns.resolvingSymlinksInPath().standardizedFileURL.path else { return [] }
        return file.records
    }

    public func save(_ records: [AddOnRecord], for addOns: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = file(for: addOns)
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let path = addOns.resolvingSymlinksInPath().standardizedFileURL.path
        try encoder.encode(File(formatVersion: Self.formatVersion, addOns: path, records: records)).write(to: file, options: .atomic)
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
