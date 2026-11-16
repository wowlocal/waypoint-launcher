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

    /// The add-on's description from its WoWInterface page, as plain text.
    public func details(_ ref: AddOnRef) async -> AddOnDetails? {
        guard ref.id.allSatisfy(\.isASCIIDigit),
              let url = URL(string: "https://api.mmoui.com/v4/game/WOW/filedetails/\(ref.id).json"),
              let response = try? await http.get(url), response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.data) else { return nil }
        guard let item = ((json as? [[String: Any]])?.first ?? json as? [String: Any]) else { return nil }
        func text(_ key: String) -> String? {
            guard let value = item[key], !(value is NSNull) else { return nil }
            return "\(value)"
        }
        let monthly = text("downloadsMonthly").flatMap { Int($0) }
        let updated = text("lastUpdate").flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return AddOnDetails(summary: text("description").map(Self.plain).flatMap(Self.firstParagraph), website: ref.webPage,
                            popularity: monthly.map { "\($0.formatted()) a month" }, updated: updated)
    }

    /// The first paragraph of real text: not a lone heading ("About").
    static func firstParagraph(_ text: String) -> String? {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let paragraph = paragraphs.first { $0.count > 40 } ?? paragraphs.first { !$0.isEmpty }
        guard let paragraph else { return nil }
        return paragraph.count > 400 ? String(paragraph.prefix(400)).trimmingCharacters(in: .whitespaces) + "…" : paragraph
    }

    /// BBCode as plain text: tags and images out, links' text kept, at
    /// most a few paragraphs.
    static func plain(_ bbcode: String) -> String {
        var text = ListEntry.unescaped(bbcode)
        for (pattern, replacement) in [(#"\[img\][^\[]*\[/img\]"#, ""), (#"\[url=[^\]]*\]([^\[]*)\[/url\]"#, "$1"),
                                       (#"\[\*\]"#, "• "), (#"\[/?[a-zA-Z]+(=[^\]]*)?\]"#, ""), (#"\r"#, ""),
                                       (#"[ \t]+"#, " "), (#"\n\s*\n+"#, "\n\n")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 700 ? String(text.prefix(700)).trimmingCharacters(in: .whitespaces) + "…" : text
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
        public var UIDownloadMonthly: String?

        public struct Compatibility: Decodable, Sendable { public var version: String }

        public var date: Date? { UIDate.map { Date(timeIntervalSince1970: $0 / 1000) } }
        public var downloads: Int { UIDownloadTotal.flatMap { Int($0) } ?? 0 }
        /// What people download now: the ranking for search.
        public var monthlyDownloads: Int { UIDownloadMonthly.flatMap { Int($0) } ?? 0 }
        /// Names come HTML-escaped, sometimes twice (`&amp;#54392;`).
        public var name: String { Self.unescaped(UIName) }
        public var author: String? { UIAuthorName.map(Self.unescaped) }

        /// Updated in the last year: older entries are mostly abandoned
        /// copies, and their zips' TOCs decide the game anyway.
        func isRecent(now: Date) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) < 365 * 86400
        }

        /// Whether it's for this kind of game: an entry that lists versions
        /// only of the other kind (retail 6 and up, the classic games 1 to 5)
        /// would download and then fail. Forever isn't listed there at all.
        func fits(_ flavor: WoWFlavor) -> Bool {
            let majors = (UICompatibility ?? []).compactMap { Int($0.version.split(separator: ".").first ?? "") }
            guard !majors.isEmpty, flavor != .forever else { return true }
            return flavor == .mainline ? majors.contains { $0 >= 6 } : majors.contains { $0 <= 5 }
        }

        static func unescaped(_ text: String) -> String {
            var result = text
            for _ in 0..<2 where result.contains("&") {
                var out = ""
                var rest = Substring(result)
                while let amp = rest.firstIndex(of: "&") {
                    out += rest[..<amp]
                    let tail = rest[amp...]
                    guard let semi = tail.firstIndex(of: ";"), tail.distance(from: amp, to: semi) <= 10 else {
                        out += "&"; rest = rest[rest.index(after: amp)...]; continue
                    }
                    let entity = String(tail[tail.index(after: amp)..<semi])
                    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'"]
                    if let value = named[entity] {
                        out += value
                    } else if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                    } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                        out.unicodeScalars.append(scalar)
                    } else {
                        out += "&\(entity);"
                    }
                    rest = rest[rest.index(after: semi)...]
                }
                result = out + rest
            }
            return result
        }
    }

    public static let listURL = URL(string: "https://api.mmoui.com/v3/game/WOW/filelist.json")!
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
