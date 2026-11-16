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
        /// What it does, in a line: shown under its name and on its page.
        public var summary: String?
        /// What kind of add-on it is; searchable, and Popular doesn't
        /// suggest a second one of an exclusive kind (two boss mods).
        public var category: Category?
        /// Other names people search for ("rio").
        public var keywords: [String] = []

        public func isFor(_ flavor: WoWFlavor) -> Bool { flavors?.contains(flavor) ?? true }
    }

    public enum Category: String, Sendable, CaseIterable {
        case bossMods = "Boss Mods", nameplates = "Nameplates", actionBars = "Action Bars", bags = "Bags"
        case raidFrames = "Raid Frames", interfaceSuite = "Interface Replacement", interface = "Interface"
        case auras = "Alerts", dungeons = "Dungeons", combat = "Combat", maps = "Maps", questing = "Questing"
        case collections = "Collections", pvp = "PvP"

        /// One of these is enough: a second boss mod isn't a suggestion.
        var isExclusive: Bool { [.bossMods, .nameplates, .actionBars, .bags, .raidFrames, .interfaceSuite].contains(self) }
    }

    public var entries: [Entry]
    /// Well-known add-ons only CurseForge or Wago have, which Waypoint
    /// can't download: search says so instead of finding nothing.
    public var elsewhere: [String] = []

    public init(entries: [Entry], elsewhere: [String] = []) {
        self.entries = entries
        self.elsewhere = elsewhere
    }

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
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        return entries.enumerated()
            .filter { _, entry in flavor.map(entry.isFor) ?? true }
            .filter { _, entry in
                Self.matches(words, in: [entry.name, entry.author] + entry.folders + entry.keywords + [entry.category?.rawValue ?? ""])
            }
            // Better matches first; the index is in order of popularity.
            .sorted { a, b in
                let (ra, rb) = (Self.rank(a.element.name, words), Self.rank(b.element.name, words))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Popular add-ons for this game that aren't installed: the index is
    /// kept in order of popularity.
    public func suggestions(for flavor: WoWFlavor, excluding installed: Set<AddOnRef>, folders: Set<String>, limit: Int = 6) -> [Entry] {
        // A kind already there (Dominos): no second one (Bartender4).
        let have = Set(entries.filter { installed.contains($0.source) || $0.folders.contains { folders.contains($0.lowercased()) } }
            .compactMap(\.category).filter(\.isExclusive))
        return Array(entries.filter { entry in
            entry.isFor(flavor) && !installed.contains(entry.source) &&
                !entry.folders.contains { folders.contains($0.lowercased()) } &&
                !(entry.category.map(have.contains) ?? false)
        }.prefix(limit))
    }

    /// The CurseForge- or Wago-only add-ons a search names.
    public func elsewhere(matching text: String) -> [String] {
        // Only names that start with what was typed: "bags" isn't AdiBags.
        let query = Self.words(text).joined(separator: " ")
        guard query.count > 2 else { return [] }
        return elsewhere.filter { Self.words($0).joined(separator: " ").hasPrefix(query) }
    }

    /// Lowercased words of a query.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Every query word starts a word in one of the texts ("spo" finds
    /// "Spoken", not "Transportation"); camel case counts ("wigs" finds
    /// "BigWigs").
    static func matches(_ words: [String], in texts: [String]) -> Bool {
        let parts = Set(texts.flatMap(wordStarts))
        // Initials too: "mdt" is Mythic Dungeon Tools, "att" All The Things.
        let initials = Set(texts.map(Self.initials).filter { $0.count > 1 })
        return words.allSatisfy { word in parts.contains { $0.hasPrefix(word) } || initials.contains { $0.hasPrefix(word) && word.count > 1 } }
    }

    /// The first letters of a text's words and camel-case parts.
    static func initials(_ text: String) -> String {
        var letters = ""
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array(word)
            for i in chars.indices where i == 0 || (chars[i].isUppercase && chars[i - 1].isLowercase) {
                letters.append(chars[i])
            }
        }
        return letters.lowercased()
    }

    /// Each word and camel-case part from its start to the end of the word:
    /// "BigWigs_Core" → "bigwigs", "wigs", "core".
    static func wordStarts(_ text: String) -> [String] {
        var starts: [String] = []
        for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array(word)
            for i in chars.indices where i == 0 || (chars[i].isUppercase && chars[i - 1].isLowercase) || (chars[i].isNumber && !chars[i - 1].isNumber) {
                starts.append(String(chars[i...]).lowercased())
            }
        }
        return starts
    }

    /// 0: the name starts with the text, 1: a word of it starts with the
    /// first word, 2: otherwise.
    static func rank(_ name: String, _ words: [String]) -> Int {
        let lower = name.lowercased()
        if lower.hasPrefix(words.joined(separator: " ")) { return 0 }
        if wordStarts(name).contains(where: { $0.hasPrefix(words[0]) }) { return 1 }
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
    /// In order of popularity: suggestions come from the top.
    public static let bundled = AddOnIndex(entries: bundledEntries.map(described), elsewhere: [
        "Details! Damage Meter", "Auctionator", "Baganator", "Bagnon", "Syndicator", "Leatrix Plus", "Leatrix Maps",
        "Method Raid Tools", "RareScanner", "Narcissus", "Plumber", "World Quest Tracker", "Chattynator", "Platynator",
        "Prat", "Rematch", "Hekili", "Kui Nameplates", "AdiBags", "AtlasLoot", "Grid2", "Threat Plates", "RCLootCouncil",
        "Gargul", "VuhDo", "Musician", "BugSack",
    ])

    /// What each add-on does and what kind it is, by hand.
    static let about: [String: (Category, String, [String])] = [
        "Deadly Boss Mods": (.bossMods, "Warns you about boss abilities with timers, sounds and on-screen alerts.", ["dbm"]),
        "BigWigs": (.bossMods, "Light, modular timers and warnings for raid bosses.", []),
        "LittleWigs": (.bossMods, "BigWigs timers and warnings for dungeon bosses.", []),
        "BigWigs Voice": (.bossMods, "Spoken warnings for BigWigs.", []),
        "Plater Nameplates": (.nameplates, "Nameplates with threat colors, cast bars and your own scripts.", []),
        "WeakAuras": (.auras, "Build your own on-screen alerts for buffs, cooldowns and more.", ["wa"]),
        "TellMeWhen": (.auras, "Icons that light up when a spell, buff or cooldown matters.", ["tmw"]),
        "Raider.IO": (.dungeons, "Mythic+ and raid scores in tooltips and the group finder.", ["rio", "raiderio"]),
        "Mythic Dungeon Tools": (.dungeons, "Plan Mythic+ routes: which packs to pull, on the dungeon map.", []),
        "ElvUI": (.interfaceSuite, "Replaces the whole interface: unit frames, bars, bags, chat and more.", []),
        "Tukui": (.interfaceSuite, "A minimal replacement for the whole interface.", []),
        "All The Things": (.collections, "Tracks every mount, pet, toy and appearance you're missing, and where to get it.", ["att"]),
        "Rarity": (.collections, "Counts your attempts at rare mounts, pets and toys.", []),
        "Bartender4": (.actionBars, "Moves, resizes and hides your action bars.", []),
        "Dominos": (.actionBars, "Moves, resizes and hides your action bars.", []),
        "tullaRange": (.combat, "Turns action buttons red when your target is out of range.", []),
        "OmniCC": (.combat, "Shows cooldowns as numbers on your buttons.", []),
        "Quartz": (.combat, "Cast bars you can move and style, for you, your target and focus.", []),
        "BigDebuffs": (.combat, "Shows important debuffs and crowd control larger on unit frames.", []),
        "SimulationCraft": (.combat, "Exports your character for SimulationCraft and Raidbots.", ["simc", "raidbots"]),
        "Questie": (.questing, "Shows quest givers, objectives and turn-ins on your map.", []),
        "HandyNotes": (.maps, "Adds notes and points of interest to your map.", []),
        "Mapster": (.maps, "A cleaner world map you can resize and fade.", []),
        "SexyMap": (.maps, "Reshapes and decorates the minimap.", []),
        "BetterBags": (.bags, "One bag window, sorted into categories for you.", []),
        "Inventorian": (.bags, "One window for all your bags, and one for the bank.", []),
        "BagSync": (.bags, "Shows which of your characters has an item: in bags, banks or mail.", []),
        "Cell": (.raidFrames, "Party and raid frames made for healers.", []),
        "Raid Frame Settings": (.raidFrames, "More options for the game's own raid frames.", []),
        "Decursive": (.raidFrames, "Click to dispel debuffs on your group.", []),
        "Masque": (.interface, "Skins for your action buttons and other add-ons.", []),
        "BlizzMove": (.interface, "Lets you move the game's own windows.", []),
        "Advanced Interface Options": (.interface, "Hidden game settings in a simple menu.", ["aio"]),
        "Edit Mode Expanded": (.interface, "Adds more frames to the game's Edit Mode.", []),
        "Capping": (.pvp, "Battleground timers and objectives.", []),
    ]

    static func described(_ entry: Entry) -> Entry {
        var entry = entry
        if let (category, summary, keywords) = about[entry.name] {
            (entry.category, entry.summary, entry.keywords) = (category, summary, keywords)
        }
        return entry
    }

    static let bundledEntries: [Entry] = [
        github("Deadly Boss Mods", "MysticalOS", "DeadlyBossMods/DeadlyBossMods", ["DBM-Core", "DBM-GUI", "DBM-StatusBarTimers"], curse: "3358", wago: "qv633o6b", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("BigWigs", "Funkeh", "BigWigsMods/BigWigs", ["BigWigs", "BigWigs_Core", "BigWigs_Options", "BigWigs_Plugins"], curse: "2382", wago: "5NRegwG3", wowi: "5086", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("Plater Nameplates", "Tercioo", "Tercioo/Plater-Nameplates", ["Plater"], curse: "100547", wago: "kRNLep6o", flavors: [.forever, .mainline, .mists, .tbc, .titan, .vanilla]),
        github("WeakAuras", "The WeakAuras Team", "WeakAuras/WeakAuras2", ["WeakAuras", "WeakAurasArchive", "WeakAurasModelPaths", "WeakAurasOptions", "WeakAurasTemplates"], curse: "65387", wago: "VBNBxKx5", wowi: "24910", flavors: [.cata, .mists, .tbc, .titan, .vanilla]),
        github("Raider.IO", "Vladinator", "RaiderIO/raiderio-addon", ["RaiderIO"], curse: "279257", wago: "b6mb0XKP", flavors: [.mainline]),
        github("Mythic Dungeon Tools", "Nnoggie", "Nnoggie/MythicDungeonTools", ["MythicDungeonTools", "MythicDungeonTools_UI"], curse: "288981", wago: "rN4VrAKD", flavors: [.mainline]),
        Entry(name: "ElvUI", author: "Elv", folders: ["ElvUI", "ElvUI_Options", "ElvUI_Libraries"], source: AddOnRef(.tukui, "elvui"),
              flavors: [.mainline, .forever, .mists, .vanilla, .tbc]),
        github("All The Things", "Crieve", "ATTWoWAddon/AllTheThings", ["AllTheThings"], curse: "267285", wago: "yQKyY5K7", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("Bartender4", "Nevcairiel", "Nevcairiel/Bartender4", ["Bartender4"], curse: "13501", wago: "v63oVn6b", wowi: "11190", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Dominos", "Tuller", "tullamods/Dominos", ["Dominos", "Dominos_Cast", "Dominos_Config", "Dominos_Progress", "Dominos_Roll"], flavors: [.forever, .mainline, .mists, .tbc, .titan, .vanilla]),
        github("OmniCC", "Tuller", "tullamods/OmniCC", ["OmniCC", "OmniCC_Config"], flavors: [.mists, .tbc, .titan, .vanilla]),
        github("Questie", "Aero", "Questie/Questie", ["Questie", "QuestieDB", "QuestieTrace"], curse: "334372", wago: "qv634BKb", flavors: [.forever, .mists, .tbc, .titan, .vanilla]),
        github("TellMeWhen", "Cybeloras of Aerie Peak", "ascott18/TellMeWhen", ["TellMeWhen", "TellMeWhen_Options"], curse: "8025", wago: "ZQ6aZqKW", wowi: "10855", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("HandyNotes", "Xinhuan", "Nevcairiel/HandyNotes", ["HandyNotes"], curse: "14154", wago: "mNwQMlKo", wowi: "15716", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Masque", "StormFX", "SFX-WoW/Masque", ["Masque"], curse: "13592", wago: "kRNLgpGo", wowi: "12097", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("BetterBags", "Cidan", "Cidan/BetterBags", ["BetterBags"], curse: "942432", wago: "aNDmy96o", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("LittleWigs", "Funkeh", "BigWigsMods/LittleWigs", ["LittleWigs"], curse: "4383", wago: "5bGolnN0", wowi: "9577", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath], requires: ["BigWigsMods/BigWigs"]),
        github("SimulationCraft", "Theck", "simulationcraft/simc-addon", ["Simulationcraft"], curse: "82745", wago: "BNBeRVGx", flavors: [.forever, .mainline]),
        github("Cell", "enderneko", "enderneko/Cell", ["Cell"], curse: "409666", wago: "qv63LLKb", wowi: "26244", flavors: [.cata, .mists, .tbc, .titan, .vanilla]),
        github("Quartz", "Nevcairiel", "Nevcairiel/Quartz", ["Quartz"], curse: "4558", wowi: "7158", flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Mapster", "Nevcairiel", "Nevcairiel/Mapster", ["Mapster"], curse: "14376", wowi: "8306", flavors: [.forever, .mainline]),
        github("BagSync", "Xruptor", "Xruptor/BagSync", ["BagSync"], curse: "22067", wago: "xZKxjQNk", wowi: "15351", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("Rarity", "Allara", "WowRarity/Rarity", ["Rarity", "Rarity_Options"], curse: "30801", flavors: [.mists, .vanilla]),
        github("Decursive", "John Wellesz", "2072/Decursive", ["Decursive"], curse: "2154", flavors: [.mainline, .titan]),
        github("BigDebuffs", "Jordon", "jordonwow/bigdebuffs", ["BigDebuffs"], curse: "82697", wago: "WYK98e6L", wowi: "26006", flavors: [.mainline, .mists, .tbc, .titan, .vanilla]),
        github("SexyMap", "Funkeh", "funkydude/SexyMap", ["SexyMap"], curse: "15936", wago: "e56no0K9", wowi: "21538", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("BlizzMove", "Kiatra", "Kiatra/BlizzMove", ["BlizzMove", "BlizzMove_Debug"], curse: "17809", wowi: "23875", flavors: [.cata, .forever, .mainline, .mists, .tbc, .vanilla, .wrath]),
        github("Capping", "Funkeh", "BigWigsMods/Capping", ["Capping", "Capping_Options"], curse: "20143", wago: "Rn6VXOGd", wowi: "11177", flavors: [.cata, .forever, .mainline, .mists, .tbc, .titan, .vanilla, .wrath]),
        github("Advanced Interface Options", "Stanzilla", "Stanzilla/AdvancedInterfaceOptions", ["AdvancedInterfaceOptions"], curse: "99982", wago: "ZQ6aPNW7", wowi: "25002", flavors: [.cata, .forever, .mainline, .mists, .tbc, .vanilla, .wrath]),
        github("Edit Mode Expanded", "Teelo", "teelolws/EditModeExpanded", ["EditModeExpanded"], curse: "695703", flavors: [.forever, .mainline, .mists, .tbc]),
        github("Raid Frame Settings", "Slothpala", "Slothpala/RaidFrameSettings", ["RaidFrameSettings", "RaidFrameSettingsOptions"], curse: "688930", flavors: [.forever, .mainline]),
        github("tullaRange", "Tuller", "tullamods/tullaRange", ["tullaRange", "tullaRange_Config"], flavors: [.forever, .mainline, .mists, .tbc, .vanilla]),
        github("Inventorian", "Nevcairiel", "Nevcairiel/Inventorian", ["Inventorian", "Inventorian_BagBrother"], curse: "85646", flavors: [.forever, .mainline]),
        github("BigWigs Voice", "Funkeh", "BigWigsMods/BigWigs_Voice", ["BigWigs_Voice"], curse: "87513", wowi: "24218", flavors: [.mainline], requires: ["BigWigsMods/BigWigs"]),
        Entry(name: "Tukui", author: "Tukz", folders: ["Tukui"], source: AddOnRef(.tukui, "tukui"), flavors: [.mainline, .mists, .vanilla]),
    ]
}
