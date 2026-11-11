import Foundation
import Testing
@testable import WaypointCore

// Reduced, unmodified fields from Blizzard's PUB-30 catalog and its WoW
// fragment/product configs, fetched 2026-11-04. No network in ordinary tests.
private func catalogFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Catalog/\(name).json"))
}

@Test func catalogFindsLiveMacVersionsAndTheirLauncherMetadata() throws {
    let document = try CatalogDocument(data: catalogFixture("root"))
    let entries = try document.entries(in: catalogFixture("world-of-warcraft"), region: .eu, supportedCodenames: ["WoW"])
    #expect(Set(entries.map(\.productCode)) == ["wow", "wowf"])
    let entry = try #require(entries.first { $0.productCode == "wowf" })
    let config = try ProductConfig(json: catalogFixture("wowf-product"))
    let product = try #require(entry.product(config: config))
    #expect(product.uid == "wowf")
    #expect(product.displayName == "WoW: Forever")
    #expect(product.codename == "WoW")
    #expect(product.folderName == "World of Warcraft")
    #expect(product.appPath == "_forever_/World of Warcraft.app")
    #expect(product.flavorFolder == "_forever_")
    #expect(product.launchArguments == ["-launcherlogin"])
    #expect(product.languages.contains("ruRU"))
    #expect(product.supportedPlatforms == [.macOS])
}

@Test func catalogDiscoversUnlistedFutureVersionsWithoutCodeChanges() throws {
    var fragment = try #require(JSONSerialization.jsonObject(with: catalogFixture("world-of-warcraft")) as? [String: Any])
    var products = try #require(fragment["products"] as? [[String: Any]])
    var base = try #require(products[0]["base"] as? [String: Any])
    var types = try #require(base["types"] as? [String: [String: Any]])
    types["future_release"] = ["uid": "wow_future_uid", "name": "A Future WoW", "supported_regions": ["EU"]]
    base["types"] = types
    products[0]["base"] = base
    fragment["products"] = products
    var installs = try #require(fragment["installs"] as? [String: [String: Any]])
    installs["wow_future_uid"] = ["tact_product": "wow_new_release", "sso_launch_argument": "-launcherlogin"]
    fragment["installs"] = installs
    var definitions = try #require(fragment["types"] as? [String: Any])
    var list = try #require(definitions["definitions"] as? [[String: Any]])
    list.append(["id": "future_release", "category": "cat_wow_forever"])
    definitions["definitions"] = list
    fragment["types"] = definitions
    let data = try JSONSerialization.data(withJSONObject: fragment)
    let document = try CatalogDocument(data: catalogFixture("root"))
    let eu = try document.entries(in: data, region: .eu, supportedCodenames: ["WoW"])
    let future = try #require(eu.first { $0.productCode == "wow_new_release" })
    #expect(future.uid == "wow_future_uid")
    #expect(future.displayName == "A Future WoW")
    #expect(try !document.entries(in: data, region: .us, supportedCodenames: ["WoW"]).contains { $0.productCode == future.productCode })
    #expect(try document.entries(in: data, region: .eu, supportedCodenames: ["W3"]).isEmpty)
}

