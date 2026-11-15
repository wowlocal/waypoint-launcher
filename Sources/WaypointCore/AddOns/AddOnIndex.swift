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

    /// Names and authors containing every word, best match first.
    public func search(_ text: String) -> [Entry] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries
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
                               curse: String? = nil, wago: String? = nil, wowi: String? = nil) -> Entry {
        Entry(name: name, author: author, folders: folders, curse: curse, wago: wago, wowi: wowi, source: AddOnRef(.github, repo))
    }

    /// Checked 2026-11-15: every GitHub entry publishes `release.json`.
    public static let bundled = AddOnIndex(entries: [
        Entry(name: "ElvUI", author: "Elv", folders: ["ElvUI", "ElvUI_Options", "ElvUI_Libraries"], source: AddOnRef(.tukui, "elvui")),
        Entry(name: "Tukui", author: "Tukz", folders: ["Tukui"], source: AddOnRef(.tukui, "tukui")),
        github("BigWigs", "Funkeh", "BigWigsMods/BigWigs", ["BigWigs", "BigWigs_Core", "BigWigs_Options", "BigWigs_Plugins"],
               curse: "2382", wago: "5NRegwG3", wowi: "5086"),
        github("LittleWigs", "Funkeh", "BigWigsMods/LittleWigs", ["LittleWigs"], curse: "4383", wago: "5bGolnN0", wowi: "9577"),
        github("Deadly Boss Mods", "MysticalOS", "DeadlyBossMods/DeadlyBossMods", ["DBM-Core", "DBM-GUI", "DBM-StatusBarTimers"],
               curse: "3358", wago: "qv633o6b"),
        github("WeakAuras", "The WeakAuras Team", "WeakAuras/WeakAuras2", ["WeakAuras", "WeakAurasOptions"],
               curse: "65387", wago: "VBNBxKx5", wowi: "24910"),
        github("Plater Nameplates", "Tercioo", "Tercioo/Plater-Nameplates", ["Plater"], curse: "100547", wago: "kRNLep6o"),
        github("Mythic Dungeon Tools", "Nnoggie", "Nnoggie/MythicDungeonTools", ["MythicDungeonTools"], curse: "288981", wago: "rN4VrAKD"),
        github("Masque", "StormFX", "SFX-WoW/Masque", ["Masque"], curse: "13592", wago: "kRNLgpGo", wowi: "12097"),
        github("Hekili", "Hekili", "Hekili/hekili", ["Hekili"], curse: "69254", wago: "WYK9WXNL", wowi: "24608"),
        github("All The Things", "Crieve", "ATTWoWAddon/AllTheThings", ["AllTheThings"], curse: "267285", wago: "yQKyY5K7"),
        github("Bartender4", "Nevcairiel", "Nevcairiel/Bartender4", ["Bartender4"], curse: "13501", wago: "v63oVn6b", wowi: "11190"),
        github("OmniCC", "Tuller", "tullamods/OmniCC", ["OmniCC", "OmniCC_Config"]),
        github("Dominos", "Tuller", "tullamods/Dominos", ["Dominos", "Dominos_Config"]),
        github("BugSack", "Funkeh", "funkydude/BugSack", ["BugSack"], curse: "6273", wago: "rkGrrgGy", wowi: "5995"),
        github("Cell", "enderneko", "enderneko/Cell", ["Cell"], curse: "409666", wago: "qv63LLKb", wowi: "26244"),
        github("Grid2", "Michael", "michaelnpsp/Grid2", ["Grid2", "Grid2Options"], curse: "15226", wago: "vEGPyeN1"),
        github("Questie", "Aero", "Questie/Questie", ["Questie"], curse: "334372", wago: "qv634BKb"),
        github("Raider.IO", "Vladinator", "RaiderIO/raiderio-addon", ["RaiderIO"], curse: "279257", wago: "b6mb0XKP"),
    ])
}
