import Foundation
import Testing
@testable import WaypointCore

private func addOn(_ name: String, version: String? = "1.0", ref: AddOnRef? = nil, unmanaged: InstalledAddOn.Unmanaged? = nil,
                   recorded: Bool = false) -> InstalledAddOn {
    var addOn = InstalledAddOn(id: ref?.description ?? "folder:\(name)", name: name, folders: [name], version: version, ref: ref,
                               unmanaged: ref == nil ? (unmanaged ?? .unknown) : nil)
    if recorded, let ref {
        let release = AddOnRelease(ref: ref, id: version ?? "", version: version ?? "", date: nil, download: URL(string: "https://github.com/x")!)
        addOn.record = AddOnRecord(ref: ref, name: name, mainFolder: name, folders: [name], release: release, folderHashes: [:], tocVersion: version)
    }
    return addOn
}

private func release(_ ref: AddOnRef, _ version: String) -> AddOnRelease {
    AddOnRelease(ref: ref, id: version, version: version, date: nil, download: URL(string: "https://github.com/x")!)
}

private let dbm = AddOnRef(.github, "DeadlyBossMods/DeadlyBossMods"), omni = AddOnRef(.github, "tullamods/OmniCC")
private let tomtom = AddOnRef(.wowInterface, "4111"), details = AddOnRef(.wowInterface, "23056")

@Test func nothingIsSaidBeforeItsKnown() {
    var state = AddOnsModel.State()
    #expect(AddOnListing.items(state, othersExpanded: false) == [.note("Reading add-ons…")])
    state.hasScanned = true
    #expect(AddOnListing.items(state, othersExpanded: false) == [.note("No add-ons yet. Search to add one.")])
    state.addOns = [addOn("Deadly Boss Mods", ref: dbm), addOn("Details", unmanaged: .curseForge("1"))]
    let checking = AddOnListing.items(state, othersExpanded: false)
    #expect(checking.map(\.key) == ["h:Checking for Updates…", "r:\(dbm)", "o:1:false"], "nothing is Up to Date before the check")
}

@Test func addOnsGoWhereWhatsKnownPutsThem() {
    var state = AddOnsModel.State()
    state.hasScanned = true
    state.lastChecked = Date()
    state.addOns = [addOn("Deadly Boss Mods", version: "1", ref: dbm), addOn("OmniCC", version: "11.2.8", ref: omni),
                    addOn("TomTom", ref: tomtom), addOn("Details", version: "12.1.4", ref: details), addOn("MyTweaks")]
    state.updates = [dbm.description: .available(release(dbm, "2")), omni.description: .current(release(omni, "11.2.8")),
                     tomtom.description: .unavailable(.unavailable),
                     // WoWInterface's Details is years behind the copy on disk.
                     details.description: .current(release(details, "DetailsRetail-v8.2.5"))]
    let items = AddOnListing.items(state, othersExpanded: false)
    #expect(items.map(\.key) == ["h:Updates", "r:\(dbm)", "h:Up to Date", "r:\(omni)", "h:Couldn’t Check", "r:\(tomtom)", "o:2:false"])
    // The others' own page: the reason, then them alone.
    let others = AddOnListing.items(state, othersExpanded: true)
    #expect(others.map(\.key) == ["n:\(AddOnListing.othersHelp)", "r:\(details)", "r:folder:MyTweaks"])
    guard case .row(let update) = items[1], case .row(let couldnt) = items[5], case .row(let behind) = others[1] else {
        Issue.record("rows"); return
    }
    #expect(update.detail == "1 → 2" && update.actionTitle == "Update")
    #expect(couldnt.detail == "1.0 · WoWInterface didn’t answer")
    // A game Waypoint can't place: listed, no sections, no buttons.
    let unknown = AddOnListing.items(state, othersExpanded: false, flavorKnown: false)
    #expect(unknown.first == .header("Installed") && unknown.count == 6)
    #expect(behind.detail == "12.1.4 · WoWInterface has DetailsRetail-v8.2.5" && behind.action == nil)
    state.keepsCurrent = true
    #expect(AddOnListing.items(state, othersExpanded: false).map(\.key).contains("h:Kept Up to Date"))
    #expect(AddOnListing.items(state, othersExpanded: false).last == .others(count: 2, isExpanded: false))
}

