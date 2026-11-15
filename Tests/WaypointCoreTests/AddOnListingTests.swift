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
    #expect(checking.map(\.key) == ["h:Checking for Updates…", "r:\(dbm)", "o:false"], "nothing is Up to Date before the check")
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
    let items = AddOnListing.items(state, othersExpanded: true)
    #expect(items.map(\.key) == ["h:Updates", "r:\(dbm)", "h:Up to Date", "r:\(omni)", "h:Couldn’t Check", "r:\(tomtom)",
                                 "o:true", "r:\(details)", "r:folder:MyTweaks"])
    guard case .row(let update) = items[1], case .row(let couldnt) = items[5], case .row(let behind) = items[7] else {
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
