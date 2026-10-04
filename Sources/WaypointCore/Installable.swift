import Foundation

/// A game Waypoint can install from scratch. Installing is the updater run
/// against an empty folder: the same manifest, tag selection, download and
/// verification, with every file missing.
///
/// Only games stored as loose files qualify. WoW keeps its data in a CASC
/// archive store, which Waypoint can't write yet.
public struct InstallableProduct: Sendable, Identifiable, Equatable {
    public var id: String { uid }
    public var uid: String
    public var productCode: String
    public var displayName: String
    /// Folder name under the chosen location, e.g. /Applications/Hearthstone.
    public var folderName: String
    /// Game languages, as Blizzard locale codes.
    public var languages: [String]
    /// Content tags Battle.net selects for a full install. Taken from the
    /// `active_tag_string` of a Battle.net install, which selects exactly the
    /// files it puts on disk.
    var contentTags: [String]

    public static let hearthstone = InstallableProduct(
        uid: "hs_beta",
        productCode: "hsb",
        displayName: "Hearthstone",
        folderName: "Hearthstone",
        languages: ["enUS", "deDE", "esES", "esMX", "frFR", "itIT", "jaJP", "koKR",
                    "plPL", "ptBR", "ruRU", "thTH", "zhCN", "zhTW"],
        contentTags: ["adventure", "base", "bgs", "dbf", "essential", "heromusic", "initial", "manifest",
                      "merc", "musicexpansion", "playsound", "porthigh", "portpremium", "soundlegend",
                      "soundmission", "soundotherminion", "strings"]
    )

    public static let all: [InstallableProduct] = [.hearthstone]

    /// The tag string Battle.net would record for this install: one group for
    /// speech and one for text, both in the chosen language.
    public func tagString(region: Region, language: String) -> String {
        let common = (["OSX"] + contentTags + ["\(region.launchOptionValue)?", language]).joined(separator: " ")
        return "\(common) speech?:\(common) text?"
    }

    /// The install record for a fresh install into `folder`.
    public func install(at folder: URL, region: Region, language: String) -> ProductInstall {
        ProductInstall(uid: uid, productCode: productCode, installPath: folder.standardizedFileURL.path,
                       region: region.rawValue, textLanguage: language,
                       tagString: tagString(region: region, language: language))
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