@Test func theFooterTellsWhatsTrueNow() {
    var state = AddOnsModel.State()
    state.hasScanned = true
    state.addOns = [addOn("OmniCC", ref: omni)]
    #expect(AddOnListing.footer(state, gameName: "WoW", flavorKnown: true, isRunning: false)?.contains("first update or install") == true)
    #expect(AddOnListing.footer(state, gameName: "WoW", flavorKnown: true, isRunning: false, isSearching: true) == nil)
    state.keepsCurrent = true
    #expect(AddOnListing.footer(state, gameName: "WoW", flavorKnown: true, isRunning: true) == nil)
    state.changedWhileRunning = true
    #expect(AddOnListing.footer(state, gameName: "WoW", flavorKnown: true, isRunning: true) == "Restart WoW to load the updated add-ons.")
    #expect(AddOnListing.footer(state, gameName: "WoW", flavorKnown: false, isRunning: false) == AddOnError.unknownGame.errorDescription)
}

@Test func searchShowsMatchesAndWhatsStillComing() {
    var state = AddOnsModel.State()
    state.hasScanned = true
    state.addOns = [addOn("OmniCC", ref: omni)]
    let results = [AddOnSearchResult(ref: omni, name: "OmniCC", author: "Tuller"),
                   AddOnSearchResult(ref: AddOnRef(.wowInterface, "1"), name: "OmniBar", author: "x")]
    let items = AddOnListing.items(state, othersExpanded: false, search: "omni", results: results, isSearching: true)
    #expect(items.map(\.key) == ["h:Installed", "r:\(omni)", "h:Available", "r:wowInterface:1", "n:Searching WoWInterface…"])
    #expect(AddOnListing.items(state, othersExpanded: false, search: "zzz", results: []).last == .note("No add-ons found."))
    var bigWigs = addOn("BigWigs", ref: AddOnRef(.github, "BigWigsMods/BigWigs"))
    bigWigs.folders = ["BigWigs", "BigWigs_Sporefall"]
    state.addOns = [bigWigs]
    #expect(!AddOnListing.items(state, othersExpanded: false, search: "spo").contains(.header("Installed")))
}

@Test func onlyWhatsReallyKeptIsListedAsKept() {
    var state = AddOnsModel.State()
    (state.hasScanned, state.lastChecked, state.keepsCurrent) = (true, Date(), true)
    var byName = addOn("OmniCC", version: "11.2.8", ref: omni)
    byName.isMatchedByName = true
    state.addOns = [addOn("Deadly Boss Mods", version: "2", ref: dbm), byName]
    state.updates = [dbm.description: .current(release(dbm, "2")), omni.description: .current(release(omni, "11.2.8"))]
    #expect(AddOnListing.items(state, othersExpanded: false).map(\.key) ==
            ["h:Kept Up to Date", "r:\(dbm)", "h:Up to Date", "r:\(omni)"])
}

@Test func eachAddOnSaysInOneSentenceWhyItIsntKept() {
    var state = AddOnsModel.State()
    (state.hasScanned, state.lastChecked) = (true, Date())
    let curse = addOn("Auctionator", unmanaged: .curseForge("1"))
    let mine = addOn("MyTweaks")
    let behind = addOn("Details", version: "12.1.4", ref: details)
    state.addOns = [curse, mine, behind, addOn("Deadly Boss Mods", version: "2", ref: dbm)]
    state.updates = [details.description: .current(release(details, "8.2.5")), dbm.description: .current(release(dbm, "2"))]
    #expect(AddOnListing.reason(for: curse, in: state)?.hasPrefix("It comes from CurseForge") == true)
    #expect(AddOnListing.reason(for: mine, in: state)?.contains("doesn’t know where") == true)
    #expect(AddOnListing.reason(for: behind, in: state) == "WoWInterface’s newest version, 8.2.5, is older than this copy, so Waypoint leaves it alone.")
    #expect(AddOnListing.reason(for: state.addOns[3], in: state) == nil)
}

@Test func searchMatchesTheStartsOfWords() {
    #expect(AddOnIndex.matches(["spo"], in: ["Spoken"]))
    #expect(!AddOnIndex.matches(["spo"], in: ["Atlas Transportation"]))
    #expect(AddOnIndex.matches(["wigs"], in: ["BigWigs"]), "camel case counts")
    #expect(AddOnIndex.matches(["dbm"], in: ["Deadly Boss Mods", "DBM-Core"]))
    #expect(AddOnIndex.matches(["boss", "dead"], in: ["Deadly Boss Mods"]))
    #expect(AddOnIndex.wordStarts("BigWigs_Core") == ["bigwigs", "wigs", "core"])
}

