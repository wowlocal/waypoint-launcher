import CryptoKit
import Foundation

/// Synchronous lookups for launch/install code, backed by a periodically
/// refreshed Blizzard catalog. The last successful discoveries survive restarts
/// and failed requests; no network request is needed to launch a game.
public final class ProductCatalog: @unchecked Sendable {
    public static let shared = ProductCatalog()
    private let lock = NSLock()
    private let file: URL
    private var snapshot: Snapshot
    private var refreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Snapshot: Codable {
        var products: [InstallableProduct] = []
        var checkedAt: Date = .distantPast
        var region: Region? = nil
        /// Region -> canonical fragment name -> currently offered products.
        /// Metadata above survives retirement so existing installs still work.
        var availableByRegion: [String: [String: [String]]]? = nil
    }

    public init(file: URL = ProductCatalog.defaultFile) {
        self.file = file
        snapshot = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.waypoint.launcher/catalog-v1.json")
    }

    public var nativeProducts: [InstallableProduct] {
        lock.withLock { Self.merging(InstallableProduct.fallbackNative, snapshot.products) }
    }

    public func availableNativeProducts(region: Region) -> [InstallableProduct] {
        lock.withLock {
            let products = Self.merging(InstallableProduct.fallbackNative, snapshot.products)
            let codes: Set<String>
            if let fragments = snapshot.availableByRegion?[region.rawValue] {
                codes = Set(fragments.values.flatMap { $0 })
            } else {
                codes = Set(InstallableProduct.fallbackNative.map(\.productCode))
            }
            return products.filter { codes.contains($0.productCode) }
        }
    }

    static func merging(_ old: [InstallableProduct], _ new: [InstallableProduct]) -> [InstallableProduct] {
        var result = old
        for product in new {
            if let index = result.firstIndex(where: { $0.productCode == product.productCode }) {
                result[index] = product
            } else {
                result.append(product)
            }
        }
        return result
    }

    public func refresh(region: Region, force: Bool = false,
                        service: LauncherCatalogService = LauncherCatalogService()) async throws {
        // A size check for a different region must await an in-flight refresh,
        // then fetch its own region rather than consulting the bundled fallback.
        while true {
            try Task.checkCancellation()
            let decision = lock.withLock {
                if refreshing { return 0 }
                if !force, snapshot.region == region, Date().timeIntervalSince(snapshot.checkedAt) <= 60 * 60 { return 1 }
                refreshing = true
                return 2
            }
            if decision == 1 { return }
            if decision == 2 { break }
            await withCheckedContinuation { continuation in
                let waiting = lock.withLock {
                    if refreshing { refreshWaiters.append(continuation); return true }
                    return false
                }
                if !waiting { continuation.resume() }
            }
        }
        defer {
            let waiters = lock.withLock {
                refreshing = false
                let waiting = refreshWaiters
                refreshWaiters.removeAll()
                return waiting
            }
            for waiter in waiters { waiter.resume() }
        }
        let discovery = try await service.discover(region: region)
        let updated = lock.withLock {
            let previous = snapshot.availableByRegion?[region.rawValue] ?? [:]
            var available = discovery.availableByFragment
            for fragment in discovery.failedFragments {
                available[fragment] = previous[fragment] ?? []
            }
            // A parsed live entry with an unavailable CDN retains its earlier
            // offer. An explicitly removed, disabled or non-Mac entry does not.
            for (fragment, codes) in available {
                let old = Set(previous[fragment] ?? [])
                available[fragment] = codes.filter { !discovery.failedProducts.contains($0) || old.contains($0) }
            }
            var byRegion = snapshot.availableByRegion ?? [:]
            byRegion[region.rawValue] = available
            return Snapshot(products: Self.merging(snapshot.products, discovery.products), checkedAt: Date(), region: region,
                            availableByRegion: byRegion)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        lock.withLock { snapshot = updated }
        Log.info(.library, "catalog_refreshed", nil, ["products": discovery.products.count, "region": region.rawValue])
    }

    public func validateDownload(_ product: InstallableProduct, region: Region, platform: InstallPlatform,
                                 service: LauncherCatalogService = LauncherCatalogService()) async throws {
        guard platform == .macOS else { return }
        try await refresh(region: region, service: service)
        guard availableNativeProducts(region: region).contains(where: { $0.productCode == product.productCode }) else {
            throw CatalogAvailabilityError(game: product.displayName, region: region)
        }
    }
}

struct CatalogAvailabilityError: LocalizedError {
    var game: String
    var region: Region
    var errorDescription: String? { "\(game) is not available for macOS in \(region.displayName). Choose another region." }
}

/// The same catalog the Battle.net launcher uses. Only live versions within
/// Waypoint's supported game families are offered. Windows compatibility stays
/// governed by WindowsTitle; publishing a new variant cannot enable Wine support.
public struct LauncherCatalogService: Sendable {
    public var versions: VersionService
    public var cacheDirectory: URL

