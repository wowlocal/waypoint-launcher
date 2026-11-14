import Foundation

/// The folder the install sheet offers to put a game's folder in: the one
/// last chosen there with Change… for that platform, or else the built-in
/// one (/Applications for macOS games, ~/Games for Windows games).
public struct InstallLocations {
    /// A folder chosen with Change…, and the volume it was on, so another
    /// drive mounted under the same name isn't taken for it.
    public struct Remembered: Codable, Equatable, Sendable {
        public var path: String
        public var volumeUUID: String?

        public init(path: String, volumeUUID: String? = nil) {
            self.path = URL(fileURLWithPath: path).standardizedFileURL.path
            self.volumeUUID = volumeUUID
        }

        /// Reads the folder's volume: off the main thread.
        public init(at url: URL) {
            self.init(path: url.path, volumeUUID: try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        }
    }

    private let defaults: UserDefaults
    private let home: URL

    public init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
    }

    static func key(for platform: InstallPlatform) -> String { "installFolder.\(platform.rawValue)" }

    public func builtIn(for platform: InstallPlatform) -> URL {
        platform == .windows ? home.appendingPathComponent("Games", isDirectory: true)
            : URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    /// Whether `installPath` (a game's folder) is outside the built-in
    /// folders: somewhere the user chose.
    public func isChosen(installPath: String) -> Bool {
        let parent = URL(fileURLWithPath: installPath).standardizedFileURL.deletingLastPathComponent().path
        return !InstallPlatform.allCases.contains { builtIn(for: $0).standardizedFileURL.path == parent }
    }

    public func remembered(for platform: InstallPlatform) -> Remembered? {
        guard let data = defaults.data(forKey: Self.key(for: platform)) else { return nil }
        return try? JSONDecoder().decode(Remembered.self, from: data)
    }

    /// Offered from now on for `platform`'s games. The built-in folder
    /// isn't remembered: it stays whatever the built-in one is.
    public func remember(_ folder: Remembered, for platform: InstallPlatform) {
        if folder.path == builtIn(for: platform).standardizedFileURL.path {
            defaults.removeObject(forKey: Self.key(for: platform))
        } else if let data = try? JSONEncoder().encode(folder) {
            defaults.set(data, forKey: Self.key(for: platform))
        }
    }

    /// The folder to show first: the remembered one while its drive is
    /// mounted. Reads only the list of mounted volumes, so it may be used on
    /// the main thread; `resolved` checks the folder itself.
    public func offered(for platform: InstallPlatform, fileManager fm: FileManager = .default) -> URL {
        guard let remembered = remembered(for: platform),
              InstallVolume.missingDrive(for: remembered.path, fileManager: fm) == nil else { return builtIn(for: platform) }
        return URL(fileURLWithPath: remembered.path, isDirectory: true)
    }

    /// The folder to install in: the remembered one while it is there, on
    /// the drive it was chosen on; otherwise, silently, the built-in one.
    /// Reads the disk: off the main thread.
    public func resolved(for platform: InstallPlatform, fileManager fm: FileManager = .default) -> URL {
        guard let remembered = remembered(for: platform) else { return builtIn(for: platform) }
        let url = URL(fileURLWithPath: remembered.path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard InstallVolume.missingDrive(for: remembered.path, fileManager: fm) == nil,
              fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              remembered.volumeUUID == nil ||
                (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == remembered.volumeUUID
        else { return builtIn(for: platform) }
        return url
    }
}

// The defaults are only read and written on the main thread; `resolved`
// reads them from another, which UserDefaults allows.
extension InstallLocations: @unchecked Sendable {}
