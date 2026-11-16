import Foundation

/// Add-ons released on GitHub with the BigWigs packager's `release.json`,
/// which lists each zip's games. Read through GitHub's web download links,
/// not its API: no token, and not the API's 60 requests an hour.
/// `releases/latest` never names a pre-release, so this is stable only.
public struct GitHubAddOnSource: AddOnSource {
    public let id = AddOnSourceID.github
    let http: AddOnHTTP

    public init(http: AddOnHTTP) { self.http = http }

    public func latest(_ refs: [AddOnRef], flavor: WoWFlavor, interface: Int?) async -> [AddOnRef: Result<AddOnRelease, AddOnSourceError>] {
        let http = http
        let results = await concurrentMap(refs, width: 4) { ref in
            await Self.latest(ref, flavor: flavor, interface: interface, http: http)
        }
        return Dictionary(zip(refs, results), uniquingKeysWith: { first, _ in first })
    }

    static func latest(_ ref: AddOnRef, flavor: WoWFlavor, interface: Int?, http: AddOnHTTP) async -> Result<AddOnRelease, AddOnSourceError> {
        guard isRepository(ref.id), let url = URL(string: "https://github.com/\(ref.id)/releases/latest/download/release.json") else {
            return .failure(.noRelease)
        }
        let response: AddOnHTTP.Response
        do {
            response = try await http.get(url)
        } catch {
            Log.info(.addOns, "source_failed", nil, ["ref": ref.description, "error": error])
            return .failure(.unavailable)
        }
        guard response.status != 404 else { return .failure(.noRelease) }
        guard response.status == 200 else { return .failure(.unavailable) }
        guard let redirect = response.firstRedirect, let (base, tag) = tagged(redirect, repository: ref.id) else {
            return .failure(.unavailable)
        }
        guard let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: response.data) else {
            return .failure(.unavailable)
        }
        guard let release = manifest.choose(flavor: flavor, interface: interface) else { return .failure(.notForThisVersion) }
        guard let name = release.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])),
              let download = URL(string: "\(base)/\(name)") else { return .failure(.unavailable) }
        return .success(AddOnRelease(ref: ref, id: tag, version: release.version ?? tag, date: response.lastModified, download: download))
    }

    /// Nothing beyond the index's own line: GitHub's API is rate-limited
    /// and Waypoint doesn't use it (only its web links).
    public func details(_ ref: AddOnRef) async -> AddOnDetails? { nil }

    /// The release's page on GitHub, for "What's New".
    static func releasePage(_ release: AddOnRelease) -> URL? {
        guard release.ref.source == .github,
              let tag = release.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else { return nil }
        return URL(string: "https://github.com/\(release.ref.id)/releases/tag/\(tag)")
    }

    /// "owner/repo", the only form an index entry may use.
    static func isRepository(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    /// `https://github.com/o/r/releases/download/<tag>/release.json` → its
    /// folder (where the zips are) and the tag. Tags may contain `/`.
    static func tagged(_ redirect: URL, repository: String) -> (base: String, tag: String)? {
        let prefix = "https://github.com/\(repository)/releases/download/"
        let text = redirect.absoluteString
        guard text.lowercased().hasPrefix(prefix.lowercased()), text.hasSuffix("/release.json") else { return nil }
        let encodedTag = text.dropFirst(prefix.count).dropLast("/release.json".count)
        guard !encodedTag.isEmpty, let tag = String(encodedTag).removingPercentEncoding else { return nil }
        return (String(text.dropLast("/release.json".count)), tag)
    }
}

/// The BigWigs packager's `release.json`.
struct ReleaseManifest: Decodable {
    struct Release: Decodable {
        var name: String?
        var version: String?
        var filename: String
        var nolib: Bool?
        var metadata: [Metadata]
    }

    struct Metadata: Decodable {
        var flavor: String
        var interface: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            flavor = try c.decode(String.self, forKey: .flavor)
            if let number = try? c.decodeIfPresent(Int.self, forKey: .interface) {
                interface = number
            } else {
                interface = (try? c.decodeIfPresent(String.self, forKey: .interface)).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
        }

        enum CodingKeys: String, CodingKey { case flavor, interface }

        /// The interface number decides when it disagrees with the label:
        /// Questie labels Titan Reforged's 38002 "wrath".
        var gameFlavor: WoWFlavor? { interface.flatMap(WoWFlavor.init(interface:)) ?? WoWFlavor(releaseName: flavor) }
    }

    var releases: [Release]

    /// The zip for this game: one listing its exact interface number if
    /// there is one, else the first built for the game's current patch line
    /// (a retail release still on 11.x isn't for a 12.x game). Never a
    /// `nolib` zip, which leaves out libraries the add-on needs.
    func choose(flavor: WoWFlavor, interface: Int?) -> Release? {
        let candidates = releases.filter { release in
            release.nolib != true && release.metadata.contains { meta in
                guard meta.gameFlavor == flavor else { return false }
                guard let number = meta.interface else { return true }
                return flavor.isCurrent(number, game: interface)
            }
        }
        if let interface, let exact = candidates.first(where: { $0.metadata.contains { $0.interface == interface } }) { return exact }
        return candidates.first
    }
}