    public init(versions: VersionService = VersionService(), cacheDirectory: URL = CDNClient.defaultCacheDirectory) {
        self.versions = versions
        self.cacheDirectory = cacheDirectory
    }

    public func products(region: Region) async throws -> [InstallableProduct] {
        try await discover(region: region).products
    }

    struct Discovery: Sendable {
        var products: [InstallableProduct]
        var availableByFragment: [String: [String]]
        var failedFragments: Set<String>
        var failedProducts: Set<String>
    }

    private enum Resolution: Sendable {
        case native(InstallableProduct)
        case unsupported
    }

    func discover(region: Region) async throws -> Discovery {
        let table = try await versions.table(product: "catalogs", file: "versions", region: region)
        // PUB-N is the launcher's catalog schema, not a geographic region.
        let published = table.rows.compactMap { row -> (Int, String)? in
            guard let channel = row["Region"], channel.hasPrefix("PUB-"),
                  let number = Int(channel.dropFirst(4)), let hash = row["BuildConfig"], CatalogDocument.isHash(hash)
            else { return nil }
            return (number, hash)
        }.max { $0.0 < $1.0 }
        guard let published else { throw TACTError.notFound("published launcher catalog") }
        var cdn = try await versions.cdn(product: "catalogs", region: region)
        cdn.cacheDirectory = cacheDirectory
        let build = TACTConfig(String(decoding: try await cdn.cached(.config, published.1), as: UTF8.self))
        guard let hash = build["root"].first, CatalogDocument.isHash(hash) else { throw TACTError.malformed("catalog root") }
        let catalog = try CatalogDocument(data: await cdn.cached(.data, hash))
        let mirror = cdn
        let supported = Set(InstallableProduct.fallbackNative.map(\.codename))
        let fragments = catalog.fragments(for: region)
        let overrides = try await Self.map(fragments.filter(\.isConditional)) { fragment in
            try await mirror.cached(.data, fragment.hash)
        }
        // A missing compatibility override must not enable a disabled game.
        guard overrides.allSatisfy({ $0.1 != nil }) else { throw TACTError.notFound("catalog compatibility overrides") }
        let overlayData = overrides.sorted { $0.0.order < $1.0.order }.compactMap { $0.1 }
        let groups = try await Self.map(fragments.filter { !$0.isConditional }) { fragment in
            let data = try await mirror.cached(.data, fragment.hash)
            return try catalog.entries(in: data, region: region, supportedCodenames: supported, overrides: overlayData)
        }
        let entries = groups.flatMap { $0.1 ?? [] }.sorted { $0.productCode < $1.productCode }
        let resolutions = try await Self.map(entries) { entry -> Resolution in
            let config = try await versions.productConfig(product: entry.productCode, region: region, platform: .macOS,
                                                          cacheDirectory: cacheDirectory)
            return entry.product(config: config).map(Resolution.native) ?? .unsupported
        }
        var products: [InstallableProduct] = []
        var offered: Set<String> = [], failedProducts: Set<String> = []
        for (entry, resolution) in resolutions {
            switch resolution {
            case .native(let product): products.append(product); offered.insert(entry.productCode)
            case .unsupported: break
            case nil: failedProducts.insert(entry.productCode); offered.insert(entry.productCode)
            }
        }
        let failedFragments = Set(groups.filter { $0.1 == nil }.map { $0.0.name })
        if products.isEmpty, !failedProducts.isEmpty || !failedFragments.isEmpty {
            throw TACTError.notFound("supported macOS games in launcher catalog")
        }
        var availability: [String: [String]] = [:]
        for (fragment, entries) in groups {
            if let entries { availability[fragment.name] = entries.map(\.productCode).filter { offered.contains($0) } }
        }
        return Discovery(products: ProductCatalog.merging([], products), availableByFragment: availability,
                         failedFragments: failedFragments, failedProducts: failedProducts)
    }

