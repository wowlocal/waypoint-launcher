import Foundation

/// The parts of a product's Blizzard "product config" (JSON on the CDN,
/// named by the `ProductConfig` column of the versions table) that say how
/// the game is laid out on macOS. It's what the Battle.net Agent itself
/// follows, so installs match its layout.
public struct ProductConfig: Sendable, Equatable {
    public let platform: InstallPlatform
    public let hasPlatformConfiguration: Bool
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
    public var ssoLaunchArgument: String?
    /// Default folder name under /Applications, when the config names one.
    public var folderName: String?
    /// Games stored as loose files only, with no local CASC storage (Hearthstone).
    public var isContainerless: Bool

    public init(json data: Data, platform: InstallPlatform = .macOS) throws {
        self.platform = platform
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TACTError.malformed("product config")
        }
        let all = (root["all"] as? [String: Any])?["config"] as? [String: Any] ?? [:]
        let selected = ((root["platform"] as? [String: Any])?[platform.rawValue] as? [String: Any])?["config"] as? [String: Any]
        hasPlatformConfiguration = selected != nil
        if platform == .windows, selected == nil { throw TACTError.malformed("Windows product configuration is missing") }
        let config = selected ?? [:]

        subfolder = all["shared_container_default_subfolder"] as? String ?? ""
        dataDirectory = all["data_dir"] as? String ?? "Data/"
        supportedLocales = all["supported_locales"] as? [String] ?? []
        platformTags = config["tags"] as? [String] ?? [platform.manifestTag]

        var extra: [String] = []
        if let bits64 = config["tags_64bit"] as? [String] {
            // The Agent picks the 64-bit set; WoW's manifests also carry
            // arm64 files for Apple silicon, so take both.
            extra += bits64 + (platform == .macOS ? ["arm64"] : [])
        }
        extra += all["extra_tags"] as? [String] ?? []
        extra += all["noigr_tags"] as? [String] ?? []
        extraTags = extra

        let game = (config["binaries"] as? [String: Any])?["game"] as? [String: Any] ?? [:]
        gameBinary = game["relative_path_64"] as? String ?? game["relative_path"] as? String
        launchArguments = game["launch_arguments"] as? [String]
            ?? config["launch_arguments"] as? [String] ?? all["launch_arguments"] as? [String] ?? []
        ssoLaunchArgument = (config["opaque_product_specific"] as? [String: Any])?["sso_launch_argument"] as? String
            ?? (all["opaque_product_specific"] as? [String: Any])?["sso_launch_argument"] as? String
        folderName = ((config["form"] as? [String: Any])?["game_dir"] as? [String: Any])?["dirname"] as? String
            ?? ((all["form"] as? [String: Any])?["game_dir"] as? [String: Any])?["dirname"] as? String
        isContainerless = (config["update_method"] as? String)?.contains("containerless") == true
            || (all["update_method"] as? String)?.contains("containerless") == true
    }

    /// The tag string the Agent records for an install: a speech group in
    /// the spoken language and a text group in the text language.
    public func tagString(region: Region, languages: GameLanguages) -> String {
        let common = (platformTags + extraTags + ["\(region.launchOptionValue)?"]).joined(separator: " ")
        return "\(common) \(languages.speech) speech?:\(common) \(languages.text) text?"
    }

    public func tagString(region: Region, language: String) -> String {
        tagString(region: region, languages: GameLanguages(text: language))
    }
}

extension VersionService {
    /// Fetches and parses a product's config for the given live version.
    public func productConfig(product: String, region: Region, version given: ProductVersion? = nil,
                              platform: InstallPlatform, cacheDirectory: URL = CDNClient.defaultCacheDirectory) async throws -> ProductConfig {
        let version: ProductVersion
        if let given { version = given } else { version = try await latest(product: product, region: region) }
        guard let hash = version.productConfig, !hash.isEmpty else { throw TACTError.notFound("\(product) product config") }
        var cdn = try await cdn(product: product, region: region)
        cdn.cacheDirectory = cacheDirectory
        let data = try await cdn.cachedConfigFile(hash, path: cdn.configPath ?? "tpr/configs/data")
        return try ProductConfig(json: data, platform: platform)
    }
}
