import Foundation

/// One row of a product's `versions` table.
public struct ProductVersion: Sendable, Equatable, Codable {
    public var region: String
    public var buildConfig: String
    public var cdnConfig: String
    public var buildID: Int
    /// Human-readable version, e.g. `36.6.3.253932.253216`.
    public var name: String
    /// Hash of the product config JSON (layout, binaries, tags).
    public var productConfig: String?
    /// Key ring for encrypted content, when the product has one (WoW).
    public var keyRing: String?

    public init(region: String, buildConfig: String, cdnConfig: String, buildID: Int, name: String,
                productConfig: String? = nil, keyRing: String? = nil) {
        self.region = region
        self.buildConfig = buildConfig
        self.cdnConfig = cdnConfig
        self.buildID = buildID
        self.name = name
        self.productConfig = productConfig
        self.keyRing = keyRing
    }
}

/// Blizzard's patch service: which build is live, and where the CDN is.
public struct VersionService: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latest(product: String, region: Region) async throws -> ProductVersion {
        let table = try await table(product: product, file: "versions", region: region)
        guard let row = table.rows.first(where: { $0["Region"] == region.rawValue }) ?? table.rows.first(where: { $0["Region"] == "us" }),
              let build = row["BuildConfig"], let cdn = row["CDNConfig"], let name = row["VersionsName"]
        else { throw TACTError.notFound("\(product) version for \(region.rawValue)") }
        return ProductVersion(region: row["Region"] ?? region.rawValue, buildConfig: build, cdnConfig: cdn,
                              buildID: Int(row["BuildId"] ?? "") ?? 0, name: name,
                              productConfig: row["ProductConfig"].flatMap { $0.isEmpty ? nil : $0 },
                              keyRing: row["KeyRing"].flatMap { $0.isEmpty ? nil : $0 })
    }

    public func cdn(product: String, region: Region) async throws -> CDNClient {
        let table = try await table(product: product, file: "cdns", region: region)
        guard let row = table.rows.first(where: { $0["Name"] == region.rawValue }) ?? table.rows.first(where: { $0["Name"] == "us" }),
              let path = row["Path"]
        else { throw TACTError.notFound("\(product) CDN for \(region.rawValue)") }

        // Only HTTPS mirrors: plain HTTP would need App Transport Security exceptions.
        var servers = (row["Servers"] ?? "").split(separator: " ").compactMap { entry -> URL? in
            guard var components = URLComponents(string: String(entry)), components.scheme == "https" else { return nil }
            components.path = ""
            components.query = nil
            return components.url
        }
        if servers.isEmpty {
            servers = (row["Hosts"] ?? "").split(separator: " ").compactMap { URL(string: "https://\($0)") }
        }
        guard !servers.isEmpty else { throw TACTError.notFound("HTTPS CDN for \(product)") }
        var client = CDNClient(product: product, path: path, servers: servers, session: session)
        client.configPath = row["ConfigPath"].flatMap { $0.isEmpty ? nil : $0 }
        client.hosts = (row["Hosts"] ?? "").split(separator: " ").map(String.init)
        client.serversField = row["Servers"] ?? ""
        return client
    }

    private func table(product: String, file: String, region: Region) async throws -> BPSV {
        let host = region == .cn ? "us" : region.rawValue
        let url = URL(string: "https://\(host).version.battle.net/v2/products/\(product)/\(file)")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TACTError.network("\(url.absoluteString): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return BPSV(String(decoding: data, as: UTF8.self))
    }
}

/// Fetches content-addressed files from Blizzard's CDN mirrors, trying each
/// mirror in turn. Configs, manifests and archive indexes never change for a
/// given hash, so they're cached on disk.
public struct CDNClient: Sendable {
    public var product: String
    public var path: String
    public var servers: [URL]
    public var session: URLSession
    public var cacheDirectory: URL
    /// Where product configs live (`tpr/configs/data`), from the cdns table.
    public var configPath: String?
    /// The cdns table's Hosts and Servers columns, verbatim, for `.build.info`.
    public var hosts: [String] = []
    public var serversField = ""