    /// Bound concurrency and isolate a broken fragment/product without hiding
    /// other games. Cancellation still leaves immediately.
    private static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [(Input, Output?)] {
        try await withThrowingTaskGroup(of: (Input, Output?).self) { group in
            var remaining = inputs.makeIterator()
            func add(_ input: Input) {
                group.addTask {
                    do { return (input, try await operation(input)) }
                    catch {
                        if Task.isCancelled || NetworkRetry.isCancellation(error) { throw error }
                        Log.warning(.library, "catalog_entry_unavailable", nil, ["error": error])
                        return (input, nil)
                    }
                }
            }
            for _ in 0..<6 { if let input = remaining.next() { add(input) } }
            var result: [(Input, Output?)] = []
            while let output = try await group.next() {
                result.append(output)
                if let input = remaining.next() { add(input) }
            }
            return result
        }
    }
}

/// Only the catalog fields needed to turn a live launcher entry into an
/// installable product. Canonical definitions are combined with applicable
/// Mac/region overrides. Account-specific conditions are left to Battle.net.
struct CatalogDocument: Sendable {
    struct Fragment: Sendable {
        var hash: String
        var name: String
        var order: Int
        var condition: Data?
        var isConditional: Bool { condition != nil }
    }

    struct Entry: Sendable {
        var uid: String
        var productCode: String
        var displayName: String
        var codename: String
        var ssoArgument: String?
        var artwork: ProductArtwork? = nil

        func product(config: ProductConfig) -> InstallableProduct? {
            guard config.hasPlatformConfiguration,
                  let binary = config.gameBinary, binary.hasSuffix(".app"), CatalogDocument.isRelativePath(binary),
                  config.subfolder.isEmpty || CatalogDocument.isRelativePath(config.subfolder),
                  let folder = config.folderName, CatalogDocument.isRelativePath(folder), !folder.contains("/"),
                  !config.supportedLocales.isEmpty else { return nil }
            var arguments = config.launchArguments
            if let sso = ssoArgument ?? config.ssoLaunchArgument, !sso.isEmpty, !arguments.contains(sso) { arguments.insert(sso, at: 0) }
            return InstallableProduct(uid: uid, productCode: productCode, displayName: displayName, folderName: folder,
                codename: codename, appPath: ([config.subfolder, binary].filter { !$0.isEmpty }).joined(separator: "/"),
                launchArguments: arguments, flavorFolder: config.subfolder.isEmpty ? nil : config.subfolder,
                isContainerless: config.isContainerless, languages: config.supportedLocales, artwork: artwork)
        }
    }

    private var allFragments: [Fragment]
    private var strings: [String: String]
    private var typeCategories: [String: String]
    private var liveCategories: Set<String>
    private var files: [String: String]

