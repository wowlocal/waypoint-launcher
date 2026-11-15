import Foundation

/// The `## Key: Value` lines of an add-on's TOC file that Waypoint uses.
/// Parsing never fails: a TOC the game can't read yields empty values.
public struct AddOnTOC: Equatable, Sendable {
    public var interfaces: [Int] = []
    /// Without color, texture and load-condition markup.
    public var title: String?
    public var author: String?
    /// Nil for a packager placeholder (`@project-version@`): a development copy.
    public var version: String?
    public var curseID: String?
    public var wagoID: String?
    public var wowiID: String?
    public var tukuiID: String?
    public var dependencies: [String] = []
    /// `## Group` (the main add-on of a group), else `## X-Part-Of`.
    public var group: String?
    public var isLoadOnDemand = false

    /// The game reads at most this much of a line.
    static let maximumLineLength = 1024
    /// More than any real TOC; a bigger file is read only this far.
    static let maximumSize = 256 * 1024

    public init(_ data: Data) {
        var seen: Set<String> = []
        for line in Self.lines(of: data.prefix(Self.maximumSize)) {
            guard line.hasPrefix("##") else { continue }
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The first of a repeated key wins, as in the game.
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            switch key {
            case "interface":
                interfaces = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            case "title": title = Self.plain(value)
            case "author": author = Self.plain(value)
            case "version":
                version = value.isEmpty || value.contains("@project-") ? nil : value
            case "x-curse-project-id": curseID = Self.id(value)
            case "x-wago-id": wagoID = Self.id(value)
            case "x-wowi-id": wowiID = Self.id(value)
            case "x-tukui-projectid": tukuiID = Self.id(value)
            case "dependencies", "requireddeps", "reqdeps", "dependancies":
                dependencies += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "group": group = value.isEmpty ? group : value
            case "x-part-of": if group == nil, !value.isEmpty { group = value }
            case "loadondemand": isLoadOnDemand = value == "1"
            default: break
            }
        }
    }

    /// Lines of UTF-8 (with or without a BOM), UTF-16 with a BOM, or else
    /// Latin-1; CRLF, CR or LF; each cut at the game's line length.
    static func lines(of data: Data) -> [Substring] {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else if let utf8 = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
        }
        return text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { $0.prefix(maximumLineLength) }
    }

    /// `|cFF33FF99Deadly|r Boss Mods |T…|t [AllowLoadGameType classic]` →
    /// "Deadly Boss Mods".
    static func plain(_ value: String) -> String? {
        var text = value
        for pattern in [#"\|c[0-9A-Fa-f]{8}"#, #"\|r"#, #"\|T[^|]*\|t"#, #"\|A[^|]*\|a"#,
                        #"\[(?:AllowLoad|ExcludeLoad)[^\]]*\]"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func id(_ value: String) -> String? {
        let id = value.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// The TOC the game loads for `flavor` among the file names in `folder`:
    /// a game suffix, then the family's, then `Folder.toc`. Names compare
    /// without regard to case, with `_` or `-` before the suffix.
    public static func choose(from names: [String], folder: String, flavor: WoWFlavor) -> String? {
        let byName = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let base = folder.lowercased()
        for suffix in flavor.tocSuffixes.map({ $0.lowercased() }) {
            for separator in ["_", "-"] {
                if let name = byName["\(base)\(separator)\(suffix).toc"] { return name }
            }
        }
        return byName["\(base).toc"]
    }

    /// Whether `name` is one of the folder's TOCs for some game: `Folder.toc`
    /// or `Folder_<suffix>.toc` with a suffix a game reads.
    static func isTOC(_ name: String, of folder: String) -> Bool {
        let lower = name.lowercased(), base = folder.lowercased()
        guard lower.hasSuffix(".toc"), lower.hasPrefix(base) else { return false }
        let rest = lower.dropFirst(base.count).dropLast(4)
        if rest.isEmpty { return true }
        guard let separator = rest.first, separator == "_" || separator == "-" else { return false }
        return WoWFlavor.allTOCSuffixes.contains(String(rest.dropFirst()))
    }

    /// Whether the game loads the folder at all: a TOC with one of the
    /// flavor's suffixes, or a plain TOC that lists one of the flavor's
    /// interface numbers, or none at all (the game shows such an add-on as
    /// out of date but loads it when asked). A plain TOC that names only
    /// other games, like Questie's "client not supported" `00000`, isn't.
    static func isForFlavor(chosen: String, folder: String, toc: AddOnTOC, flavor: WoWFlavor) -> Bool {
        guard chosen.lowercased() == "\(folder.lowercased()).toc", !toc.interfaces.isEmpty else { return true }
        return toc.interfaces.contains { WoWFlavor(interface: $0) == flavor }
    }
}
