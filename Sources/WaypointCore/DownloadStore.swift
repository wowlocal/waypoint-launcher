import CryptoKit
import Darwin
import Foundation

/// Separate atomic files let independent jobs and app copies update their own
/// checkpoints without overwriting one another's queue.
public struct DownloadStore: Sendable {
    public var directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint/Downloads", isDirectory: true)) {
        self.directory = directory
    }

    func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func read(_ file: URL) throws -> UnfinishedDownload {
        let record = try JSONDecoder().decode(UnfinishedDownload.self, from: Data(contentsOf: file))
        guard record.formatVersion == 1,
              file.standardizedFileURL.resolvingSymlinksInPath() == self.file(for: record.request.key).standardizedFileURL.resolvingSymlinksInPath(),
              record.request.install.installPath.hasPrefix("/") else {
            throw TACTError.malformed("unfinished download record")
        }
        return record
    }

    func save(_ record: UnfinishedDownload) throws {
        try makeDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: file(for: record.request.key), options: .atomic)
    }

    func remove(key: String) throws {
        let file = file(for: key)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func claim(key: String) throws -> DownloadLease {
        try makeDirectory()
        return try DownloadLease(file: file(for: key).deletingPathExtension().appendingPathExtension("lock"))
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
}

enum DownloadStoreError: Error, LocalizedError {
    case inUse, alreadyQueued
    var errorDescription: String? {
        switch self {
        case .inUse: "This download is open in another copy of Waypoint. Quit that copy first."
        case .alreadyQueued: "This game already has an unfinished download. Resume or cancel it first."
        }
    }
}

/// Keep the lock file's inode stable across atomic checkpoint replacements.
final class DownloadLease {
    private let descriptor: Int32

    init(file: URL) throws {
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw DownloadStoreError.inUse }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// Owned by one live job while it is displayed, including while paused.
final class DownloadCheckpoint {
    var record: UnfinishedDownload
    let store: DownloadStore
    private let lease: DownloadLease
    private var lastSave = ContinuousClock.now

    init(record: UnfinishedDownload, store: DownloadStore, lease: DownloadLease) {
        self.record = record
        self.store = store
        self.lease = lease
    }

    func save(progress: UpdateProgress?, keepsMacAwake: Bool, failure: String?, force: Bool) throws {
        guard force || lastSave.duration(to: .now) >= .seconds(1) else { return }
        lastSave = .now
        record.progress = progress
        record.keepsMacAwake = keepsMacAwake
        record.failure = failure
        try store.save(record)
    }

    func remove() throws { try store.remove(key: record.request.key) }
}