@Test func discoveryFindsWhatPeopleCallThings() {
    let index = AddOnIndex.bundled
    #expect(index.search("mdt", flavor: .mainline).first?.name == "Mythic Dungeon Tools")
    #expect(index.search("att", flavor: .mainline).first?.name == "All The Things")
    #expect(index.search("rio", flavor: .mainline).first?.name == "Raider.IO")
    #expect(index.search("bags", flavor: .mainline).contains { $0.name == "BetterBags" }, "by kind")
    #expect(index.search("!", flavor: .mainline).isEmpty)
    #expect(index.entries.allSatisfy { $0.summary != nil && $0.category != nil }, "every entry says what it does")
    #expect(index.elsewhere(matching: "details") == ["Details! Damage Meter"])
    #expect(index.elsewhere(matching: "bags").isEmpty, "not a name the person didn't type")
    // Dominos is there: no second action bar add-on, nor a whole new interface.
    let dominos = index.entries.first { $0.name == "Dominos" }!
    let suggested = index.suggestions(for: .mainline, excluding: [dominos.source], folders: ["dominos"]).map(\.name)
    #expect(!suggested.contains("Bartender4") && !suggested.contains("Dominos"))
    #expect(suggested.first == "Deadly Boss Mods")
    let dbmEntry = index.entries.first { $0.name == "Deadly Boss Mods" }!
    #expect(!index.suggestions(for: .mainline, excluding: [dbmEntry.source], folders: []).map(\.name).contains("BigWigs"))
}

@Test func searchSaysWhenAWellKnownAddOnIsOnlyElsewhere() {
    var state = AddOnsModel.State()
    state.hasScanned = true
    let items = AddOnListing.items(state, othersExpanded: false, search: "details", results: [], elsewhere: ["Details! Damage Meter"])
    #expect(items == [.note("Details! Damage Meter is only on CurseForge or Wago, which don’t let other apps download from them.")])
    #expect(AddOnListing.items(state, othersExpanded: false, search: "!!").contains(.header("Installed")) == false)
}

@Test func anAddOnsPageSaysOnlyWhatsKnown() {
    var state = AddOnsModel.State()
    (state.hasScanned, state.lastChecked) = (true, Date())
    var installed = addOn("Deadly Boss Mods", version: "1", ref: dbm)
    installed.author = "MysticalOS"
    state.addOns = [installed]
    state.updates = [dbm.description: .available(release(dbm, "2"))]
    let entry = AddOnIndex.bundled.entries.first { $0.name == "Deadly Boss Mods" }
    let page = try! #require(AddOnListing.detail(installed: installed, result: nil, entry: entry, latest: nil, details: nil, in: state))
    #expect(page.byline == "by MysticalOS · from GitHub")
    #expect(page.summary == entry?.summary)
    #expect(page.facts.map(\.title) == ["Installed", "Newest"])
    #expect(page.whatsNew?.absoluteString == "https://github.com/DeadlyBossMods/DeadlyBossMods/releases/tag/2")
    #expect(page.actionTitle == "Update")

    // Up to date: no "Newest".
    state.updates = [dbm.description: .current(release(dbm, "1"))]
    #expect(AddOnListing.detail(installed: installed, result: nil, entry: entry, latest: nil, details: nil, in: state)?.facts.map(\.title) == ["Installed"])

    // Not installed, nothing for this game: no Install.
    let result = AddOnSearchResult(ref: omni, name: "OmniCC", author: "Tuller")
    let none = AddOnListing.detail(installed: nil, result: result, entry: nil, latest: .failure(.notForThisVersion), details: nil, in: state)
    #expect(none?.actionTitle == nil && none?.status == "There’s no version of it for this game yet.")
    let some = AddOnListing.detail(installed: nil, result: result, entry: nil, latest: .success(release(omni, "11.2.9")), details: nil, in: state)
    #expect(some?.actionTitle == "Install" && some?.facts.first == .init(title: "Version", value: "11.2.9"))

    // CurseForge: the TOC's own notes, and why.
    var curse = addOn("Auctionator", unmanaged: .curseForge("1"))
    curse.notes = "Auction house prices and search."
    let cursePage = AddOnListing.detail(installed: curse, result: nil, entry: nil, latest: nil, details: nil, in: state)
    #expect(cursePage?.summary == "Auction house prices and search." && cursePage?.status?.hasPrefix("It comes from CurseForge") == true)
    #expect(cursePage?.webPage?.absoluteString == "https://www.curseforge.com/projects/1")
}

@Test func wowInterfaceDescriptionsBecomeOneParagraph() {
    let text = WoWInterfaceAddOnSource.plain("[size=5][b]About[/b][/size]\r\n\r\n[img]x.png[/img]Masque is a [url=https://x]skinning[/url] engine for button-based add-ons and the game’s own bars.\n\n[b]Skin[/b]")
    #expect(WoWInterfaceAddOnSource.firstParagraph(text) == "Masque is a skinning engine for button-based add-ons and the game’s own bars.")
}
