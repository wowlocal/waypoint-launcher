import Foundation

/// WoW's full-quality install includes HighRes even though the client can
/// start without it. Keep other optional packages governed by Blizzard's
/// product config and the installation's existing selection.
enum InstallContent {
    static func tags(for install: ProductInstall, from tags: String) -> String {
        guard GameCatalog.family(for: install.productCode) == .worldOfWarcraft else { return tags }
        return tags.split(separator: ":", omittingEmptySubsequences: false).map { set in
            let selected = set.split(whereSeparator: \.isWhitespace)
                .contains { $0 == "HighRes" || $0 == "HighRes?" }
            return selected ? String(set) : String(set) + (set.isEmpty ? "" : " ") + "HighRes"
        }.joined(separator: ":")
    }

    static func needsUpdate(_ install: ProductInstall) -> Bool {
        // A missing tag record is also incomplete: planning will start from
        // the live product config and commit the resulting content selection.
        guard GameCatalog.family(for: install.productCode) == .worldOfWarcraft else { return false }
        guard let current = install.tagString, !current.isEmpty else { return true }
        return tags(for: install, from: current) != current
    }
}
