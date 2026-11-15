import Foundation

/// Tukui's own API, which now lists ElvUI and Tukui. One zip serves every
/// game; its `patch` list says which.
public struct TukUIAddOnSource: AddOnSource {
    public let id = AddOnSourceID.tukui
    let http: AddOnHTTP

    public init(http: AddOnHTTP) { self.http = http }

    struct Entry: Decodable {
        var slug: String
        var name: String
        var author: String?
        var version: String
        var url: String
        var patch: [String]?
        var directories: [String]?
        var last_update: String?
    }

    public func latest(_ refs: [AddOnRef], flavor: WoWFlavor, interface: Int?) async -> [AddOnRef: Result<AddOnRelease, AddOnSourceError>] {
        guard !refs.isEmpty else { return [:] }
        let entries: [Entry]
        do {
            let response = try await http.get(URL(string: "https://api.tukui.org/v1/addons")!)
            guard response.status == 200 else { throw HTTPFailure(status: response.status, url: URL(string: "https://api.tukui.org/v1/addons")!) }
            entries = try JSONDecoder().decode([Entry].self, from: response.data)
        } catch {
            Log.info(.addOns, "source_failed", nil, ["source": "tukui", "error": error])
            return Dictionary(refs.map { ($0, .failure(.unavailable)) }, uniquingKeysWith: { first, _ in first })
        }
        var results: [AddOnRef: Result<AddOnRelease, AddOnSourceError>] = [:]
        for ref in refs {
            guard let entry = entries.first(where: { $0.slug == ref.id }) else { results[ref] = .failure(.noRelease); continue }
            results[ref] = Self.release(entry, ref: ref, flavor: flavor)
        }
        return results
    }

    static func release(_ entry: Entry, ref: AddOnRef, flavor: WoWFlavor) -> Result<AddOnRelease, AddOnSourceError> {
        let flavors = (entry.patch ?? []).compactMap { WoWFlavor.interface(version: $0).flatMap(WoWFlavor.init(interface:)) }
        guard flavors.contains(flavor) else { return .failure(.notForThisVersion) }
        guard let download = URL(string: entry.url), download.scheme == "https", download.host == "api.tukui.org" else {
            return .failure(.unavailable)
        }
        let date = entry.last_update.flatMap { day -> Date? in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: day)
        }
        return .success(AddOnRelease(ref: ref, id: entry.version, version: entry.version, date: date, download: download))
    }
}
