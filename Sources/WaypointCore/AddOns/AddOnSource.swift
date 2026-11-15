import Foundation

/// Where Waypoint gets add-ons. Only sources any app may download from:
/// CurseForge's API needs a private key its terms don't let an open-source
/// app ship, and Wago's needs a paid one.
public enum AddOnSourceID: String, Codable, Sendable, CaseIterable {
    case github, tukui, wowInterface

    public var displayName: String {
        switch self {
        case .github: "GitHub"
        case .tukui: "Tukui"
        case .wowInterface: "WoWInterface"
        }
    }
}

/// An add-on at a source: `BigWigsMods/BigWigs`, `elvui`, `5086`.
public struct AddOnRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var source: AddOnSourceID
    public var id: String

    public init(_ source: AddOnSourceID, _ id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source.rawValue):\(id)" }

    /// The add-on's page, for "Open Web Page".
    public var webPage: URL? {
        switch source {
        case .github: URL(string: "https://github.com/\(id)")
        case .tukui: URL(string: "https://tukui.org/\(id)")
        case .wowInterface: URL(string: "https://www.wowinterface.com/downloads/info\(id)")
        }
    }
}

/// A release of an add-on, for one flavor.
public struct AddOnRelease: Equatable, Codable, Sendable {
    public var ref: AddOnRef
    /// What changes with each release: a tag, a version, WoWInterface's
    /// version and upload time.
    public var id: String
    /// What people see.
    public var version: String
    public var date: Date?
    public var download: URL
    /// WoWInterface's checksum of the zip.
    public var md5: String?

    public init(ref: AddOnRef, id: String, version: String, date: Date?, download: URL, md5: String? = nil) {
        self.ref = ref
        self.id = id
        self.version = version
        self.date = date
        self.download = download
        self.md5 = md5
    }
}

public enum AddOnSourceError: Error, Equatable, Sendable, LocalizedError {
    /// The add-on has no release (any more).
    case noRelease
    /// It has releases, none for this game.
    case notForThisVersion
    /// The source couldn't be reached or answered nonsense; try later.
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .noRelease: "This add-on has no download any more."
        case .notForThisVersion: "This add-on has no version for this game."
        case .unavailable: "Couldn’t check for updates. Try again later."
        }
    }
}

public protocol AddOnSource: Sendable {
    var id: AddOnSourceID { get }
    /// The latest stable release of each add-on for `flavor`. `interface`
    /// is the game's own number, preferred when a release lists several.
    func latest(_ refs: [AddOnRef], flavor: WoWFlavor, interface: Int?) async -> [AddOnRef: Result<AddOnRelease, AddOnSourceError>]
}

/// The network, as closures so tests need none.
public struct AddOnHTTP: Sendable {
    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        /// The first redirect's target: GitHub's own URL for an asset,
        /// which names the release's tag. Later ones are signed CDN links.
        public var firstRedirect: URL?
        public var lastModified: Date?

        public init(data: Data, status: Int, firstRedirect: URL? = nil, lastModified: Date? = nil) {
            self.data = data
            self.status = status
            self.firstRedirect = firstRedirect
            self.lastModified = lastModified
        }
    }

    public var get: @Sendable (URL) async throws -> Response
    /// Into a temporary file, which the caller removes; fails past
    /// `maximumBytes`. Progress is 0…1.
    public var download: @Sendable (URL, _ maximumBytes: Int64, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    public init(get: @escaping @Sendable (URL) async throws -> Response,
                download: @escaping @Sendable (URL, Int64, @escaping @Sendable (Double) -> Void) async throws -> URL) {
        self.get = get
        self.download = download
    }

    /// HTTPS only, nothing stored, an honest User-Agent; downloads share
    /// the games' bandwidth limit.
    public static let live: AddOnHTTP = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: configuration)
        let retry = NetworkRetry(delays: [.seconds(1), .seconds(3)])
        return AddOnHTTP(
            get: { url in
                guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
                return try await retry.run { _ in
                    let redirects = RedirectRecorder()
                    let (data, response) = try await session.data(from: url, delegate: redirects)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    if [429, 500, 502, 503, 504].contains(http.statusCode) { throw HTTPFailure(status: http.statusCode, url: url) }
                    let modified = (http.value(forHTTPHeaderField: "Last-Modified")).flatMap(Self.httpDate)
                    return Response(data: data, status: http.statusCode, firstRedirect: redirects.first, lastModified: modified)
                }
            },
            download: { url, maximum, progress in
                guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
                let (file, response) = try await retry.run { _ in
                    let transfer = DownloadTransfer(limiter: .shared, maximumBytes: maximum) { written, expected in
                        if expected > 0 { progress(Double(written) / Double(expected)) }
                    }
                    return try await transfer.download(session: session, request: URLRequest(url: url))
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: file)
                    throw HTTPFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, url: url)
                }
                return file
            })
    }()

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Waypoint/\(version) (+https://github.com/wowlocal/waypoint-launcher)"
    }()

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// Remembers where the first redirect pointed; follows every redirect.
private final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var firstURL: URL?
    var first: URL? { lock.withLock { firstURL } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // Only HTTPS, to any host: GitHub hands assets to its CDN.
        guard request.url?.scheme == "https" else { return nil }
        lock.withLock { if firstURL == nil { firstURL = request.url } }
        return request
    }
}

/// Every source Waypoint uses, in the order it prefers them when an add-on
/// is at more than one.
public enum AddOnSources {
    public static func live(http: AddOnHTTP = .live) -> [any AddOnSource] {
        [TukUIAddOnSource(http: http), GitHubAddOnSource(http: http), WoWInterfaceAddOnSource(http: http)]
    }
}

/// Runs `body` for each element, at most `width` at a time.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        while next < min(width, items.count) {
            let i = next, item = items[i]
            group.addTask { (i, await body(item)) }
            next += 1
        }
        while let (i, result) = await group.next() {
            results[i] = result
            if next < items.count {
                let j = next, item = items[j]
                group.addTask { (j, await body(item)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
