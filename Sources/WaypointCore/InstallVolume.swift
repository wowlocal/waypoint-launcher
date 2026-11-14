import Foundation

/// The volume a game would be installed on, as the install sheet checks
/// it, and the free-space reading the installers go by.
public struct InstallVolume: Equatable, Sendable {
    /// Its name in the Finder ("T7").
    public var name: String
    /// The startup disk, which messages don't name.
    public var isStartupDisk: Bool
    /// Bytes free for a game, or nil when that can't be read.
    public var availableCapacity: UInt64?
    public var isReadOnly: Bool
    /// False for a network volume.
    public var isLocal: Bool
    public var isCaseSensitive: Bool
    /// The nearest folder there that exists, when this user can't write to
    /// it (its name).
    public var unwritableFolder: String?
    /// The file system, as `volumeTypeName` gives it: "apfs", "hfs", "exfat", "msdos"…
    public var format: String?

    /// Room kept free beyond the download: the most the installers keep
    /// (games with local storage; loose files keep half as much).
    public static let headroom: UInt64 = 1 << 30

    public init(name: String, isStartupDisk: Bool = false, availableCapacity: UInt64?, isReadOnly: Bool = false,
                isLocal: Bool = true, isCaseSensitive: Bool = false, unwritableFolder: String? = nil, format: String? = "apfs") {
        self.name = name
        self.isStartupDisk = isStartupDisk
        self.availableCapacity = availableCapacity
        self.isReadOnly = isReadOnly
        self.isLocal = isLocal
        self.isCaseSensitive = isCaseSensitive
        self.unwritableFolder = unwritableFolder
        self.format = format
    }

    private var quotedName: String { "“\(name)”" }

    /// Why a game can't be installed here, in one line; nil when it can.
    /// `download`: what the install downloads, once known.
    public func problem(download: UInt64?, platform: InstallPlatform) -> String? {
        if !isLocal { return "\(quotedName) isn’t a drive connected to this Mac." }
        if isReadOnly { return isStartupDisk ? "This location is read-only." : "\(quotedName) is read-only." }
        if let unwritableFolder { return "You don’t have permission to save in “\(unwritableFolder)”." }
        // Wine copes with case-sensitive names; Blizzard's Mac games don't.
        if isCaseSensitive, platform == .macOS {
            return "\(isStartupDisk ? "The startup disk" : quotedName) is case-sensitive, which Blizzard games don’t support."
        }
        if let download, let availableCapacity, availableCapacity < download + Self.headroom {
            // In whole gigabytes, rounded up: “needs 52 GB”, not “51.07 GB”.
            let gigabytes = (download + Self.headroom + 999_999_999) / 1_000_000_000
            let needed = ByteCountFormatter.string(fromByteCount: Int64(clamping: gigabytes * 1_000_000_000), countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: Int64(clamping: availableCapacity), countStyle: .file)
            return "Not enough space\(isStartupDisk ? "" : " on \(quotedName)"): needs \(needed), \(free) available."
        }
        return nil
    }

