import Foundation

/// WoW's optional packages, `HighRes` above all: 39.7 GB the client starts
/// without. A fresh install Waypoint makes takes it, for the full-quality
/// install. An installation that already exists keeps the content it was
/// installed with, whoever installed it: Battle.net deliberately leaves
/// HighRes out of some installs and its cleanup would discard it again, so
/// an update downloads what Battle.net would and nothing else.
enum InstallContent {
    /// `tags` with HighRes selected in every set: a full-quality install.
    static func tags(for install: ProductInstall, from tags: String) -> String {
        guard GameCatalog.family(for: install.productCode) == .worldOfWarcraft else { return tags }
        return tags.split(separator: ":", omittingEmptySubsequences: false).map { set in
            selectsHighRes(in: set) ? String(set) : String(set) + (set.isEmpty ? "" : " ") + "HighRes"
        }.joined(separator: ":")
    }

    /// The tags a download plans with. Only an install being made from
    /// scratch opts into optional content; an update or a language change
    /// keeps the installation's own selection, even when no tags are
    /// recorded for it (then the product config's own selection stands in).
    static func plannedTags(for install: ProductInstall, from tags: String) -> String {
        isFresh(install) ? self.tags(for: install, from: tags) : tags
    }

    /// Nothing is installed yet: neither a build nor a version is recorded,
    /// as for the install record a fresh download starts from.
    static func isFresh(_ install: ProductInstall) -> Bool {
        install.buildConfig == nil && install.version == nil
    }

    /// Whether an installation's own tags select HighRes throughout, which is
    /// what the Agent's `UserSettings.additional_tags` would claim of it. A
    /// missing tag record, or a selection in only some sets, is not that.
    static func selectsHighRes(_ install: ProductInstall) -> Bool {
        guard GameCatalog.family(for: install.productCode) == .worldOfWarcraft,
              let tags = install.tagString, !tags.isEmpty else { return false }
        return tags.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { selectsHighRes(in: $0) }
    }

    private static func selectsHighRes(in set: Substring) -> Bool {
        set.split(whereSeparator: \.isWhitespace).contains { $0 == "HighRes" || $0 == "HighRes?" }
    }
}
