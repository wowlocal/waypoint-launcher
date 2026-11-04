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
    var retry = NetworkRetry()

    /// Offline requests use the bounded retry policy, so planning and size
    /// checks can report an error instead of waiting for the resource timeout.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // A deliberate low speed limit can make a large file take hours.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration)
    }()

    public init(session: URLSession = VersionService.defaultSession) {
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
        client.retry = retry
        client.configPath = row["ConfigPath"].flatMap { $0.isEmpty ? nil : $0 }
        client.hosts = (row["Hosts"] ?? "").split(separator: " ").map(String.init)
        client.serversField = row["Servers"] ?? ""
        return client
    }

    func table(product: String, file: String, region: Region) async throws -> BPSV {
        let host = region == .cn ? "us" : region.rawValue
        let url = URL(string: "https://\(host).version.battle.net/v2/products/\(product)/\(file)")!
        return try await retry.run { _ in
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw HTTPFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, url: url)
            }
            return BPSV(String(decoding: data, as: UTF8.self))
        }
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
    var retry = NetworkRetry()
    var bandwidthLimiter: DownloadBandwidthLimiter = .shared

    public init(product: String, path: String, servers: [URL], session: URLSession = VersionService.defaultSession,
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

    /// A file on disk, downloaded once into the cache (or the given local
    /// copy, when it exists). For files too big to hold in memory.
    public func cachedFile(_ kind: Kind, _ hash: String, suffix: String = "", localCopy: URL? = nil) async throws -> URL {
        let fm = FileManager.default
        let cacheFile = cacheDirectory.appendingPathComponent(relativePath(kind, hash, suffix: suffix))
        if fm.fileExists(atPath: cacheFile.path) { return cacheFile }
        if let localCopy, fm.fileExists(atPath: localCopy.path) { return localCopy }
        let temp = try await download(kind, hash, suffix: suffix)
        try fm.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: temp, to: cacheFile)
        } catch {
            try? fm.removeItem(at: temp)
            guard fm.fileExists(atPath: cacheFile.path) else { throw error } // else: another task got there first
        }
        return cacheFile
    }

    /// A BLTE file (manifest, encoding table), decoded once into the cache and
    /// memory-mapped. These run to tens of megabytes for WoW; mapped pages
    /// aren't part of the app's footprint, and the system drops them when
    /// it needs the memory.
    public func decoded(_ hash: String) async throws -> Data {
        let fm = FileManager.default
        let decodedFile = cacheDirectory.appendingPathComponent(relativePath(.data, hash, suffix: ".decoded"))
        if let data = try? Data(contentsOf: decodedFile, options: .alwaysMapped) { return data }
        let encoded = try await cachedFile(.data, hash)
        let partial = decodedFile.appendingPathExtension("\(UUID().uuidString).part")
        try fm.createDirectory(at: decodedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            _ = try BLTE.decode(file: encoded, to: output)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        do {
            try fm.moveItem(at: partial, to: decodedFile)
        } catch {
            try? fm.removeItem(at: partial)
            guard fm.fileExists(atPath: decodedFile.path) else { throw error }
        }
        try? fm.removeItem(at: encoded) // only the decoded form is read again
        return try Data(contentsOf: decodedFile, options: .alwaysMapped)
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
        let file = try await download(kind, hash, suffix: suffix)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    /// Downloads to a temporary file. `range` is an inclusive byte range
    /// inside an archive.
    public func download(_ kind: Kind, _ hash: String, suffix: String = "", range: ClosedRange<UInt64>? = nil) async throws -> URL {
        // Resume data belongs to one URL, never another mirror. Archive
        // slices restart their bounded batch: URLSession's resume Range may
        // otherwise extend past the requested end of the archive slice.
        var resumeData: [URL: Data] = [:]
        return try await withMirrors(kind, hash, suffix: suffix, range: range) { request in
            let url = request.url!
            let saved = resumeData.removeValue(forKey: url)
            var resumed = false
            var file: URL
            var response: URLResponse
            do {
                let result = try await Self.resumeOrRestart(saved) { data in
                    if data != nil { Log.info(.cdn, "download_resuming", nil, ["url": url.absoluteString]) }
                    return try await DownloadTransfer(limiter: bandwidthLimiter)
                        .download(session: session, request: request, resumeData: data)
                }
                (file, response, resumed) = result
            } catch {
                if range == nil, let data = (error as? URLError)?.downloadTaskResumeData { resumeData[url] = data }
                throw error
            }
            do {
                // A resumed whole file can have a 206 response, with the
                // temporary file containing both the original and new bytes.
                try Self.check(response, request, expectPartial: range != nil, resumed: resumed)
                if let range {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    let contentRange = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard size.map(UInt64.init) == range.upperBound - range.lowerBound + 1,
                          contentRange.hasPrefix("bytes \(range.lowerBound)-\(range.upperBound)/") else {
                        throw TACTError.malformed("CDN archive range response")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            // DownloadTransfer already owns this temporary file. The caller
            // moves it into the cache or removes it after decoding.
            return file
        }
    }

    /// A rejected/stale resume may need one fresh attempt. Failures from
    /// that fresh attempt belong to the outer retry policy, never this catch.
    static func resumeOrRestart(_ data: Data?,
                                perform: (Data?) async throws -> (URL, URLResponse)) async throws -> (URL, URLResponse, Bool) {
        if let data {
            var result: (URL, URLResponse)?
            do {
                result = try await perform(data)
            } catch {
                if Task.isCancelled || NetworkRetry.isCancellation(error) || NetworkRetry.isTransient(error) { throw error }
            }
            if let result {
                let status = (result.1 as? HTTPURLResponse)?.statusCode
                if status != 412 && status != 416 { return (result.0, result.1, true) }
                try? FileManager.default.removeItem(at: result.0)
            }
        }
        let result = try await perform(nil)
        return (result.0, result.1, false)
    }

    private func withMirrors<T>(_ kind: Kind, _ hash: String, suffix: String, range: ClosedRange<UInt64>?,
                                _ body: (URLRequest) async throws -> T) async throws -> T {
        var unavailable = Set<URL>()
        do {
            return try await retry.run { attempt in
                var lastError: Error = TACTError.network("no CDN mirrors")
                var transient: Error?
                for server in servers where !unavailable.contains(server) {
                    try Task.checkCancellation()
                    var request = URLRequest(url: server.appendingPathComponent(relativePath(kind, hash, suffix: suffix)))
                    request.timeoutInterval = 60
                    if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
                    do {
                        return try await body(request)
                    } catch {
                        if Task.isCancelled || NetworkRetry.isCancellation(error) { throw error }
                        let ns = error as NSError
                        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { throw error }
                        Log.warning(.cdn, "request_failed", nil, ["url": request.url?.absoluteString ?? "?", "attempt": attempt + 1,
                                                                  "range": range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "", "error": error])
                        if NetworkRetry.isTransient(error) {
                            transient = error
                        } else if error is HTTPFailure {
                            unavailable.insert(server)
                        } else if case TACTError.notFound = error {
                            unavailable.insert(server)
                        } else {
                            throw error // disk, integrity and other local failures won't improve on another mirror
                        }
                        lastError = error
                    }
                }
                throw transient ?? lastError
            }
        } catch {
            if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled {
                Log.error(.cdn, "all_mirrors_failed", nil, ["path": relativePath(kind, hash, suffix: suffix), "error": error])
            }
            throw error
        }
    }

    private static func check(_ response: URLResponse, _ request: URLRequest, expectPartial: Bool, resumed: Bool = false) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let url = request.url?.absoluteString ?? "?"
        if status == 404 { throw TACTError.notFound(url) }
        guard status == (expectPartial ? 206 : 200) || (resumed && status == 206) else {
            throw HTTPFailure(status: status, url: request.url!)
        }
    }
}
