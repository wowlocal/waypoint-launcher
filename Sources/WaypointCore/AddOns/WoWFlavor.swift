import Foundation

/// Which World of Warcraft game an add-on is built for. Add-ons, their TOC
/// files and their releases are per flavor, not per Battle.net product:
/// `_classic_` has been Wrath, Cata and now Mists Classic.
public enum WoWFlavor: String, Codable, Sendable, CaseIterable {
    case mainline, vanilla, forever, tbc, wrath, titan, cata, mists

    /// From an `## Interface` number (12.1.5 is 120105). The ranges are
    /// instawow's and the BigWigs packager's; numbers outside them belong to
    /// no current game.
    public init?(interface: Int) {
        switch interface {
        case 11300...15999: self = .vanilla
        case 16000...19999: self = .forever
        case 20500...29999: self = .tbc
        case 30400...37999: self = .wrath
        case 38000...39999: self = .titan
        case 40400...49999: self = .cata
        case 50500...59999: self = .mists
        case 60000...999_999: self = .mainline
        default: return nil
        }
    }

    /// "12.1.5.65432" → 120105.
    public static func interface(version: String?) -> Int? {
        guard let version else { return nil }
        let parts = version.split(separator: ".").prefix(3).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2],
              (0..<100).contains(minor), (0..<100).contains(patch) else { return nil }
        return major * 10000 + minor * 100 + patch
    }

    /// The flavor of an installed WoW game: from its version when that's
    /// known, so Waypoint keeps up when Blizzard moves `_classic_` to the next
    /// expansion; else from the product. Nil for a game Waypoint can't place:
    /// it lists the add-ons but doesn't update them.
    public static func of(productCode: String, version: String?) -> WoWFlavor? {
        if let interface = interface(version: version), let flavor = WoWFlavor(interface: interface) { return flavor }
        switch productCode {
        case "wow", "wowt", "wowxptr", "wow_beta": return .mainline
        case "wow_classic", "wow_classic_ptr": return .mists
        case "wow_classic_era": return .vanilla
        case "wow_classic_era_ptr", "wow_anniversary": return .tbc
        case "wowf", "wow_classic_beta": return .forever
        default: return nil
        }
    }

    public static func of(_ install: ProductInstall) -> WoWFlavor? {
        of(productCode: install.productCode, version: install.version)
    }

    /// The TOC suffixes the game looks for, most specific first, before it
    /// falls back to the plain `Folder.toc` (warcraft.wiki.gg/wiki/TOC_format:
    /// game type, then family). Forever is in the mainline family; Titan
    /// Reforged reads Wrath's.
    public var tocSuffixes: [String] {
        switch self {
        case .mainline: ["Standard", "Mainline"]
        case .forever: ["Forever", "Camelot", "Mainline"]
        case .vanilla: ["Vanilla", "Classic"]
        case .tbc: ["TBC", "BCC", "Classic"]
        case .wrath, .titan: ["Wrath", "WOTLKC", "Classic"]
        case .cata: ["Cata", "Classic"]
        case .mists: ["Mists", "Classic"]
        }
    }

    /// Every suffix any game reads: a TOC with one of them is for some
    /// flavor, a TOC with another suffix isn't a game's at all.
    static let allTOCSuffixes: Set<String> = Set(allCases.flatMap(\.tocSuffixes).map { $0.lowercased() })
        .union(["plunderstorm", "wowlabs", "wowhack"])

    /// The name `release.json` (BigWigs packager) gives this flavor.
    var releaseName: String {
        switch self {
        case .mainline: "mainline"
        case .vanilla: "classic"
        case .forever: "forever"
        case .tbc: "bcc"
        case .wrath: "wrath"
        case .titan: "titan"
        case .cata: "cata"
        case .mists: "mists"
        }
    }

    init?(releaseName: String) {
        guard let flavor = Self.allCases.first(where: { $0.releaseName == releaseName.lowercased() }) else { return nil }
        self = flavor
    }

    /// For messages: "TomTom has no version for WoW Classic Era."
    public var gameName: String {
        switch self {
        case .mainline: "World of Warcraft"
        case .vanilla: "WoW Classic Era"
        case .forever: "WoW Forever"
        case .tbc: "WoW Classic Anniversary"
        case .wrath: "Wrath of the Lich King Classic"
        case .titan: "Titan Reforged"
        case .cata: "Cataclysm Classic"
        case .mists: "WoW Classic"
        }
    }
}
