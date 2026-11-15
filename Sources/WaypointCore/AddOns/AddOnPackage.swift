import CryptoKit
import Foundation

/// A downloaded add-on zip that passed every check. An add-on either
/// installs exactly as it was packaged or not at all: any entry that could
/// land outside its folder, or a zip that isn't made of add-on folders, is
/// refused before anything is extracted.
public struct AddOnPackage: Sendable {
    /// The zip's top-level folders, each an add-on with its own TOC.
    public let folders: [String]
    public let uncompressedBytes: UInt64
    let url: URL
    /// What `extract` writes, junk left out.
    private let files: [ZipArchive.Entry]

    public static let maximumEntries = 100_000
    public static let maximumBytes: UInt64 = 4 << 30
    /// Finder, Windows and macOS's zip leave these behind; they're dropped.
    static let junk: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]

    public init(zip: URL, flavor: WoWFlavor,
                maximumEntries: Int = maximumEntries, maximumBytes: UInt64 = maximumBytes) throws {
        let archive = try ZipArchive(zip)
        guard archive.entries.count <= maximumEntries else { throw AddOnPackageError.tooLarge }
        url = zip

        var kept: [ZipArchive.Entry] = []
        var seen: Set<String> = []
        var folderNames: [String: String] = [:]   // lowercased → as written
        var total: UInt64 = 0
        for entry in archive.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // A trailing "/" marks a folder; it leaves one empty component.
            let parts = entry.path.hasSuffix("/") ? Array(components.dropLast()) : components
            guard let top = parts.first, !top.isEmpty else { throw AddOnPackageError.unsafe(entry.path) }
            if top == "__MACOSX" { continue }
            if let last = parts.last, Self.junk.contains(last.lowercased()) || last.hasPrefix("._") { continue }
            guard !entry.path.hasPrefix("/"), !Self.hasDriveLetter(top),
                  parts.allSatisfy(Self.isSafeComponent) else { throw AddOnPackageError.unsafe(entry.path) }
            guard !entry.isSymlink else { throw AddOnPackageError.unsafe(entry.path) }
            guard !entry.isEncrypted, entry.method == 0 || entry.method == 8 else { throw AddOnPackageError.unsupported }
            if parts.count == 1 && !entry.isDirectory { throw AddOnPackageError.notAnAddOn("a loose file, \(top)") }
            // Two names the Mac's disk treats as one would overwrite each other.
            guard seen.insert(parts.joined(separator: "/").lowercased()).inserted || entry.isDirectory else {
                throw AddOnPackageError.unsafe(entry.path)
            }
            if let earlier = folderNames[top.lowercased()], earlier != top { throw AddOnPackageError.unsafe(entry.path) }
            folderNames[top.lowercased()] = top
            total += entry.size
            guard total <= maximumBytes else { throw AddOnPackageError.tooLarge }
            if !entry.isDirectory { kept.append(entry) }
        }

        let folders = folderNames.values.sorted()
        guard !folders.isEmpty else { throw AddOnPackageError.notAnAddOn("no add-on folders") }
        var loads = false
        for folder in folders {
            guard !folder.hasPrefix("Blizzard_"), !folder.hasPrefix(".") else { throw AddOnPackageError.notAnAddOn(folder) }
            let inside = kept.filter { $0.path.hasPrefix(folder + "/") && $0.path.dropFirst(folder.count + 1).firstIndex(of: "/") == nil }
            let tocs = inside.map { String($0.path.dropFirst(folder.count + 1)) }.filter { AddOnTOC.isTOC($0, of: folder) }
            guard !tocs.isEmpty else { throw AddOnPackageError.notAnAddOn("\(folder) has no TOC file") }
            if let chosen = AddOnTOC.choose(from: tocs, folder: folder, flavor: flavor),
               let entry = inside.first(where: { $0.path == "\(folder)/\(chosen)" }) {
                let toc = AddOnTOC(try archive.data(entry, maximum: AddOnTOC.maximumSize * 4))
                if AddOnTOC.isForFlavor(chosen: chosen, folder: folder, toc: toc, flavor: flavor) { loads = true }
            }
        }
        guard loads else { throw AddOnSourceError.notForThisVersion }
        self.folders = folders
        self.files = kept
        uncompressedBytes = total
    }

    /// Writes the add-on folders into `directory`: plain files and folders
    /// only, each checked against its size and CRC.
    func extract(to directory: URL) throws {
        let archive = try ZipArchive(url)
        let fm = FileManager.default
        for folder in folders {
            try fm.createDirectory(at: directory.appendingPathComponent(folder, isDirectory: true),
                                   withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        for entry in files {
            let file = directory.appendingPathComponent(entry.path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try archive.extract(entry, to: file)
        }
    }

    static func isSafeComponent(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 255 &&
            !part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == ":" }
    }

    private static func hasDriveLetter(_ part: String) -> Bool {
        part.count == 2 && part.last == ":" && part.first?.isLetter == true
    }
}

public enum AddOnPackageError: Error, Equatable, LocalizedError {
    case unsafe(String)
    case notAnAddOn(String)
    case tooLarge
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unsafe: "The add-on’s download contains files Waypoint won’t install."
        case .notAnAddOn: "The download isn’t an add-on Waypoint can install."
        case .tooLarge: "The add-on’s download is too large."
        case .unsupported: "This add-on’s download is in a format Waypoint can’t open."
        }
    }
}

/// A fingerprint of add-on folders as they are on disk: every file's path
/// and contents. Equal before and after means nobody changed the files.
enum AddOnContentHash {
    /// Each folder that's there, by name.
    static func of(_ folders: [String], in addOns: URL) -> [String: String] {
        var hashes: [String: String] = [:]
        for folder in folders {
            if let hash = try? of(folder, in: addOns) { hashes[folder] = hash }
        }
        return hashes
    }

    /// Whether any folder that's still there differs from how Waypoint left it.
    static func changed(_ record: AddOnRecord, in addOns: URL) -> Bool {
        let now = of(record.folders, in: addOns)
        return now.contains { record.folderHashes[$0.key] != $0.value }
    }

    /// Every file's path and contents in one folder; throws when the folder
    /// isn't there (or isn't a folder).
    static func of(_ folder: String, in addOns: URL) throws -> String {
        var hash = SHA256()
        let fm = FileManager.default
        let root = addOns.appendingPathComponent(folder, isDirectory: true)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let walker = fm.enumerator(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
        var paths: [String] = []
        while let path = walker.nextObject() as? String {
            // Finder adds .DS_Store when someone just looks.
            guard (path as NSString).lastPathComponent != ".DS_Store" else { continue }
            guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFREG || type == S_IFLNK { paths.append(path) }
        }
        for path in paths.sorted() {
            hash.update(data: Data("\(path)\0".utf8))
            let file = root.appendingPathComponent(path)
            if let target = try? fm.destinationOfSymbolicLink(atPath: file.path) {
                hash.update(data: Data("link:\(target)\0".utf8))
            } else {
                hash.update(data: Data(SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