    init(data: Data) throws {
        let root = try Self.object(data)
        guard let fragments = root["fragments"] as? [[String: Any]] else { throw TACTError.malformed("catalog fragments") }
        self.allFragments = fragments.enumerated().compactMap { index, fragment in
            guard fragment["decryption_key_id"] == nil,
                  let hash = fragment["hash"] as? String, Self.isHash(hash),
                  let name = fragment["name"] as? String else { return nil }
            if let requirement = fragment["requires"], !(requirement is [String: Any]), !(requirement is Bool) { return nil }
            return Fragment(hash: hash, name: name, order: index,
                            condition: fragment["requires"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) })
        }
        strings = Self.strings(in: root)
        typeCategories = Self.categories(in: root)
        liveCategories = Self.liveCategories(in: root)
        files = Self.files(in: root)
    }

    func fragments(for region: Region) -> [Fragment] {
        allFragments.filter { fragment in
            guard let condition = fragment.condition else { return true }
            guard let value = try? JSONSerialization.jsonObject(with: condition, options: .fragmentsAllowed) else { return false }
            if let flag = value as? Bool { return flag }
            return (value as? [String: Any]).flatMap { Self.matches($0, region: region) } == true
        }
    }

    func entries(in data: Data, region: Region, supportedCodenames: Set<String>, overrides: [Data] = []) throws -> [Entry] {
        var root = try Self.object(data)
        let ids = Set((root["products"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        for data in overrides {
            var override = try Self.object(data)
            if let products = override["products"] as? [[String: Any]] {
                let relevant = products.filter { ($0["id"] as? String).map(ids.contains) == true }
                if relevant.isEmpty { continue }
                override["products"] = relevant
            }
            root = Self.merge(root, override)
        }
        let strings = strings.merging(Self.strings(in: root)) { _, new in new }
        let categories = typeCategories.merging(Self.categories(in: root)) { _, new in new }
        let live = liveCategories.union(Self.liveCategories(in: root))
        let installs = root["installs"] as? [String: [String: Any]] ?? [:]
        let files = files.merging(Self.files(in: root)) { _, new in new }
        // A type may show as another product: WoW's Classic flavors do.
        let bases = (root["products"] as? [[String: Any]] ?? []).reduce(into: [String: [String: Any]]()) { result, product in
            if let id = product["id"] as? String, let base = product["base"] as? [String: Any] { result[id] = base }
        }
        var result: [Entry] = []
        for product in root["products"] as? [[String: Any]] ?? [] {
            guard let base = product["base"] as? [String: Any], let codename = base["program_id"] as? String,
                  supportedCodenames.contains(codename), base["hidden"] as? Bool != true,
                  base["deprecated"] as? Bool != true else { continue }
            for (typeID, type) in base["types"] as? [String: [String: Any]] ?? [:] {
                guard let category = categories[typeID], live.contains(category),
                      type["hidden"] as? Bool != true, type["deprecated"] as? Bool != true,
                      let uid = type["uid"] as? String ?? base["uid"] as? String,
                      let install = installs[uid], install["deprecated"] as? Bool != true,
                      let code = install["tact_product"] as? String, Self.isProductCode(code), Self.isProductCode(uid)
                else { continue }
                if let regions = type["supported_regions"] as? [String] ?? base["supported_regions"] as? [String],
                   !regions.contains(where: { $0.lowercased() == region.rawValue }) { continue }
                if Self.isDisabled(Self.merge(base, type), region: region, strings: strings) { continue }
                let nameKey = type["selector_display_name"] as? String ?? type["name"] as? String ?? base["name"] as? String
                guard let nameKey, let name = strings[nameKey] ?? (nameKey.contains("#") ? nil : nameKey), !name.isEmpty else { continue }
                let shownAs = (type["override_product_id"] as? String).flatMap { bases[$0] }
                result.append(Entry(uid: uid, productCode: code, displayName: name, codename: codename,
                                    ssoArgument: install["sso_launch_argument"] as? String,
                                    artwork: Self.artwork(type: type, base: base, shownAs: shownAs, files: files)))
            }
        }
        return result
    }

    /// Three-valued matching: account/country/client conditions cannot be
    /// inferred from the selected game region, including under negation.
    private static func matches(_ condition: [String: Any], region: Region) -> Bool? {
        if let all = condition["all_of"] as? [[String: Any]] {
            let values = all.map { matches($0, region: region) }
            if values.contains(false) { return false }
            return values.allSatisfy { $0 == true } ? true : nil
        }
        if let any = condition["any_of"] as? [[String: Any]] {
            let values = any.map { matches($0, region: region) }
            if values.contains(true) { return true }
            return values.allSatisfy { $0 == false } ? false : nil
        }
        if let negated = condition["not"] as? [String: Any] { return matches(negated, region: region).map { !$0 } }
        switch condition["type"] as? String {
        case "login_region":
            func values(_ key: String) -> [String]? {
                (condition[key] as? [String] ?? (condition[key] as? String).map { [$0] })?.map { $0.lowercased() }
            }
            if let include = values("include"), !include.contains(region.rawValue) { return false }
            if let exclude = values("exclude"), exclude.contains(region.rawValue) { return false }
            return condition["include"] != nil || condition["exclude"] != nil ? true : nil
        case "platform":
            return (condition["platform"] as? String).map { $0 == "mac" }
        default: return nil
        }
    }

    /// Catalog overlays merge dictionaries and records by id. Scalar lists
    /// (regions, arguments, etc.) replace their earlier value.
    private static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        base.merging(overlay) { old, new in
            if let old = old as? [String: Any], let new = new as? [String: Any] { return merge(old, new) }
            if var old = old as? [[String: Any]], let new = new as? [[String: Any]], !new.isEmpty,
               new.allSatisfy({ $0["id"] is String }) {
                for item in new {
                    if let index = old.firstIndex(where: { $0["id"] as? String == item["id"] as? String }) {
                        old[index] = merge(old[index], item)
                    } else { old.append(item) }
                }
                return old
            }
            return new
        }
    }

    private static func isDisabled(_ attributes: [String: Any], region: Region, strings: [String: String]) -> Bool {
        if attributes["install_disabled"] as? Bool == true { return true }
        if let message = attributes["install_disabled_message"] as? String, !(strings[message] ?? message).isEmpty { return true }
        if let flags = attributes["region_permission_flags"] as? [String: Any] {
            var permission = flags["default"] as? String
            for override in flags["overrides"] as? [[String: Any]] ?? [] where override["override_type"] as? String == "region" {
                permission = override[region.rawValue.uppercased()] as? String ?? permission
            }
            if permission?.hasPrefix("disabled") == true { return true }
        }
        return false
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TACTError.malformed("launcher catalog JSON") }
        return root
    }

    private static func definitions(_ key: String, in root: [String: Any]) -> [[String: Any]] {
        (root[key] as? [String: Any])?["definitions"] as? [[String: Any]] ?? []
    }

    private static func categories(in root: [String: Any]) -> [String: String] {
        definitions("types", in: root).reduce(into: [:]) { result, type in
            if let id = type["id"] as? String, let category = type["category"] as? String { result[id] = category }
        }
    }

    private static func liveCategories(in root: [String: Any]) -> Set<String> {
        Set(definitions("categories", in: root).compactMap {
            $0["name"] as? String == "default#CATEGORIES_LIVE_NAME" ? $0["id"] as? String : nil
        })
    }

    /// File id (`hearthstone#HS_KEY_ART`) -> content hash, of the file
    /// for every language. Some have versions per language (Japanese and
    /// Chinese box art); those aren't used.
    private static func files(in root: [String: Any]) -> [String: String] {
        let files = (root["files"] as? [String: Any])?["default"] as? [String: Any] ?? [:]
        return files.reduce(into: [:]) { result, file in
            if let hash = (file.value as? [String: Any])?["hash"] as? String, isHash(hash) { result[file.key] = hash }
        }
    }

    /// A type's own picture where it has one (WoW's Classic flavors have
    /// only the one their install screen shows), else its product's key art.
    /// The icon is the vector one, sharp at any size.
    private static func artwork(type: [String: Any], base: [String: Any], shownAs: [String: Any]?,
                                files: [String: String]) -> ProductArtwork? {
        func hash(_ id: Any?) -> String? { (id as? String).flatMap { files[$0] } }
        let keyArt = hash(type["key_art"]) ?? hash(type["install_background"]) ?? hash(shownAs?["key_art"]) ?? hash(base["key_art"])
        let icon = hash(type["icon_svg"]) ?? hash(shownAs?["icon_svg"]) ?? hash(base["icon_svg"])
        return keyArt == nil && icon == nil ? nil : ProductArtwork(keyArt: keyArt, icon: icon)
    }

    private static func strings(in root: [String: Any]) -> [String: String] {
        let strings = root["strings"] as? [String: [String: String]] ?? [:]
        return (strings["default"] ?? [:]).merging(strings["enUS"] ?? [:]) { _, english in english }
    }

    static func isHash(_ value: String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func isProductCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
    }
    static func isRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0") &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// A game's pictures in Blizzard's launcher catalog: the content hashes
/// (MD5) of files on the catalog's CDN, which are also their names there.
public struct ProductArtwork: Sendable, Equatable, Codable {
    /// Box art, taller than wide.
    public var keyArt: String?
    /// The game's emblem, as SVG.
    public var icon: String?

    public init(keyArt: String? = nil, icon: String? = nil) {
        self.keyArt = keyArt
        self.icon = icon
    }
}

/// The catalog's pictures on this Mac, each in a file named by its hash.
/// Nothing ships with Waypoint: they come from the CDN the catalog itself
/// comes from, once, and are checked against their hash.
public struct ArtworkCache: Sendable {
    public var directory: URL
    /// The largest file worth keeping; the catalog's are under 2 MB.
    static let largest = 16 << 20

    public init(directory: URL = CDNClient.defaultCacheDirectory.deletingLastPathComponent().appendingPathComponent("artwork", isDirectory: true)) {
        self.directory = directory
    }

    /// The file for `hash`, if it has been downloaded.
    public func file(_ hash: String) -> URL? {
        guard CatalogDocument.isHash(hash) else { return nil }
        let file = directory.appendingPathComponent(hash)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Deletes every downloaded picture.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Downloads those of `hashes` that aren't here yet, calling `arrived`
    /// with each as it is saved. Returns the ones that failed: not found,
    /// too large, or not what their hash says. A failure to reach the CDN at
    /// all fails none of them; they are simply still missing.
    @discardableResult
    public func download(_ hashes: Set<String>, region: Region, versions: VersionService = VersionService(),
                         arrived: @Sendable (String) -> Void = { _ in }) async -> Set<String> {
        let missing = hashes.filter { CatalogDocument.isHash($0) && file($0) == nil }.sorted()
        guard !missing.isEmpty else { return [] }
        let fm = FileManager.default
        var saved = 0
        var failed: Set<String> = []
        do {
            let cdn = try await versions.cdn(product: "catalogs", region: region)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for hash in missing {
                try Task.checkCancellation()
                do {
                    let temporary = try await cdn.download(.data, hash)
                    defer { try? fm.removeItem(at: temporary) }
                    let size = (try? fm.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
                    guard size > 0, size <= Self.largest, let data = try? Data(contentsOf: temporary),
                          Insecure.MD5.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                        throw TACTError.checksumMismatch(hash)
                    }
                    try data.write(to: directory.appendingPathComponent(hash), options: .atomic)
                    saved += 1
                    arrived(hash)
                } catch {
                    if Task.isCancelled || NetworkRetry.isCancellation(error) { throw error }
                    failed.insert(hash)
                    Log.warning(.library, "artwork_unavailable", nil, ["hash": hash, "error": error])
                }
            }
        } catch {
            if !(Task.isCancelled || NetworkRetry.isCancellation(error)) {
                Log.warning(.library, "artwork_download_failed", nil, ["error": error])
            }
        }
        if saved > 0 { Log.info(.library, "artwork_downloaded", nil, ["files": saved, "of": missing.count]) }
        return failed
    }
}
