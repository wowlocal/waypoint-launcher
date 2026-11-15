import Foundation

/// WoWInterface's public API (the one its Minion app uses). One file per
/// add-on, usually the retail one; the zip's own TOCs decide whether it
/// installs for another game. Only an add-on's author can upload to its ID,
/// so a TOC's `X-WoWI-ID` is trusted without an index.
public struct WoWInterfaceAddOnSource: AddOnSource {
    public let id = AddOnSourceID.wowInterface
    let http: AddOnHTTP

    public init(http: AddOnHTTP) { self.http = http }

    /// Fields come as strings in a batch and as numbers for a single ID.
    struct Details: Decodable {
        var id: String
        var version: String
        var lastUpdate: String?
        var checksum: String?
        var downloadUri: String

        enum CodingKeys: String, CodingKey { case id, version, lastUpdate, checksum, downloadUri }

        init(id: String, version: String, lastUpdate: String?, checksum: String?, downloadUri: String) {
            (self.id, self.version, self.lastUpdate, self.checksum, self.downloadUri) = (id, version, lastUpdate, checksum, downloadUri)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                if let string = try? c.decode(String.self, forKey: key) { return string }
                if let number = try? c.decode(Int64.self, forKey: key) { return String(number) }
                if let number = try? c.decode(Double.self, forKey: key) { return String(format: "%.0f", number) }
                return nil
            }
            guard let id = text(.id), let version = text(.version), let download = text(.downloadUri) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WoWInterface file details"))
            }
            self.init(id: id, version: version, lastUpdate: text(.lastUpdate), checksum: text(.checksum), downloadUri: download)
        }
    }

    /// Every ref in one request (`filedetails/1,2,3.json`), up to 50 at a time.
    public func latest(_ refs: [AddOnRef], flavor: WoWFlavor, interface: Int?) async -> [AddOnRef: Result<AddOnRelease, AddOnSourceError>] {
        let valid = refs.filter { !$0.id.isEmpty && $0.id.allSatisfy(\.isASCIIDigit) }
        var results: [AddOnRef: Result<AddOnRelease, AddOnSourceError>] = [:]
        for ref in refs where !valid.contains(ref) { results[ref] = .failure(.noRelease) }
        for start in stride(from: 0, to: valid.count, by: 50) {
            let batch = Array(valid[start..<min(start + 50, valid.count)])
            let url = URL(string: "https://api.mmoui.com/v4/game/WOW/filedetails/\(batch.map(\.id).joined(separator: ",")).json")!
            let details: [Details]
            do {
                let response = try await http.get(url)
                if response.status == 404 {
                    for ref in batch { results[ref] = .failure(.noRelease) }
                    continue
                }
                guard response.status == 200 else { throw HTTPFailure(status: response.status, url: url) }
                details = try JSONDecoder().decode([Details].self, from: response.data)
            } catch {
                Log.info(.addOns, "source_failed", nil, ["source": "wowinterface", "error": error])
                for ref in batch { results[ref] = .failure(.unavailable) }
                continue
            }
            for ref in batch {
                guard let entry = details.first(where: { $0.id == ref.id }) else { results[ref] = .failure(.noRelease); continue }
                results[ref] = Self.release(entry, ref: ref)
            }
        }
        return results
    }

    static func release(_ entry: Details, ref: AddOnRef) -> Result<AddOnRelease, AddOnSourceError> {
        guard let download = URL(string: entry.downloadUri), download.scheme == "https",
              let host = download.host?.lowercased(), host == "wowinterface.com" || host.hasSuffix(".wowinterface.com") else {
            return .failure(.unavailable)
        }
        let milliseconds = entry.lastUpdate.flatMap(Double.init)
        return .success(AddOnRelease(ref: ref, id: "\(entry.version)|\(entry.lastUpdate ?? "")", version: entry.version,
                                     date: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) },
                                     download: download, md5: entry.checksum?.lowercased()))
    }

    // MARK: Search

    /// An entry in WoWInterface's full list (`filelist.json`, ~6 MB).
    public struct ListEntry: Decodable, Sendable {
        public var UID: String
        public var UIName: String
        public var UIAuthorName: String?
        public var UIVersion: String?
        public var UIDate: Double?
        public var UIDir: [String]?
        public var UICompatibility: [Compatibility]?
        public var UIDownloadTotal: String?

        public struct Compatibility: Decodable, Sendable { public var version: String }

        public var date: Date? { UIDate.map { Date(timeIntervalSince1970: $0 / 1000) } }
        public var downloads: Int { UIDownloadTotal.flatMap { Int($0) } ?? 0 }

        /// Whether it's worth showing for `flavor`: it lists a version of
        /// that game, or was updated in the last year (the list is often
        /// behind). Its zip's TOCs decide in the end.
        func suits(_ flavor: WoWFlavor, now: Date) -> Bool {
            if let date, now.timeIntervalSince(date) < 365 * 86400 { return true }
            return (UICompatibility ?? []).contains {
                WoWFlavor.interface(version: $0.version).flatMap(WoWFlavor.init(interface:)) == flavor
            }
        }
    }

    public static let listURL = URL(string: "https://api.mmoui.com/v3/game/WOW/filelist.json")!
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
