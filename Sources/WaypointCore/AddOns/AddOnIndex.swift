import Foundation

/// Add-ons Waypoint knows where to update, checked by hand: each entry is
/// the author's own repository, with the folders and IDs its own release
/// ships (`tools/addon-index/check.py` reads them). Only the author's own
/// repository goes in, so a fork can't take over an add-on's updates.
/// Compiled in: no file to read, no request to make.
public struct AddOnIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var author: String
        /// Main folders, the first the one that names the add-on.
        public var folders: [String]
        public var curse: String?
        public var wago: String?
        public var wowi: String?
        public var source: AddOnRef
        /// The games its release is for; nil when not recorded (offered for all).
        public var flavors: Set<WoWFlavor>? = nil
        /// Add-ons it needs to run, installed with it when missing.
        public var requires: [AddOnRef] = []

        public func isFor(_ flavor: WoWFlavor) -> Bool { flavors?.contains(flavor) ?? true }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// By an ID the folder's TOC carries.
    func entry(curse: String?, wago: String?, wowi: String?) -> Entry? {
        entries.first { entry in
            (curse != nil && entry.curse == curse) || (wago != nil && entry.wago == wago) || (wowi != nil && entry.wowi == wowi)
        }
    }

    /// By folder name, unless the folder's own IDs say it's another add-on
    /// that happens to use the name.
    func entry(folder: String, toc: AddOnTOC?) -> Entry? {
        let name = folder.lowercased()
        return entries.first { entry in
            guard entry.folders.contains(where: { $0.lowercased() == name }) else { return false }
            guard let toc else { return true }
            func contradicts(_ mine: String?, _ theirs: String?) -> Bool { mine != nil && theirs != nil && mine != theirs }
            return !contradicts(toc.curseID, entry.curse) && !contradicts(toc.wagoID, entry.wago) && !contradicts(toc.wowiID, entry.wowi)
        }
    }

    func entry(for ref: AddOnRef) -> Entry? { entries.first { $0.source == ref } }

    /// Names and authors containing every word, best match first; only
    /// add-ons with a release for `flavor` when that's given.
    public func search(_ text: String, flavor: WoWFlavor? = nil) -> [Entry] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries
            .filter { entry in flavor.map(entry.isFor) ?? true }
            .filter { entry in words.allSatisfy { "\(entry.name) \(entry.author) \(entry.folders.joined(separator: " "))".lowercased().contains($0) } }
            .sorted { AddOnIndex.rank($0.name, words) < AddOnIndex.rank($1.name, words) }
    }

    /// 0: the name starts with the text, 1: a word starts with it, 2: anywhere.
    static func rank(_ name: String, _ words: [String]) -> Int {
        let lower = name.lowercased()
        if lower.hasPrefix(words.joined(separator: " ")) { return 0 }
        if lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(words[0]) }) { return 1 }
        return 2
    }

    private static func github(_ name: String, _ author: String, _ repo: String, _ folders: [String],
                               curse: String? = nil, wago: String? = nil, wowi: String? = nil, flavors: Set<WoWFlavor>,
                               requires: [String] = []) -> Entry {
        Entry(name: name, author: author, folders: folders, curse: curse, wago: wago, wowi: wowi, source: AddOnRef(.github, repo),
              flavors: flavors, requires: requires.map { AddOnRef(.github, $0) })
    }

    /// Checked 2026-11-15 with tools/addon-index/check.py: each GitHub entry
    /// publishes `release.json`, isn't a fork, and is the author's own
    /// (tools/addon-index/EVIDENCE.md says how we know). Folders and IDs are
    /// read from its latest release; its games are those it has a release
    /// for at their current patch line.
    public static let bundled = AddOnIndex(entries: [
        Entry(name: "ElvUI", author: "Elv", folders: ["ElvUI", "ElvUI_Options", "ElvUI_Libraries"], source: AddOnRef(.tukui, "elvui"),
              flavors: [.mainline, .forever, .mists, .vanilla, .tbc]),
        Entry(name: "Tukui", author: "Tukz", folders: ["Tukui"], source: AddOnRef(.tukui, "tukui"), flavors: [.mainline, .mists, .vanilla]),
        github("BigWigs", "Funkeh", "BigWigsMods/BigWigs", ["BigWigs", "BigWigs_Core", "BigWigs_Options", "BigWigs_Plugins"], curse: "2382", wago: "5NRegwG3", wowi: "5086", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("LittleWigs", "Funkeh", "BigWigsMods/LittleWigs", ["LittleWigs"], curse: "4383", wago: "5bGolnN0", wowi: "9577", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath], requires: ["BigWigsMods/BigWigs"]),
        github("Deadly Boss Mods", "MysticalOS", "DeadlyBossMods/DeadlyBossMods", ["DBM-Core", "DBM-GUI", "DBM-StatusBarTimers"], curse: "3358", wago: "qv633o6b", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("WeakAuras", "The WeakAuras Team", "WeakAuras/WeakAuras2", ["WeakAuras", "WeakAurasArchive", "WeakAurasModelPaths", "WeakAurasOptions", "WeakAurasTemplates"], curse: "65387", wago: "VBNBxKx5", wowi: "24910", flavors: [.cata, .mists, .tbc, .titan, .vanilla]),
        github("Plater Nameplates", "Tercioo", "Tercioo/Plater-Nameplates", ["Plater"], curse: "100547", wago: "kRNLep6o", flavors: [.forever, .mainline, .mists, .tbc, .titan, .vanilla]),
        github("Mythic Dungeon Tools", "Nnoggie", "Nnoggie/MythicDungeonTools", ["MythicDungeonTools", "MythicDungeonTools_UI"], curse: "288981", wago: "rN4VrAKD", flavors: [.mainline]),
        github("Masque", "StormFX", "SFX-WoW/Masque", ["Masque"], curse: "13592", wago: "kRNLgpGo", wowi: "12097", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("All The Things", "Crieve", "ATTWoWAddon/AllTheThings", ["AllTheThings"], curse: "267285", wago: "yQKyY5K7", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("Bartender4", "Nevcairiel", "Nevcairiel/Bartender4", ["Bartender4"], curse: "13501", wago: "v63oVn6b", wowi: "11190", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("OmniCC", "Tuller", "tullamods/OmniCC", ["OmniCC", "OmniCC_Config"], flavors: [.mists, .tbc, .titan, .vanilla]),
        github("Cell", "enderneko", "enderneko/Cell", ["Cell"], curse: "409666", wago: "qv63LLKb", wowi: "26244", flavors: [.cata, .mists, .tbc, .titan, .vanilla]),
        github("Questie", "Aero", "Questie/Questie", ["Questie", "QuestieDB", "QuestieTrace"], curse: "334372", wago: "qv634BKb", flavors: [.forever, .mists, .tbc, .titan, .vanilla]),
        github("Raider.IO", "Vladinator", "RaiderIO/raiderio-addon", ["RaiderIO"], curse: "279257", wago: "b6mb0XKP", flavors: [.mainline]),
        github("Dominos", "Tuller", "tullamods/Dominos", ["Dominos", "Dominos_Cast", "Dominos_Config", "Dominos_Progress", "Dominos_Roll"], flavors: [.forever, .mainline, .mists, .tbc, .titan, .vanilla]),
        github("Decursive", "John Wellesz", "2072/Decursive", ["Decursive"], curse: "2154", flavors: [.mainline, .titan]),
        github("TellMeWhen", "Cybeloras of Aerie Peak", "ascott18/TellMeWhen", ["TellMeWhen", "TellMeWhen_Options"], curse: "8025", wago: "ZQ6aZqKW", wowi: "10855", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("BigWigs Voice", "Funkeh", "BigWigsMods/BigWigs_Voice", ["BigWigs_Voice"], curse: "87513", wowi: "24218", flavors: [.mainline], requires: ["BigWigsMods/BigWigs"]),
        github("Capping", "Funkeh", "BigWigsMods/Capping", ["Capping", "Capping_Options"], curse: "20143", wago: "Rn6VXOGd", wowi: "11177", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("BetterBags", "Cidan", "Cidan/BetterBags", ["BetterBags"], curse: "942432", wago: "aNDmy96o", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("SexyMap", "Funkeh", "funkydude/SexyMap", ["SexyMap"], curse: "15936", wago: "e56no0K9", wowi: "21538", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("BigDebuffs", "Jordon", "jordonwow/bigdebuffs", ["BigDebuffs"], curse: "82697", wago: "WYK98e6L", wowi: "26006", flavors: [.mainline, .mists, .tbc, .titan, .vanilla]),
        github("BlizzMove", "Kiatra", "Kiatra/BlizzMove", ["BlizzMove", "BlizzMove_Debug"], curse: "17809", wowi: "23875", flavors: [.cata, .forever, .mainline, .mists, .tbc, .vanilla, .wrath]),
        github("HandyNotes", "Xinhuan", "Nevcairiel/HandyNotes", ["HandyNotes"], curse: "14154", wago: "mNwQMlKo", wowi: "15716", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Inventorian", "Nevcairiel", "Nevcairiel/Inventorian", ["Inventorian", "Inventorian_BagBrother"], curse: "85646", flavors: [.forever, .mainline]),
        github("Mapster", "Nevcairiel", "Nevcairiel/Mapster", ["Mapster"], curse: "14376", wowi: "8306", flavors: [.forever, .mainline]),
        github("Quartz", "Nevcairiel", "Nevcairiel/Quartz", ["Quartz"], curse: "4558", wowi: "7158", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("SimulationCraft", "Theck", "simulationcraft/simc-addon", ["Simulationcraft"], curse: "82745", wago: "BNBeRVGx", flavors: [.forever, .mainline]),
        github("Raid Frame Settings", "Slothpala", "Slothpala/RaidFrameSettings", ["RaidFrameSettings", "RaidFrameSettingsOptions"], curse: "688930", flavors: [.forever, .mainline]),
        github("Advanced Interface Options", "Stanzilla", "Stanzilla/AdvancedInterfaceOptions", ["AdvancedInterfaceOptions"], curse: "99982", wago: "ZQ6aPNW7", wowi: "25002", flavors: [.cata, .forever, .mainline, .mists, .tbc, .vanilla, .wrath]),
        github("Edit Mode Expanded", "Teelo", "teelolws/EditModeExpanded", ["EditModeExpanded"], curse: "695703", flavors: [.forever, .mainline, .mists, .tbc]),
        github("tullaRange", "Tuller", "tullamods/tullaRange", ["tullaRange", "tullaRange_Config"], flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Rarity", "Allara", "WowRarity/Rarity", ["Rarity", "Rarity_Options"], curse: "30801", flavors: [.mists, .vanilla]),
        github("BagSync", "Xruptor", "Xruptor/BagSync", ["BagSync"], curse: "22067", wago: "xZKxjQNk", wowi: "15351", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
    ])
}
