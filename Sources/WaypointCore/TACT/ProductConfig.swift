import Foundation

/// The parts of a product's Blizzard "product config" (JSON on the CDN,
/// named by the `ProductConfig` column of the versions table) that say how
/// the game is laid out on macOS. It's what the Battle.net Agent itself
/// follows, so installs match its layout.
public struct ProductConfig: Sendable, Equatable {
    /// Where loose (install manifest) files go, relative to the install root;
    /// WoW and Warcraft III use flavor folders like `_retail_`. Empty: root.
    public var subfolder: String
    /// The local CASC storage folder, e.g. `Data/`, `SC2Data/`, `HeroesData/`.
    public var dataDirectory: String
    public var supportedLocales: [String]
    /// Tags for a full macOS install: platform plus, for some games, content
    /// sets (Hearthstone) or `code` (SC2, HotS).
    public var platformTags: [String]
    /// Extra tags the Agent adds: CPU architectures (WoW), `Alternate`
    /// (Anniversary), `noigr` (StarCraft).
    public var extraTags: [String]
    /// The game's `.app`, relative to the subfolder.
    public var gameBinary: String?
    public var launchArguments: [String]
    /// Default folder name under /Applications, when the config names one.
    public var folderName: String?
    /// Games stored as loose files only, with no local CASC storage (Hearthstone).
    public var isContainerless: Bool

    public init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TACTError.malformed("product config")
        }
        let all = (root["all"] as? [String: Any])?["config"] as? [String: Any] ?? [:]
        let mac = ((root["platform"] as? [String: Any])?["mac"] as? [String: Any])?["config"] as? [String: Any] ?? [:]

        subfolder = all["shared_container_default_subfolder"] as? String ?? ""
        dataDirectory = all["data_dir"] as? String ?? "Data/"
        supportedLocales = all["supported_locales"] as? [String] ?? []
        platformTags = mac["tags"] as? [String] ?? ["OSX"]

        var extra: [String] = []
        if let bits64 = mac["tags_64bit"] as? [String] {
            // The Agent picks the 64-bit set; WoW's manifests also carry
            // arm64 files for Apple silicon, so take both.
            extra += bits64 + ["arm64"]
        }
        extra += all["extra_tags"] as? [String] ?? []
        extra += all["noigr_tags"] as? [String] ?? []
        extraTags = extra

        let game = (mac["binaries"] as? [String: Any])?["game"] as? [String: Any] ?? [:]
        gameBinary = game["relative_path_64"] as? String ?? game["relative_path"] as? String
        launchArguments = game["launch_arguments"] as? [String] ?? []
        folderName = ((mac["form"] as? [String: Any])?["game_dir"] as? [String: Any])?["dirname"] as? String
        isContainerless = (mac["update_method"] as? String)?.contains("containerless") == true
            || (all["update_method"] as? String)?.contains("containerless") == true
    }

    /// The tag string the Agent records for an install: a speech group and a
    /// text group, both in the chosen language.
    public func tagString(region: Region, language: String) -> String {
        let common = (platformTags + extraTags + ["\(region.launchOptionValue)?", language]).joined(separator: " ")
        return "\(common) speech?:\(common) text?"
    }
}

extension VersionService {
    /// Fetches and parses a product's config for the given live version.
    public func productConfig(product: String, region: Region, version given: ProductVersion? = nil) async throws -> ProductConfig {
        let version: ProductVersion
        if let given { version = given } else { version = try await latest(product: product, region: region) }
        guard let hash = version.productConfig, !hash.isEmpty else { throw TACTError.notFound("\(product) product config") }
        let cdn = try await cdn(product: product, region: region)
        let data = try await cdn.cachedConfigFile(hash, path: cdn.configPath ?? "tpr/configs/data")
        return try ProductConfig(json: data)
    }
}
