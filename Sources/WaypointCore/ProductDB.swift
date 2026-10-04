import Foundation

/// One installed product as recorded by the Battle.net Agent.
public struct ProductInstall: Equatable, Sendable {
    /// Install uid, e.g. `hs_beta`, `wow`, `wow_classic`. This is what Battle.net
    /// passes to games as `-uid`.
    public var uid: String
    /// TACT product code, e.g. `hsb`, `wow`, `wow_classic_era`.
    public var productCode: String
    public var installPath: String
    /// Region the game was installed for: `eu`, `us`, `kr`, `cn`.
    public var region: String?
    public var textLanguage: String?
    public var version: String?
    /// Build config hash of the installed build.
    public var buildConfig: String?
    /// Install tags Battle.net selected, e.g. `OSX base … EU? enUS speech?:… enUS text?`.
    public var tagString: String?

    public init(uid: String, productCode: String, installPath: String,
                region: String? = nil, textLanguage: String? = nil, version: String? = nil,
                buildConfig: String? = nil, tagString: String? = nil) {
        self.uid = uid
        self.productCode = productCode
        self.installPath = installPath
        self.region = region
        self.textLanguage = textLanguage
        self.version = version
        self.buildConfig = buildConfig
        self.tagString = tagString
    }
}

/// Reader for Battle.net's `product.db` (Agent-wide list of installs) and the
/// per-install `.product.db` that sits in every game folder.
///
/// Field numbers were taken from the files on disk:
///   Database        { repeated ProductInstall installs = 1; }
///   ProductInstall  { uid = 1; product_code = 2; UserSettings settings = 3;
///                     CachedProductState cached_product_state = 4; }
///   UserSettings    { install_path = 1; play_region = 2; selected_text_language = 6; }
///   CachedProductState { BaseProductState base_product_state = 1; }
///   BaseProductState   { current_version_str = 7; completed_build_keys = 12;
///                        active_build_key = 14; active_tag_string = 17; }
public enum ProductDB {
    public static let agentDatabaseURL = URL(fileURLWithPath: "/Users/Shared/Battle.net/Agent/product.db")

    /// Products that are part of Battle.net itself, not games.
    static let infrastructureCodes: Set<String> = ["agent", "bna"]

    public static func loadAgentDatabase(at url: URL = agentDatabaseURL) throws -> [ProductInstall] {
        try parseDatabase(Data(contentsOf: url))
    }

    public static func parseDatabase(_ data: Data) throws -> [ProductInstall] {
        let fields = try ProtoReader(data).fields()
        return try (fields[1] ?? []).compactMap { value in
            guard let message = value.message else { return nil }
            return try parseInstall(message)
        }
        .filter { !infrastructureCodes.contains($0.productCode) }
    }

    /// Parses the `.product.db` found inside a game's install folder.
    public static func parseInstallFile(_ data: Data) throws -> ProductInstall? {
        try parseInstall(ProtoReader(data))
    }

    static func parseInstall(_ reader: ProtoReader) throws -> ProductInstall? {
        let fields = try reader.fields()
        guard let uid = fields[1]?.first?.string,
              let code = fields[2]?.first?.string,
              let settings = try fields[3]?.first?.message?.fields(),
              let path = settings[1]?.first?.string, !path.isEmpty
        else { return nil }

        let state = try fields[4]?.first?.message?.fields()[1]?.first?.message?.fields() ?? [:]

        return ProductInstall(
            uid: uid,
            productCode: code,
            installPath: path,
            region: settings[2]?.first?.string.nonEmpty,
            textLanguage: settings[6]?.first?.string.nonEmpty,
            version: state[7]?.first?.string.nonEmpty,
            buildConfig: state[14]?.first?.string.nonEmpty ?? state[12]?.last?.string.nonEmpty,
            tagString: state[17]?.first?.string.nonEmpty
        )
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        switch self {
        case .some(let s) where !s.isEmpty: return s
        default: return nil
        }
    }
}
