import Foundation
import Darwin

/// The installed files' platform, independent of the host and of the runner.
/// Never infer this from whether an executable happens to be a macOS bundle.
public enum InstallPlatform: String, Codable, Sendable, CaseIterable {
    case macOS = "mac"
    case windows = "win"

    public var manifestTag: String { self == .macOS ? "OSX" : "Windows" }

    /// Native keys retain their original spelling for existing state files.
    public func installKey(uid: String) -> String { self == .macOS ? uid : "\(uid)@windows" }

    public static func from(tags: String?) -> InstallPlatform? {
        guard let tags else { return nil }
        let words = Set(tags.split { $0.isWhitespace || $0 == ":" }.map(String.init))
        // Overwatch's Windows manifests use SPWin/TPWin, not "Windows".
        let windows = !words.isDisjoint(with: ["Windows", "SPWin", "TPWin"])
        if words.contains("OSX") && windows { return nil }
        if windows { return .windows }
        if words.contains("OSX") { return .macOS }
        return nil
    }

    /// Refuse to reuse storage belonging to another platform. The game's own
    /// build record is authoritative, even when Waypoint's record is stale.
    func validate(install: ProductInstall, fileManager: FileManager = .default) throws {
        let root = URL(fileURLWithPath: install.installPath)
        let marker = root.appendingPathComponent(Self.claimFileName)
        if fileManager.fileExists(atPath: marker.path) {
            let data = try Data(contentsOf: marker)
            guard data == Data((rawValue + "\n").utf8) else {
                throw TACTError.malformed("This folder belongs to another platform's installation")
            }
        }
        func check(_ tags: String, strict: Bool) throws {
            let words = Set(tags.split { $0.isWhitespace || $0 == ":" }.map(String.init))
            let other = self == .macOS ? !words.isDisjoint(with: ["Windows", "SPWin", "TPWin"]) : words.contains("OSX")
            if other || (strict && Self.from(tags: tags) != self) {
                throw TACTError.malformed("This folder contains another platform's game files. Choose a separate folder")
            }
        }
        if let tags = install.tagString { try check(tags, strict: self == .windows) }
        let file = URL(fileURLWithPath: install.installPath).appendingPathComponent(".build.info")
        guard fileManager.fileExists(atPath: file.path) else { return }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let header = text.split(whereSeparator: \.isNewline).first else {
            if self == .macOS { return }
            throw TACTError.malformed("Unreadable game build record")
        }
        let rows = text.split(whereSeparator: \.isNewline)
        let columns = header.split(separator: "|", omittingEmptySubsequences: false)
        guard let tagsIndex = columns.firstIndex(where: { $0.hasPrefix("Tags!") || $0 == "Tags" }) else {
            if self == .macOS { return }
            throw TACTError.malformed("Game build record has no platform tags")
        }
        let productIndex = columns.firstIndex { $0.hasPrefix("Product!") || $0 == "Product" }
        for row in rows.dropFirst() {
            let fields = row.split(separator: "|", omittingEmptySubsequences: false)
            if let productIndex, productIndex < fields.count,
               !fields[productIndex].isEmpty,
               fields[productIndex] != install.uid && fields[productIndex] != install.productCode { continue }
            guard tagsIndex < fields.count else {
                if self == .macOS { continue }
                throw TACTError.malformed("Incomplete game build record")
            }
            try check(String(fields[tagsIndex]), strict: self == .windows)
        }
    }

    /// The file `claim` leaves in an install folder. Whatever is in the
    /// folder and older than it was there before Waypoint installed anything.
    static let claimFileName = ".waypoint-platform"

    /// Claim a new folder before the first resumable write. O_EXCL prevents
    /// two installers from claiming an empty root for different platforms.
    func claim(install: ProductInstall) throws {
        try validate(install: install)
        let root = URL(fileURLWithPath: install.installPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(Self.claimFileName).path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == EEXIST { try validate(install: install); return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let data = Data((rawValue + "\n").utf8)
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0 else {
            let code = errno
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
