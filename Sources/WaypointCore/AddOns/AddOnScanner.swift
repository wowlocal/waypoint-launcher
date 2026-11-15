import Foundation

/// A folder in `Interface/AddOns`, as the game would see it.
public struct InstalledFolder: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An add-on this game loads.
        case addOn
        /// `Blizzard_*`: the game's own.
        case blizzard
        /// A symbolic link: someone put it there by hand; never followed.
        case link
        /// A checkout with `.git` in it: a developer's working copy.
        case developmentCopy
        /// Only TOCs for other games: this one doesn't load it.
        case notForThisVersion
    }

    public var name: String
    public var kind: Kind
    /// The TOC this game loads, when there is one.
    public var toc: AddOnTOC?
    /// When that TOC file last changed: about when the add-on was put there.
    public var tocModified: Date?

    public init(name: String, kind: Kind, toc: AddOnTOC? = nil, tocModified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.toc = toc
        self.tocModified = tocModified
    }
}

/// Reads `Interface/AddOns`. Reads only: it never changes a file.
public struct AddOnScanner: Sendable {
    public init() {}

    /// Folders without any TOC (a stray folder, a half-copied add-on) and
    /// files are left out. A missing AddOns folder is an empty list: the game
    /// makes it the first time it runs.
    public func scan(_ addOns: URL, flavor: WoWFlavor?) throws -> [InstalledFolder] {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: addOns.path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var folders: [InstalledFolder] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = addOns.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                folders.append(InstalledFolder(name: name, kind: .link))
                continue
            case S_IFDIR: break
            default: continue
            }
            if name.hasPrefix("Blizzard_") {
                folders.append(InstalledFolder(name: name, kind: .blizzard))
                continue
            }
            guard let files = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
            let tocs = files.filter { AddOnTOC.isTOC($0, of: name) }
            guard !tocs.isEmpty else { continue }
            let chosen = flavor.flatMap { AddOnTOC.choose(from: tocs, folder: name, flavor: $0) }
                // A game Waypoint can't place: read the plain TOC for the name.
                ?? (flavor == nil ? AddOnTOC.choose(from: tocs, folder: name, flavor: .mainline) ?? tocs.sorted().first : nil)
            var folder = InstalledFolder(name: name, kind: .addOn)
            if let chosen {
                let file = url.appendingPathComponent(chosen)
                folder.toc = AddOnTOC(Self.read(file))
                folder.tocModified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let flavor, !AddOnTOC.isForFlavor(chosen: chosen, folder: name, toc: folder.toc!, flavor: flavor) {
                    folder.kind = .notForThisVersion
                }
            } else {
                folder.kind = .notForThisVersion
            }
            if files.contains(".git") { folder.kind = .developmentCopy }
            folders.append(folder)
        }
        return folders
    }

    /// At most the TOC parser's limit, so a huge file can't stall the scan.
    static func read(_ file: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: AddOnTOC.maximumSize)) ?? Data()
    }
}
