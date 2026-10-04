import Foundation

/// A Battle.net game with a macOS client: what Waypoint needs to install and
/// launch it. Layout facts come from each product's Blizzard product config
/// (see ProductConfig); tags and folders are re-read from it at install
/// time, so this only pins down what doesn't change between builds.
public struct InstallableProduct: Sendable, Identifiable, Equatable {
    public var id: String { uid }
    /// Battle.net's install uid; also what `-uid` passes to the game.
    public var uid: String
    public var productCode: String
    public var displayName: String
    /// Default folder under /Applications. WoW flavors share one.
    public var folderName: String
    /// `Launch Options/<codename>/…` in the net.battle preferences, and the
    /// web login's `app=` value.
    public var codename: String
    /// The game's `.app`, relative to the install root (flavor folder included).
    public var appPath: String
    /// Arguments from the product config; Waypoint adds `-uid <uid>`.
    public var launchArguments: [String]
    /// Run from the flavor folder rather than the install root.
    public var flavorFolder: String?
    /// Stored as loose files only, with no local CASC storage (Hearthstone).
    public var isContainerless: Bool
    /// Game languages, as Blizzard locale codes.
    public var languages: [String]

    static let commonLanguages = ["enUS", "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "plPL", "ptBR", "ruRU", "zhCN", "zhTW"]

    public static let hearthstone = InstallableProduct(
        uid: "hs_beta", productCode: "hsb", displayName: "Hearthstone", folderName: "Hearthstone", codename: "WTCG",
        appPath: "Hearthstone.app", launchArguments: ["-launch"], flavorFolder: nil, isContainerless: true,
        languages: commonLanguages + ["jaJP", "thTH"])

    public static let all: [InstallableProduct] = [
        .hearthstone,
        InstallableProduct(uid: "wow", productCode: "wow", displayName: "World of Warcraft", folderName: "World of Warcraft",
                           codename: "WoW", appPath: "_retail_/World of Warcraft.app", launchArguments: ["-launcherlogin"],
                           flavorFolder: "_retail_", isContainerless: false, languages: commonLanguages.filter { $0 != "plPL" }),
        InstallableProduct(uid: "wow_classic", productCode: "wow_classic", displayName: "WoW Classic", folderName: "World of Warcraft",
                           codename: "WoW", appPath: "_classic_/World of Warcraft Classic.app", launchArguments: ["-launcherlogin"],
                           flavorFolder: "_classic_", isContainerless: false,
                           languages: ["enUS", "deDE", "esES", "frFR", "koKR", "ruRU", "zhCN", "zhTW"]),
        InstallableProduct(uid: "wow_classic_era", productCode: "wow_classic_era", displayName: "WoW Classic Era", folderName: "World of Warcraft",
                           codename: "WoW", appPath: "_classic_era_/World of Warcraft Classic.app", launchArguments: ["-launcherlogin"],
                           flavorFolder: "_classic_era_", isContainerless: false,
                           languages: ["enUS", "deDE", "esES", "esMX", "frFR", "koKR", "ptBR", "ruRU", "zhCN", "zhTW"]),
        InstallableProduct(uid: "wow_anniversary", productCode: "wow_anniversary", displayName: "WoW Classic Anniversary", folderName: "World of Warcraft",
                           codename: "WoW", appPath: "_anniversary_/World of Warcraft Classic.app",
                           launchArguments: ["-launcherlogin", "-initialgamemode=bccfresh"],
                           flavorFolder: "_anniversary_", isContainerless: false, languages: commonLanguages + ["jaJP", "thTH"]),
        InstallableProduct(uid: "s2", productCode: "s2", displayName: "StarCraft II", folderName: "StarCraft II", codename: "S2",
                           appPath: "Support/SC2Switcher.app", launchArguments: ["-launch"], flavorFolder: nil, isContainerless: false,
                           languages: commonLanguages),
        InstallableProduct(uid: "s1", productCode: "s1", displayName: "StarCraft", folderName: "StarCraft", codename: "S1",
                           appPath: "x86_64/StarCraft.app", launchArguments: ["-launch"], flavorFolder: nil, isContainerless: false,
                           languages: commonLanguages),
        InstallableProduct(uid: "d3", productCode: "d3", displayName: "Diablo III", folderName: "Diablo III", codename: "D3",
                           appPath: "Diablo III.app", launchArguments: ["-launch"], flavorFolder: nil, isContainerless: false,
                           languages: commonLanguages.filter { $0 != "zhCN" }),
        InstallableProduct(uid: "w3", productCode: "w3", displayName: "Warcraft III", folderName: "Warcraft III", codename: "W3",
                           appPath: "_retail_/x86_64/Warcraft III.app", launchArguments: ["-launch"], flavorFolder: "_retail_",
                           isContainerless: false, languages: commonLanguages),
        InstallableProduct(uid: "hero", productCode: "hero", displayName: "Heroes of the Storm", folderName: "Heroes of the Storm",
                           codename: "Hero", appPath: "Support/HeroesSwitcher.app", launchArguments: ["-launch"], flavorFolder: nil,
                           isContainerless: false, languages: commonLanguages),
    ]

    public static func forProduct(_ code: String) -> InstallableProduct? { all.first { $0.productCode == code } }

    /// The install record for a fresh install into `folder`.
    public func install(at folder: URL, region: Region, language: String, tagString: String) -> ProductInstall {
        ProductInstall(uid: uid, productCode: productCode, installPath: folder.standardizedFileURL.path,
                       region: region.rawValue, textLanguage: language, tagString: tagString)
    }

    /// The game language closest to the user's preferred languages.
    public func defaultLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferred {
            if let match = Self.blizzardLocale(for: identifier), languages.contains(match) { return match }
        }
        return "enUS"
    }

    /// Maps a BCP 47 identifier (`ru-RU`, `zh-Hant-TW`, `pt`) to a Blizzard locale (`ruRU`, `zhTW`, `ptBR`).
    static func blizzardLocale(for identifier: String) -> String? {
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let region = locale.region?.identifier
        switch language {
        case "en": return "enUS"
        case "es": return ["MX", "US", "AR", "CL", "CO", "PE", "VE"].contains(region ?? "") || region == "419" ? "esMX" : "esES"
        case "pt": return "ptBR"
        case "zh":
            let script = locale.language.script?.identifier
            return script == "Hant" || ["TW", "HK", "MO"].contains(region ?? "") ? "zhTW" : "zhCN"
        case "de", "fr", "it", "ru", "pl": return language + language.uppercased()
        case "ja": return "jaJP"
        case "ko": return "koKR"
        case "th": return "thTH"
        default: return nil
        }
    }
}

extension Region {
    /// The Battle.net region for a country: Americas and Oceania play on US,
    /// East Asia on KR, mainland China on CN, everyone else on EU.
    public static func `default`(for country: String? = Locale.current.region?.identifier) -> Region {
        guard let country else { return .eu }
        let americasAndOceania: Set = ["US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "VE", "UY", "PY", "BO",
                                       "EC", "AU", "NZ", "PH", "SG", "MY", "ID", "TH", "VN"]
        if americasAndOceania.contains(country) { return .us }
        if ["KR", "TW", "HK", "MO", "JP"].contains(country) { return .kr }
        if country == "CN" { return .cn }
        return .eu
    }
}
