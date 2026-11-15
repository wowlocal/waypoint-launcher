import CryptoKit
import Foundation
import zlib
@testable import WaypointCore

/// Writes zip files byte by byte, so tests can make the archives no zip
/// tool will: `../` paths, symlinks, sizes that lie, case twins.
enum TestZip {
    enum Entry {
        case file(String, Data)
        case directory(String)
        case symlink(String, target: String)
        /// Declares `declaredSize` but holds `actual`.
        case lying(String, actual: Data, declaredSize: UInt32)
        /// A CRC that doesn't match the contents.
        case badCRC(String, Data)
    }

    static func make(_ entries: [Entry], deflate: Bool = true) -> Data {
        var out = Data(), central = Data()
        for entry in entries {
            let name: String, contents: Data, mode: UInt32
            var declared: UInt32?, crcOverride: UInt32?
            switch entry {
            case .file(let n, let d): (name, contents, mode) = (n, d, 0o100644)
            case .directory(let n): (name, contents, mode) = (n.hasSuffix("/") ? n : n + "/", Data(), 0o040755)
            case .symlink(let n, let target): (name, contents, mode) = (n, Data(target.utf8), 0o120777)
            case .lying(let n, let d, let size): (name, contents, mode) = (n, d, 0o100644); declared = size
            case .badCRC(let n, let d): (name, contents, mode) = (n, d, 0o100644); crcOverride = 0xDEAD_BEEF
            }
            let crc = crcOverride ?? contents.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let packed = deflate && !contents.isEmpty ? rawDeflate(contents) : contents
            let method: UInt16 = deflate && !contents.isEmpty ? 8 : 0
            let nameData = Data(name.utf8)
            let offset = UInt32(out.count)
            out.le(UInt32(0x0403_4b50)); out.le(UInt16(20)); out.le(UInt16(0x800)); out.le(method)
            out.le(UInt16(0)); out.le(UInt16(0)); out.le(crc); out.le(UInt32(packed.count))
            out.le(declared ?? UInt32(contents.count)); out.le(UInt16(nameData.count)); out.le(UInt16(0))
            out.append(nameData); out.append(packed)
            central.le(UInt32(0x0201_4b50)); central.le(UInt16(0x0314)); central.le(UInt16(20)); central.le(UInt16(0x800))
            central.le(method); central.le(UInt16(0)); central.le(UInt16(0)); central.le(crc)
            central.le(UInt32(packed.count)); central.le(declared ?? UInt32(contents.count)); central.le(UInt16(nameData.count))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(mode << 16); central.le(offset); central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le(UInt32(0x0605_4b50)); out.le(UInt16(0)); out.le(UInt16(0)); out.le(UInt16(entries.count))
        out.le(UInt16(entries.count)); out.le(UInt32(central.count)); out.le(cdOffset); out.le(UInt16(0))
        return out
    }

    static func rawDeflate(_ data: Data) -> Data {
        var stream = z_stream()
        deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        var input = [UInt8](data)
        let produced = input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf -> Int in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                deflate(&stream, Z_FINISH)
                return outBuf.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<produced])
    }

    /// An add-on folder's entries: `Folder/Folder.toc` plus a Lua file.
    static func addOn(_ folder: String, toc: String = "## Interface: 120105\n## Version: 1.0\n", tocName: String? = nil,
                      lua: String = "print('hi')") -> [Entry] {
        [.file("\(folder)/\(tocName ?? folder + ".toc")", Data(toc.utf8)), .file("\(folder)/Core.lua", Data(lua.utf8))]
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// A World of Warcraft folder in a temp directory, with saved settings in
/// `WTF` that no add-on operation may touch.
struct FakeWoW {
    let root: URL
    let flavorFolder: String

    init(flavorFolder: String = "_retail_", makeAddOns: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-addons-\(UUID().uuidString)", isDirectory: true)
        self.flavorFolder = flavorFolder
        let fm = FileManager.default
        if makeAddOns { try fm.createDirectory(at: addOns, withIntermediateDirectories: true) }
        let sv = wtf.appendingPathComponent("Account/ACCT1/SavedVariables", isDirectory: true)
        try fm.createDirectory(at: sv, withIntermediateDirectories: true)
        try Data("DBM_SavedOptions = {}\n".utf8).write(to: sv.appendingPathComponent("DBM-Core.lua"))
        let character = wtf.appendingPathComponent("Account/ACCT1/Realm/Char", isDirectory: true)
        try fm.createDirectory(at: character.appendingPathComponent("SavedVariables"), withIntermediateDirectories: true)
        try Data("Foo: enabled\n".utf8).write(to: character.appendingPathComponent("AddOns.txt"))
        try Data("SET locale \"enUS\"\n".utf8).write(to: wtf.appendingPathComponent("Config.wtf"))
    }

    var game: URL { root.appendingPathComponent(flavorFolder, isDirectory: true) }
    var addOns: URL { game.appendingPathComponent("Interface/AddOns", isDirectory: true) }
    var wtf: URL { game.appendingPathComponent("WTF", isDirectory: true) }
    var store: AddOnStore { AddOnStore(directory: root.appendingPathComponent("Support", isDirectory: true)) }
    var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    var stagingRoot: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    /// Writes a folder into AddOns: a name → contents map of its files.
    func addOn(_ folder: String, _ files: [String: String]) throws {
        let dir = addOns.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    /// Moves to `root/Trash/<n>-<name>` and says where.
    var trashFunction: @Sendable (URL) throws -> URL {
        let trash = trash
        return { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    var stagingFunction: @Sendable (URL) throws -> URL {
        let root = stagingRoot
        return { _ in
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    func library(http: FakeHTTP, flavor: WoWFlavor? = .mainline, interface: Int? = 120105,
                 now: @escaping @Sendable () -> Date = { Date() }) -> AddOnLibrary {
        AddOnLibrary(addOns: addOns, flavor: flavor, interface: interface, store: store, http: http.http,
                     cache: root.appendingPathComponent("Cache", isDirectory: true),
                     staging: stagingFunction, trash: trashFunction, now: now)
    }

    /// Nothing left in staging after an operation.
    func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
    }

    func trashed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).map { String($0.dropFirst(9)) }.sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Every file, folder and link under a folder, with a hash of each file:
/// equal snapshots mean nothing changed.
struct TreeSnapshot: Equatable {
    var items: [String: String]

    init(_ root: URL) throws {
        items = [:]
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let walker = fm.enumerator(atPath: root.path)!
        while let path = walker.nextObject() as? String {
            let full = root.appendingPathComponent(path).path
            var info = stat()
            lstat(full, &info)
            switch info.st_mode & S_IFMT {
            case S_IFLNK: items[path] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: full)) ?? "")
            case S_IFDIR: items[path] = "dir"
            default:
                let data = (try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data()
                items[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    /// The top-level folders whose contents differ.
    func changedFolders(to other: TreeSnapshot) -> Set<String> {
        var changed: Set<String> = []
        for key in Set(items.keys).union(other.items.keys) where items[key] != other.items[key] {
            changed.insert(String(key.prefix { $0 != "/" }))
        }
        return changed
    }
}

/// Canned responses by URL; anything else is a 404, and every request is
/// remembered.
final class FakeHTTP: @unchecked Sendable {
    struct Route { var response: AddOnHTTP.Response }
    private let lock = NSLock()
    private var routes: [String: AddOnHTTP.Response] = [:]
    private var downloads: [String: Data] = [:]
    private var seen: [String] = []
    var failGets = false

    func route(_ url: String, _ data: Data, status: Int = 200, redirect: String? = nil, modified: Date? = nil) {
        lock.withLock {
            routes[url] = AddOnHTTP.Response(data: data, status: status, firstRedirect: redirect.flatMap(URL.init(string:)),
                                             lastModified: modified)
        }
    }

    func file(_ url: String, _ data: Data) { lock.withLock { downloads[url] = data } }

    var requests: [String] { lock.withLock { seen } }

    var http: AddOnHTTP {
        AddOnHTTP(
            get: { [self] url in
                lock.withLock { seen.append(url.absoluteString) }
                if lock.withLock({ failGets }) { throw URLError(.notConnectedToInternet) }
                return lock.withLock { routes[url.absoluteString] } ?? AddOnHTTP.Response(data: Data(), status: 404)
            },
            download: { [self] url, maximum, progress in
                lock.withLock { seen.append(url.absoluteString) }
                guard let data = lock.withLock({ downloads[url.absoluteString] }) else { throw HTTPFailure(status: 404, url: url) }
                guard data.count <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-test-zip-\(UUID().uuidString)")
                try data.write(to: file)
                progress(1)
                return file
            })
    }

    /// GitHub as Waypoint reads it: `release.json` behind a redirect that
    /// names the tag, and the zip next to it.
    func github(_ repo: String, tag: String, zip: Data, filename: String, metadata: [(String, Int)],
                version: String? = nil, released: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "+"]))!
        let base = "https://github.com/\(repo)/releases/download/\(encodedTag)"
        let meta = metadata.map { #"{"flavor":"\#($0.0)","interface":\#($0.1)}"# }.joined(separator: ",")
        let versionField = version.map { #""version":"\#($0)","# } ?? ""
        let json = #"{"releases":[{"name":"\#(repo)",\#(versionField)"filename":"\#(filename)","nolib":false,"metadata":[\#(meta)]}]}"#
        route("https://github.com/\(repo)/releases/latest/download/release.json", Data(json.utf8),
              redirect: "\(base)/release.json", modified: released)
        file("\(base)/\(filename)", zip)
    }
}