    /// "812 GB available on “T7”", or on the startup disk "812 GB available".
    public var summary: String? {
        guard let availableCapacity else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: Int64(clamping: availableCapacity), countStyle: .file)
        return isStartupDisk ? "\(free) available" : "\(free) available on \(quotedName)"
    }

    /// A file system games work on, but not as well.
    public var caution: String? {
        switch format {
        case "exfat": "Formatted as ExFAT. Games run best from APFS."
        case "msdos": "Formatted as MS-DOS (FAT). Games run best from APFS."
        default: nil
        }
    }

    /// The volume `folder` is on, or would be: measured at the nearest
    /// folder that exists. Throws `UpdateError.driveNotConnected` when it is
    /// under `/Volumes/<name>` and that drive isn't connected; nil when the
    /// volume can't be read. Reads the disk: off the main thread.
    public static func read(at folder: URL, fileManager fm: FileManager = .default) throws -> InstallVolume? {
        try ensureConnected(folder.path, fileManager: fm)
        let existing = nearestExisting(folder, fileManager: fm)
        guard let values = try? existing.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
            .volumeSupportsCaseSensitiveNamesKey, .volumeTypeNameKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        return InstallVolume(name: values.volumeLocalizedName ?? values.volumeName ?? existing.lastPathComponent,
                             isStartupDisk: values.volumeIsRootFileSystem ?? false,
                             availableCapacity: capacity(importantUsage: values.volumeAvailableCapacityForImportantUsage,
                                                         available: values.volumeAvailableCapacity),
                             isReadOnly: values.volumeIsReadOnly ?? false,
                             isLocal: values.volumeIsLocal ?? true,
                             isCaseSensitive: values.volumeSupportsCaseSensitiveNames ?? false,
                             unwritableFolder: fm.isWritableFile(atPath: existing.path) ? nil : fm.displayName(atPath: existing.path),
                             format: values.volumeTypeName)
    }

    /// The free space at `url`, for the installers' space checks: measured
    /// at the nearest folder that exists, since a new install's isn't there
    /// yet. Throws rather than guess when the drive isn't connected or the
    /// space can't be read.
    @Sendable public static func availableCapacity(at url: URL) throws -> UInt64 {
        try ensureConnected(url.path)
        let existing = nearestExisting(url)
        let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let capacity = capacity(importantUsage: values?.volumeAvailableCapacityForImportantUsage,
                                      available: values?.volumeAvailableCapacity) else {
            throw UpdateError.spaceUnknown(existing.path)
        }
        return capacity
    }

    /// The space for important usage (which counts what macOS can purge),
    /// else the plain free space: drives that aren't APFS (ExFAT, say)
    /// report no space for important usage at all, or zero.
    static func capacity(importantUsage: Int64?, available: Int?) -> UInt64? {
        if let importantUsage, importantUsage > 0 { return UInt64(importantUsage) }
        if let available, available >= 0 { return UInt64(available) }
        return importantUsage.map { UInt64(max($0, 0)) }
    }

    /// `url`, or the nearest folder above it that exists.
    static func nearestExisting(_ url: URL, fileManager fm: FileManager = .default) -> URL {
        var candidate = url.standardizedFileURL
        while !fm.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// The name of the drive `path` is on when that drive isn't connected:
    /// a path under `/Volumes/<name>` without a volume mounted there. Nil
    /// for the startup disk and a connected drive. Reads only the list of
    /// mounted volumes, so it may be used on the main thread.
    public static func missingDrive(for path: String, fileManager fm: FileManager = .default) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        let mounted = Set((fm.mountedVolumeURLs(includingResourceValuesForKeys: [], options: []) ?? []).map(\.standardizedFileURL.path))
        guard let missing = missingDrive(for: path, mounted: mounted) else { return nil }
        // "/Volumes/Macintosh HD" is a link to the startup disk.
        return (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/" + parts[2])) == nil ? missing : nil
    }

    static func missingDrive(for path: String, mounted: Set<String>) -> String? {
        guard !LocatedGames.isMounted(path: path, mounted: mounted) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.pathComponents[2]
    }

    /// Never writes to the startup disk in place of a drive that isn't
    /// connected: `/Volumes/<name>` would be an ordinary folder there. With
    /// `volumeUUID`, nor to another drive mounted under its name meanwhile.
    public static func ensureConnected(_ path: String, volumeUUID: String? = nil, fileManager fm: FileManager = .default) throws {
        if let drive = missingDrive(for: path, fileManager: fm) { throw UpdateError.driveNotConnected(drive) }
        if let volumeUUID, let uuid = self.volumeUUID(at: URL(fileURLWithPath: path), fileManager: fm), uuid != volumeUUID {
            throw UpdateError.otherDrive(URL(fileURLWithPath: path).standardizedFileURL.pathComponents[2])
        }
    }

    /// The volume a game on another drive is going to: its UUID. Nil on the
    /// startup disk (which is always there) and when it can't be read.
    /// Reads the disk: off the main thread.
    public static func volumeUUID(at url: URL, fileManager fm: FileManager = .default) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes", missingDrive(for: url.path, fileManager: fm) == nil else { return nil }
        return try? nearestExisting(url, fileManager: fm).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }
}