@Test func catalogRejectsConditionalFragmentsAndUnsafeOrNonMacLayouts() throws {
    let root = Data(#"{"fragments":[{"name":"base","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"account","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","requires":{"type":"account"}},{"name":"private","hash":"cccccccccccccccccccccccccccccccc","decryption_key_id":"private"},{"name":"bad","hash":"../bad"}]}"#.utf8)
    #expect(try CatalogDocument(data: root).fragments(for: .eu).map(\.hash) == [String(repeating: "a", count: 32)])
    let document = try CatalogDocument(data: catalogFixture("root"))
    let entries = try document.entries(in: catalogFixture("world-of-warcraft"), region: .eu, supportedCodenames: ["WoW"])
    let entry = try #require(entries.first)
    var config = try ProductConfig(json: catalogFixture("wowf-product"))
    config.subfolder = "../other-game"
    #expect(entry.product(config: config) == nil)
    config.subfolder = "_future_"
    config.gameBinary = "/Applications/Other.app"
    #expect(entry.product(config: config) == nil)
    let noMac = try ProductConfig(json: Data(#"{"all":{"config":{"supported_locales":["enUS"]}},"platform":{"win":{"config":{}}}}"#.utf8))
    #expect(entry.product(config: noMac) == nil)
}

@Test func discoveredProductsKeepTheProductConfigsSSOArgument() throws {
    let json = Data(#"{"all":{"config":{"form":{"game_dir":{"dirname":"StarCraft II"}},"supported_locales":["enUS"],"opaque_product_specific":{"sso_launch_argument":"-sso=1"}}},"platform":{"mac":{"config":{"binaries":{"game":{"relative_path":"Support/SC2Switcher.app","launch_arguments":["-launch"]}}}}}}"#.utf8)
    let config = try ProductConfig(json: json)
    var entry = CatalogDocument.Entry(uid: "s2", productCode: "s2", displayName: "StarCraft II", codename: "S2")
    #expect(entry.product(config: config)?.launchArguments == ["-sso=1", "-launch"])
    entry.ssoArgument = "-sso=1"
    #expect(entry.product(config: config)?.launchArguments == ["-sso=1", "-launch"])
}

/// Serves the patch tables and content-addressed CDN files. Unexpected requests
/// get a real 404, so tests catch wrong channels, paths and product codes.
private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    static let buildHash = String(repeating: "1", count: 32)
    static let rootHash = String(repeating: "2", count: 32)
    static let fragmentHash = "1193d9029eb9222f9bb52f2ca484586d"
    static let configHashes = ["wow": "53020d32e1a25648c8e1eafd5771935f", "wowf": "0d21f2f209a32c57f8c9b838cb35fd0a"]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let path = request.url!.path
            let mode = request.value(forHTTPHeaderField: "X-Catalog-Test-Mode")
            if mode == "offline" || (mode == "missing-forever" && path == "/v2/products/wowf/versions") {
                throw URLError(.notConnectedToInternet)
            }
            let body: Data?
            if path == "/v2/products/catalogs/versions" {
                body = Data("Region!STRING:0|BuildConfig!HEX:16\nPUB-30|\(Self.buildHash)\nPUB-29|wrong-channel\n".utf8)
            } else if path.hasSuffix("/cdns"), path.hasPrefix("/v2/products/") {
                let product = path.split(separator: "/")[2]
                body = Data(("Name!STRING:0|Path!STRING:0|Servers!STRING:0|ConfigPath!STRING:0\n" + ["us", "eu", "cn", "kr"].map {
                    "\($0)|tpr/\(product == "catalogs" ? "catalogs" : "wow")|https://cdn.test|tpr/configs/data\n"
                }.joined()).utf8)
            } else if path == Self.cdnPath(Self.buildHash, prefix: "tpr/catalogs/config") {
                body = Data("root = \(Self.rootHash)\n".utf8)
            } else if path == Self.cdnPath(Self.rootHash, prefix: "tpr/catalogs/data") {
                body = mode == "removed-fragment" ? Data(#"{"fragments":[]}"#.utf8) : try catalogFixture("root")
            } else if path == Self.cdnPath(Self.fragmentHash, prefix: "tpr/catalogs/data") {
                var fragment = try JSONSerialization.jsonObject(with: catalogFixture("world-of-warcraft")) as! [String: Any]
                if mode == "retired" || mode == "region-excluded" {
                    var products = fragment["products"] as! [[String: Any]]
                    var base = products[0]["base"] as! [String: Any]
                    var types = base["types"] as! [String: [String: Any]]
                    if mode == "retired" { types["wowf"]?["deprecated"] = true }
                    if mode == "region-excluded" { types["wowf"]?["supported_regions"] = ["EU"] }
                    base["types"] = types; products[0]["base"] = base; fragment["products"] = products
                }
                if mode == "windows-art" {
                    // A Windows-only title beside the games Waypoint installs natively.
                    var products = fragment["products"] as! [[String: Any]]
                    products.append(["id": "Fen", "base": ["program_id": "Fen", "key_art": "fenris#KEY_ART", "icon_svg": "fenris#ICON",
                                                           "types": ["retail": ["uid": "fenris"]]]])
                    fragment["products"] = products
                    fragment["files"] = ["default": ["fenris#KEY_ART": ["hash": String(repeating: "1", count: 32)],
                                                     "fenris#ICON": ["hash": String(repeating: "2", count: 32)]]]
                }
                body = try JSONSerialization.data(withJSONObject: fragment)
            } else if let product = Self.configHashes.keys.first(where: { path == "/v2/products/\($0)/versions" }),
                      let hash = Self.configHashes[product] {
                body = Data(("Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|BuildId!DEC:4|VersionsName!STRING:0|ProductConfig!HEX:16\n" + ["us", "eu", "cn", "kr"].map {
                    "\($0)|build|cdn|1|1.0|\(hash)\n"
                }.joined()).utf8)
            } else if let product = Self.configHashes.first(where: { path == Self.cdnPath($0.value, prefix: "tpr/configs/data") })?.key {
                body = try catalogFixture("\(product)-product")
            } else {
                body = nil
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    static func cdnPath(_ hash: String, prefix: String) -> String {
        "/\(prefix)/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)"
    }
}

private func catalogService(cache: URL, mode: String = "ok") -> LauncherCatalogService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Catalog-Test-Mode": mode]
    var versions = VersionService(session: URLSession(configuration: configuration))
    versions.retry.delays = []
    return LauncherCatalogService(versions: versions, cacheDirectory: cache)
}

@Test func catalogRefreshPersistsDiscoveriesAndRetainsThemAcrossFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("catalog.json"), cache = root.appendingPathComponent("cdn")
    let catalog = ProductCatalog(file: file)
    try await catalog.refresh(region: .eu, service: catalogService(cache: cache))
    #expect(catalog.nativeProducts.contains { $0.productCode == "wowf" && $0.flavorFolder == "_forever_" })
    #expect(Set(catalog.availableNativeProducts(region: .eu).map(\.productCode)) == ["wow", "wowf"])
    let offline = ProductCatalog(file: file)
    #expect(offline.nativeProducts == catalog.nativeProducts)
    #expect(offline.availableNativeProducts(region: .eu) == catalog.availableNativeProducts(region: .eu))
    do {
        try await offline.refresh(region: .eu, force: true, service: catalogService(cache: cache, mode: "offline"))
        Issue.record("Expected an offline error")
    } catch {}
    #expect(offline.nativeProducts == catalog.nativeProducts)
    // One unavailable product must not erase its saved metadata or stop the
    // rest of the catalog refreshing successfully.
    try await offline.refresh(region: .eu, force: true, service: catalogService(cache: cache, mode: "missing-forever"))
    #expect(offline.nativeProducts.contains { $0.productCode == "wowf" })
    #expect(offline.availableNativeProducts(region: .eu).contains { $0.productCode == "wowf" })
    #expect(offline.nativeProducts.filter { $0.productCode == "wow" }.count == 1)
}

@Test func catalogRetirementRemovesOffersAndKeepsInstalledGameMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-retirement-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = ProductCatalog(file: root.appendingPathComponent("catalog.json"))
    try await catalog.refresh(region: .eu, service: catalogService(cache: root.appendingPathComponent("initial")))
    try await catalog.refresh(region: .eu, force: true, service: catalogService(cache: root.appendingPathComponent("retired"), mode: "retired"))
    #expect(catalog.availableNativeProducts(region: .eu).map(\.productCode) == ["wow"])
    #expect(catalog.nativeProducts.contains { $0.productCode == "wowf" })
    // Removing an entire fragment is authoritative too.
    try await catalog.refresh(region: .eu, force: true, service: catalogService(cache: root.appendingPathComponent("removed"), mode: "removed-fragment"))
    #expect(catalog.availableNativeProducts(region: .eu).isEmpty)
    #expect(catalog.nativeProducts.contains { $0.productCode == "wow" })
}

@Test func catalogAvailabilityIsSavedSeparatelyForEachRegion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-regions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("catalog.json")
    let catalog = ProductCatalog(file: file)
    try await catalog.refresh(region: .eu, service: catalogService(cache: root.appendingPathComponent("eu")))
    try await catalog.refresh(region: .cn, service: catalogService(cache: root.appendingPathComponent("cn"), mode: "region-excluded"))
    let saved = ProductCatalog(file: file)
    #expect(saved.availableNativeProducts(region: .cn).map(\.productCode) == ["wow"])
    #expect(Set(saved.availableNativeProducts(region: .eu).map(\.productCode)) == ["wow", "wowf"])
    #expect(!saved.availableNativeProducts(region: .cn).contains { $0.productCode == "d3" })
    #expect(saved.nativeProducts.contains { $0.productCode == "d3" })
}

@Test func catalogAppliesMacRegionOverridesAndDisabledPermissions() throws {
    let root = Data(#"{"fragments":[{"name":"base","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"cnmac","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","requires":{"all_of":[{"type":"login_region","include":"CN"},{"type":"platform","platform":"mac"}]}},{"name":"unknown","hash":"cccccccccccccccccccccccccccccccc","requires":{"not":{"type":"account_country","include":"CN"}}}]}"#.utf8)
    let selector = try CatalogDocument(data: root)
    #expect(selector.fragments(for: .eu).map(\.name) == ["base"])
    #expect(selector.fragments(for: .cn).map(\.name) == ["base", "cnmac"])
    let document = try CatalogDocument(data: catalogFixture("root"))
    let disabled = Data(#"{"products":[{"id":"WoW","base":{"install_disabled_message":"default#UNSUPPORTED_OS_DISABLED_MESSAGE"}}]}"#.utf8)
    #expect(try document.entries(in: catalogFixture("world-of-warcraft"), region: .cn, supportedCodenames: ["WoW"], overrides: [disabled]).isEmpty)
    // A restriction for another game must not alter WoW's availability.
    let unrelated = Data(#"{"products":[{"id":"S2","base":{"install_disabled_message":"default#UNSUPPORTED_OS_DISABLED_MESSAGE"}}]}"#.utf8)
    #expect(try document.entries(in: catalogFixture("world-of-warcraft"), region: .cn, supportedCodenames: ["WoW"], overrides: [unrelated]).count == 2)
    let permissions = Data(#"{"products":[{"id":"WoW","base":{"types":{"wowf":{"region_permission_flags":{"default":"requires_account_visible","overrides":[{"CN":"disabled_invisible","override_type":"region"}]}}}}}]}"#.utf8)
    #expect(try document.entries(in: catalogFixture("world-of-warcraft"), region: .cn, supportedCodenames: ["WoW"], overrides: [permissions]).map(\.productCode) == ["wow"])
    #expect(try document.entries(in: catalogFixture("world-of-warcraft"), region: .eu, supportedCodenames: ["WoW"], overrides: [permissions]).count == 2)
}

@Test func catalogBooleanFragmentConditionsDoNotCrashFoundation() throws {
    let root = Data(#"{"fragments":[{"name":"enabled","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","requires":true},{"name":"disabled","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","requires":false},{"name":"malformed","hash":"cccccccccccccccccccccccccccccccc","requires":"unknown"}]}"#.utf8)
    let document = try CatalogDocument(data: root)
    #expect(document.fragments(for: .eu).map(\.name) == ["enabled"])
    #expect(document.fragments(for: .cn).map(\.name) == ["enabled"])
}

@Test func changingAnInstallRegionRevalidatesAvailabilityDuringConcurrentRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-validation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = ProductCatalog(file: root.appendingPathComponent("catalog.json"))
    let service = catalogService(cache: root.appendingPathComponent("cdn"), mode: "region-excluded")
    let euRefresh = Task { try await catalog.refresh(region: .eu, service: service) }
    let entry = CatalogDocument.Entry(uid: "wowf", productCode: "wowf", displayName: "WoW: Forever", codename: "WoW")
    let product = try #require(entry.product(config: ProductConfig(json: catalogFixture("wowf-product"))))
    do {
        try await catalog.validateDownload(product, region: .cn, platform: .macOS, service: service)
        Issue.record("Changing to an excluded region must prevent planning/installing")
    } catch {
        #expect(error is CatalogAvailabilityError)
    }
    try await euRefresh.value
    try await catalog.validateDownload(product, region: .eu, platform: .macOS, service: service)
    #expect(catalog.availableNativeProducts(region: .cn).map(\.productCode) == ["wow"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WAYPOINT_NETWORK_TESTS"] == "1"))
func liveCatalogDiscoversWoWForever() async throws {
    let products = try await LauncherCatalogService().products(region: .eu)
    let forever = try #require(products.first { $0.productCode == "wowf" })
    #expect(forever.appPath == "_forever_/World of Warcraft.app")
    #expect(forever.launchArguments.contains("-launcherlogin"))
    #expect(forever.codename == "WoW")
}

@Test func catalogEntriesCarryTheirPicturesByHash() throws {
    func hash(_ digit: Character) -> String { String(repeating: digit, count: 32) }
    var fragment = try #require(JSONSerialization.jsonObject(with: catalogFixture("world-of-warcraft")) as? [String: Any])
    fragment["files"] = [
        "default": [
            "wow#KEY_ART": ["hash": hash("1")], "wow#ICON": ["hash": hash("2")],
            "wow#FOREVER_INSTALL": ["hash": hash("3")], "wow#FOREVER_ICON": ["hash": hash("4")],
            "wow#NOT_A_HASH": ["hash": "../../etc/passwd"],
        ],
        // Per-language files are not what a row shows.
        "jaJP": ["wow#KEY_ART": ["hash": hash("9")]],
    ]
    var products = try #require(fragment["products"] as? [[String: Any]])
    var base = try #require(products[0]["base"] as? [String: Any])
    base["key_art"] = "wow#KEY_ART"
    base["icon_svg"] = "wow#ICON"
    var types = try #require(base["types"] as? [String: [String: Any]])
    types["wowf"]?["install_background"] = "wow#FOREVER_INSTALL"
    types["wowf"]?["override_product_id"] = "WoWF"
    base["types"] = types
    products[0]["base"] = base
    // The product a flavor shows as: its icon is the flavor's, its key art
    // only stands in where the flavor has no picture of its own.
    products.append(["id": "WoWF", "base": ["icon_svg": "wow#FOREVER_ICON", "key_art": "wow#NOT_A_HASH"]])
    fragment["products"] = products
    let document = try CatalogDocument(data: catalogFixture("root"))
    let entries = try document.entries(in: JSONSerialization.data(withJSONObject: fragment), region: .eu, supportedCodenames: ["WoW"])
    #expect(entries.first { $0.productCode == "wow" }?.artwork == ProductArtwork(keyArt: hash("1"), icon: hash("2")))
    let forever = try #require(entries.first { $0.productCode == "wowf" })
    #expect(forever.artwork == ProductArtwork(keyArt: hash("3"), icon: hash("4")))
    #expect(forever.product(config: try ProductConfig(json: catalogFixture("wowf-product")))?.artwork == forever.artwork)

    // A file whose hash isn't one is as good as absent.
    base["key_art"] = "wow#NOT_A_HASH"
    products[0]["base"] = base
    fragment["products"] = products
    let unnamed = try document.entries(in: JSONSerialization.data(withJSONObject: fragment), region: .eu, supportedCodenames: ["WoW"])
    #expect(unnamed.first { $0.productCode == "wow" }?.artwork == ProductArtwork(keyArt: nil, icon: hash("2")))

    // A catalog without pictures, as the fixture is: no artwork, and a
    // product saved before there was any still decodes.
    let plain = try document.entries(in: catalogFixture("world-of-warcraft"), region: .eu, supportedCodenames: ["WoW"])
    #expect(plain.allSatisfy { $0.artwork == nil })
    var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(InstallableProduct.hearthstone)) as? [String: Any])
    saved["artwork"] = nil
    #expect(try JSONDecoder().decode(InstallableProduct.self, from: JSONSerialization.data(withJSONObject: saved)) == InstallableProduct.hearthstone)
}

@Test func artworkCacheOnlyServesWellNamedFilesItHas() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-artwork-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = ArtworkCache(directory: directory)
    let hash = String(repeating: "a", count: 32)
    #expect(cache.file(hash) == nil)
    try Data("picture".utf8).write(to: directory.appendingPathComponent(hash))
    #expect(cache.file(hash)?.lastPathComponent == hash)
    try Data("other".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    #expect(cache.file("notes.txt") == nil)
    #expect(cache.file("../" + hash) == nil)
    cache.removeAll()
    #expect(cache.file(hash) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func catalogGivesTheWindowsOnlyTitlesTheirPictures() throws {
    func hash(_ digit: Character) -> String { String(repeating: digit, count: 32) }
    let fragment: [String: Any] = [
        "files": ["default": [
            "fenris#KEY_ART": ["hash": hash("1")], "fenris#ICON": ["hash": hash("2")], "fenris#PTR_ART": ["hash": hash("3")],
            "overwatch#INSTALL": ["hash": hash("4")], "overwatch#KEY_ART": ["hash": hash("5")],
        ]],
        "products": [
            // Not a game Waypoint installs from the catalog: its entry is never offered, its pictures are kept.
            ["id": "Fen", "base": ["program_id": "Fen", "key_art": "fenris#KEY_ART", "icon_svg": "fenris#ICON",
                                   "types": ["ptr": ["uid": "fenris_ptr", "key_art": "fenris#PTR_ART"], "retail": ["uid": "fenris"]]]],
            // The version Waypoint installs has pictures of its own.
            ["id": "Pro", "base": ["program_id": "Pro", "key_art": "overwatch#KEY_ART",
                                   "types": ["retail": ["uid": "prometheus", "install_background": "overwatch#INSTALL"]]]],
        ],
    ]
    let document = try CatalogDocument(data: catalogFixture("root"))
    let data = try JSONSerialization.data(withJSONObject: fragment)
    let contents = try document.contents(in: data, region: .eu, supportedCodenames: ["WoW"],
                                         windowsTitles: [.overwatch, .diabloII, .diabloIV])
    #expect(contents.entries.isEmpty)
    #expect(contents.windowsArtwork == [
        "fenris": ProductArtwork(keyArt: hash("1"), icon: hash("2")),
        "pro": ProductArtwork(keyArt: hash("4"), icon: nil),
    ], "by product code; a title the fragment doesn't list has no entry")
    // Only the titles asked for.
    #expect(try document.contents(in: data, region: .eu, supportedCodenames: ["WoW"]).windowsArtwork.isEmpty)

    // Other products can carry the same program id. One without the title's
    // version isn't the title, whichever comes first and whatever it shows.
    var crowded = fragment
    let others: [[String: Any]] = [
        ["id": "FenSpinOff", "base": ["program_id": "Fen", "key_art": "fenris#PTR_ART", "types": ["retail": ["uid": "fenris_spin_off"]]]],
        ["id": "FenBare", "base": ["program_id": "Fen", "types": ["retail": ["uid": "fenris_other"]]]],
    ]
    for products in [others + (fragment["products"] as! [[String: Any]]), (fragment["products"] as! [[String: Any]]) + others] {
        crowded["products"] = products
        let found = try document.contents(in: JSONSerialization.data(withJSONObject: crowded), region: .eu, supportedCodenames: ["WoW"],
                                          windowsTitles: [.diabloIV]).windowsArtwork
        #expect(found == ["fenris": ProductArtwork(keyArt: hash("1"), icon: hash("2"))])
    }
}

@Test func aCatalogRefreshSavesTheWindowsTitlesPicturesAndDropsThoseTheCatalogDropped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-windows-refresh-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("catalog.json")
    let catalog = ProductCatalog(file: file)
    try await catalog.refresh(region: .eu, service: catalogService(cache: root.appendingPathComponent("with"), mode: "windows-art"))
    let pictures = ProductArtwork(keyArt: String(repeating: "1", count: 32), icon: String(repeating: "2", count: 32))
    #expect(catalog.windowsArtwork(productCode: "fenris") == pictures)
    #expect(ProductCatalog(file: file).windowsArtwork(productCode: "fenris") == pictures, "saved with the rest")
    // A refresh that fails leaves them.
    do {
        try await catalog.refresh(region: .eu, force: true, service: catalogService(cache: root.appendingPathComponent("offline"), mode: "offline"))
        Issue.record("Expected an offline error")
    } catch {}
    #expect(catalog.windowsArtwork(productCode: "fenris") == pictures)
    // One that read the whole catalog and found the game gone doesn't.
    try await catalog.refresh(region: .eu, force: true, service: catalogService(cache: root.appendingPathComponent("without")))
    #expect(catalog.windowsArtwork(productCode: "fenris") == nil)
    #expect(ProductCatalog(file: file).windowsArtwork(productCode: "fenris") == nil)
}

@Test func theCatalogRemembersWindowsPicturesAndKnowsWhenItNeverLooked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-catalog-windows-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var product = InstallableProduct.hearthstone
    product.artwork = ProductArtwork(keyArt: String(repeating: "a", count: 32))
    let products = try JSONSerialization.jsonObject(with: JSONEncoder().encode([product]))
    func catalog(_ name: String, _ snapshot: [String: Any]) throws -> ProductCatalog {
        let file = root.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        return ProductCatalog(file: file)
    }
    let pictures = ["keyArt": String(repeating: "b", count: 32), "icon": String(repeating: "c", count: 32)]
    let saved = try catalog("saved.json", ["products": products, "checkedAt": 0, "windowsArtwork": ["fenris": pictures]])
    #expect(saved.windowsArtwork(productCode: "fenris") == ProductArtwork(keyArt: pictures["keyArt"], icon: pictures["icon"]))
    #expect(saved.windowsArtwork(productCode: "pro") == nil)
    #expect(!saved.lacksArtwork)
    // Saved by a version that kept pictures of the native games only.
    let older = try catalog("older.json", ["products": products, "checkedAt": 0])
    #expect(older.nativeProducts.contains { $0.artwork != nil })
    #expect(older.lacksArtwork, "the next refresh reads the catalog again for the Windows titles")
    #expect(older.windowsArtwork(productCode: "fenris") == nil)
    // Looked and found none: not the same as never having looked.
    #expect(try !catalog("none.json", ["products": products, "checkedAt": 0, "windowsArtwork": [String: Any]()]).lacksArtwork)
}