    public init(product: String, path: String, servers: [URL], session: URLSession = .shared,
                cacheDirectory: URL = CDNClient.defaultCacheDirectory) {
        self.product = product
        self.path = path
        self.servers = servers
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.waypoint.launcher/tact", isDirectory: true)
    }

    public enum Kind: String, Sendable {
        case config, data, patch
        /// Directly under `path`, as product configs are.
        case raw = ""
    }

    func relativePath(_ kind: Kind, _ hash: String, suffix: String = "") -> String {
        let h = hash.lowercased()
        let folder = kind == .raw ? path : "\(path)/\(kind.rawValue)"
        return "\(folder)/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/\(h)\(suffix)"
    }

    /// A product config JSON: lives outside the product's own CDN path.
    public func cachedConfigFile(_ hash: String, path configPath: String) async throws -> Data {
        var mirror = self
        mirror.path = configPath
        return try await mirror.cached(.raw, hash)
    }

    /// Small files, kept in memory and cached on disk.
    public func cached(_ kind: Kind, _ hash: String, suffix: String = "", localCopy: URL? = nil) async throws -> Data {
        let cacheFile = cacheDirectory.appendingPathComponent(relativePath(kind, hash, suffix: suffix))
        if let data = try? Data(contentsOf: cacheFile) { return data }
        if let localCopy, let data = try? Data(contentsOf: localCopy) { return data }
        let data = try await fetch(kind, hash, suffix: suffix)
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        return data
    }

    public func fetch(_ kind: Kind, _ hash: String, suffix: String = "") async throws -> Data {
        try await withMirrors(kind, hash, suffix: suffix, range: nil) { request in
            let (data, response) = try await session.data(for: request)
            try Self.check(response, request, expectPartial: false)
            return data
        }
    }

    /// Downloads to a temporary file. `range` is an inclusive byte range
    /// inside an archive.
    public func download(_ kind: Kind, _ hash: String, range: ClosedRange<UInt64>? = nil) async throws -> URL {
        try await withMirrors(kind, hash, suffix: "", range: range) { request in
            let (file, response) = try await session.download(for: request)
            do {
                try Self.check(response, request, expectPartial: range != nil)
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            // The system deletes `file` when this call returns; keep our own copy.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: file, to: kept)
            return kept
        }
    }

    private func withMirrors<T>(_ kind: Kind, _ hash: String, suffix: String, range: ClosedRange<UInt64>?,
                                _ body: (URLRequest) async throws -> T) async throws -> T {
        var lastError: Error = TACTError.network("no CDN mirrors")
        for server in servers {
            var request = URLRequest(url: server.appendingPathComponent(relativePath(kind, hash, suffix: suffix)))
            request.timeoutInterval = 60
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
            for attempt in 0..<2 {
                do {
                    return try await body(request)
                } catch let error as TACTError {
                    Log.warning(.cdn, "request_failed", nil, ["url": request.url?.absoluteString ?? "?", "attempt": attempt + 1,
                                                              "range": range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "", "error": error])
                    if case .notFound = error { lastError = error; break } // try the next mirror
                    lastError = error
                } catch {
                    Log.warning(.cdn, "request_failed", nil, ["url": request.url?.absoluteString ?? "?", "attempt": attempt + 1, "error": error])
                    lastError = error
                }
                if attempt == 0 { try await Task.sleep(for: .seconds(1)) }
            }
        }
        Log.error(.cdn, "all_mirrors_failed", nil, ["path": relativePath(kind, hash, suffix: suffix), "error": lastError])
        throw lastError
    }

    private static func check(_ response: URLResponse, _ request: URLRequest, expectPartial: Bool) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let url = request.url?.absoluteString ?? "?"
        if status == 404 { throw TACTError.notFound(url) }
        guard status == (expectPartial ? 206 : 200) else { throw TACTError.network("\(url): HTTP \(status)") }
    }
}
