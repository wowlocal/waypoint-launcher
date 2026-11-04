import Foundation

/// A game's text and spoken language, as Blizzard locale codes (`enUS`, `deDE`).
public struct GameLanguages: Sendable, Equatable, Hashable, Codable {
    public var text: String
    public var speech: String

    public init(text: String, speech: String? = nil) {
        self.text = text
        self.speech = speech ?? text
    }
}

/// The languages in a Battle.net tag string. In `… enUS speech?:… deDE text?`
/// the set that names `speech` picks the spoken-language files and the one
/// that names `text` the text-language files (see
/// `InstallManifest.Tag.selectedIndices`).
public enum TagLanguages {
    public static func speech(in tags: String) -> String? { locale(in: tags, set: "speech") }
    public static func text(in tags: String) -> String? { locale(in: tags, set: "text") }

    /// `tags` installing `languages`: each set's locale swapped in place, so
    /// everything else Battle.net put there (`acct-CZE?`, content tags) stays.
    /// A string without one speech set and one text set becomes both, from
    /// its first set.
    public static func replacing(in tags: String, with languages: GameLanguages) -> String {
        var sets = tags.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func only(_ marker: Substring, _ other: Substring) -> Int? {
            sets.firstIndex { names(in: $0).contains(marker) && !names(in: $0).contains(other) }
        }
        guard let speechSet = only("speech", "text"), let textSet = only("text", "speech") else {
            let base = (sets.first ?? "").split(whereSeparator: \.isWhitespace)
                .filter { !markers.contains(String($0)) }.joined(separator: " ")
            return "\(swap(base, to: languages.speech)) speech?:\(swap(base, to: languages.text)) text?"
        }
        sets[speechSet] = swap(sets[speechSet], to: languages.speech)
        sets[textSet] = swap(sets[textSet], to: languages.text)
        return sets.joined(separator: ":")
    }

    private static let markers: Set = ["speech", "speech?", "text", "text?"]

    /// `enUS`, `zhTW`: two lowercase letters, then two uppercase.
    static func isLocale<S: StringProtocol>(_ word: S) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count == 4 else { return false }
        return scalars[..<2].allSatisfy { ("a"..."z").contains($0) } && scalars[2...].allSatisfy { ("A"..."Z").contains($0) }
    }

    private static func names(in set: String) -> [Substring] {
        set.split(whereSeparator: \.isWhitespace).map { $0.hasSuffix("?") ? $0.dropLast() : $0 }
    }

    private static func locale(in tags: String, set name: String) -> String? {
        for set in tags.split(separator: ":").map(String.init) {
            let words = names(in: set)
            if words.contains(Substring(name)) { return words.first(where: isLocale).map(String.init) }
        }
        return nil
    }

    /// One set with its locale replaced (any others dropped), or added before
    /// the speech/text marker (or at the end) when it names none.
    private static func swap(_ set: String, to locale: String) -> String {
        var words = set.split(whereSeparator: \.isWhitespace).map(String.init)
        let isLocaleWord = { (word: String) in isLocale(word.hasSuffix("?") ? word.dropLast() : Substring(word)) }
        if let i = words.firstIndex(where: isLocaleWord) {
            words[i] = words[i].hasSuffix("?") ? locale + "?" : locale
            words = words.enumerated().filter { $0.offset == i || !isLocaleWord($0.element) }.map(\.element)
        } else if let marker = words.firstIndex(where: { markers.contains($0) }) {
            words.insert(locale, at: marker)
        } else {
            words.append(locale)
        }
        return words.joined(separator: " ")
    }
}

extension ProductInstall {
    /// What the install's tags select, else what was recorded.
    public var languages: GameLanguages {
        let text = tagString.flatMap(TagLanguages.text(in:)) ?? textLanguage ?? "enUS"
        let speech = tagString.flatMap(TagLanguages.speech(in:)) ?? speechLanguage ?? text
        return GameLanguages(text: text, speech: speech)
    }

    /// The same install in other languages: `tags` (the install's own, or a
    /// default when it has none) with the locales swapped, and the records.
    public func with(_ languages: GameLanguages, tags: String) -> ProductInstall {
        var install = self
        install.tagString = TagLanguages.replacing(in: tags, with: languages)
        install.textLanguage = languages.text
        install.speechLanguage = languages.speech
        return install
    }
}

/// WoW's `WTF/Config.wtf` in a flavor folder: `SET name "value"` lines the
/// game reads at startup. Waypoint only sets the two language lines, after
/// an install or a language change, like Battle.net's language settings.
public enum WoWConfig {
    /// A missing Config.wtf is only created for a spoken language that
    /// differs from the text: the launcher's locale already gives the game
    /// its text language, and the game writes its own file (graphics
    /// settings for this Mac) on first launch. A file that can't be read
    /// throws rather than come back as just these two lines.
    public static func setLanguages(_ languages: GameLanguages, flavorFolder: URL) throws {
        let directory = flavorFolder.appendingPathComponent("WTF", isDirectory: true)
        // A symlinked file stays a symlink: its target is what changes.
        let url = directory.appendingPathComponent("Config.wtf").resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard languages.speech != languages.text || exists else { return }
        let data = exists ? try Data(contentsOf: url) : Data()
        // Latin-1 round-trips any bytes, for a file that isn't UTF-8.
        let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .isoLatin1
        let existing = String(data: data, encoding: encoding) ?? ""
        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        var lines = existing.components(separatedBy: newline)
        while lines.last?.isEmpty == true { lines.removeLast() }
        for (name, value) in [("textLocale", languages.text), ("audioLocale", languages.speech)] {
            let line = "SET \(name) \"\(value)\""
            // CVar names are case-insensitive.
            if let i = lines.firstIndex(where: { $0.lowercased().hasPrefix("set \(name.lowercased()) ") }) {
                lines[i] = line
            } else {
                lines.append(line)
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = (lines.joined(separator: newline) + newline).data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        try out.write(to: url, options: .atomic)
    }
}
