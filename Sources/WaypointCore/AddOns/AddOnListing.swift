import Foundation

/// What the Add-Ons sheet shows, worked out from the model's state alone,
/// so every line can be tested: it says only what's known. Nothing is "Up
/// to Date" before the check has answered, an add-on whose source can't
/// keep it current isn't listed as kept, and what Waypoint doesn't update
/// is one quiet row until asked for.
public enum AddOnListing {
    public enum Action: Equatable, Sendable {
        case update(evenIfChanged: Bool)
        case install
    }

    public struct Row: Equatable, Sendable {
        public var id: String
        public var name: String
        public var detail: String
        public var isFailure = false
        public var tooltip: String?
        public var action: Action?
        public var actionTitle: String?
        public var progress: Double?
    }

    public enum Item: Equatable, Sendable {
        case header(String)
        case row(Row)
        case note(String)
        /// "28 Other Add-Ons": the add-ons Waypoint doesn't update, shown
        /// when opened.
        case others(count: Int, isExpanded: Bool)

        public var key: String {
            switch self {
            case .header(let title): "h:\(title)"
            case .row(let row): "r:\(row.id)"
            case .note(let text): "n:\(text)"
            case .others(_, let open): "o:\(open)"
            }
        }
    }

    enum Placement: Equatable { case updates, kept, current, checking, unchecked, others }

    static let changedMessage = AddOnError.changedLocally.errorDescription!
    public static let othersHelp = "Waypoint keeps add-ons up to date when they’re published on GitHub, WoWInterface or Tukui and it can tell which add-on they are. It can’t for these: most come from CurseForge or Wago, which don’t let other apps download from them, and some are older there than the copy you have. Keep updating them where you got them."

    static func placement(of addOn: InstalledAddOn, in state: AddOnsModel.State) -> Placement {
        guard addOn.isManaged else { return .others }
        if case .downloading? = state.activity[addOn.id] { return .updates }
        if state.update(for: addOn) != nil { return .updates }
        switch state.updates[addOn.id] {
        case nil: return state.lastChecked == nil ? .checking : .kept
        case .current(let release):
            // A source behind the copy on disk (WoWInterface's 2020 Details)
            // can't keep it current.
            if addOn.record == nil, let version = addOn.version,
               AddOnLibrary.normalized(version) != AddOnLibrary.normalized(release.version) { return .others }
            // Recognized by name alone: current, but not kept until updated once.
            return state.keepsCurrent && addOn.isMatchedByName ? .current : .kept
        case .unavailable(.unavailable): return .unchecked
        case .unavailable: return .others
        case .available: return .updates
        }
    }

    /// The sheet's rows. `search` empty: the sections. Otherwise the
    /// installed add-ons that match, then what can be installed.
    /// `flavorKnown` false: a game Waypoint can't place, so it updates
    /// nothing there; the add-ons are just listed.
    public static func items(_ state: AddOnsModel.State, othersExpanded: Bool, search: String = "",
                             results: [AddOnSearchResult] = [], isSearching: Bool = false, searchFailure: String? = nil,
                             flavorKnown: Bool = true) -> [Item] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty {
            let installed = state.addOns.filter {
                $0.name.lowercased().contains(text) || $0.folders.contains { $0.lowercased().contains(text) }
            }
            var items: [Item] = []
            if !installed.isEmpty { items.append(.header("Installed")); items += installed.map { .row(row(for: $0, in: state)) } }
            let have = Set(state.addOns.compactMap(\.ref))
            let available = results.filter { !have.contains($0.ref) }
            items.append(.header("Available"))
            if available.isEmpty {
                items.append(.note(searchFailure ?? (isSearching ? "Searching…" : "No add-ons found.")))
            } else {
                items += available.map { .row(row(for: $0, in: state)) }
                if isSearching { items.append(.note("Searching WoWInterface…")) }
            }
            return items
        }
        guard state.hasScanned else { return [.note("Reading add-ons…")] }
        guard !state.addOns.isEmpty else { return [.note("No add-ons yet. Search to add one.")] }
        guard flavorKnown else {
            return [.header("Installed")] + state.addOns.map { addOn in
                var row = row(for: addOn, in: state)
                (row.action, row.actionTitle) = (nil, nil)
                return .row(row)
            }
        }
        var groups: [Placement: [InstalledAddOn]] = [:]
        for addOn in state.addOns { groups[placement(of: addOn, in: state), default: []].append(addOn) }
        var items: [Item] = []
        let titles: [(Placement, String)] = [
            (.updates, "Updates"),
            (.kept, state.keepsCurrent ? "Kept Up to Date" : "Up to Date"),
            (.current, "Up to Date"),
            (.checking, "Checking for Updates…"),
            (.unchecked, "Couldn’t Check"),
        ]
        for (placement, title) in titles {
            guard let addOns = groups[placement], !addOns.isEmpty else { continue }
            items.append(.header(title))
            items += addOns.map { .row(row(for: $0, in: state)) }
        }
        if let others = groups[.others], !others.isEmpty {
            items.append(.others(count: others.count, isExpanded: othersExpanded))
            if othersExpanded { items += others.map { .row(row(for: $0, in: state)) } }
        }
        return items
    }

    public static func row(for addOn: InstalledAddOn, in state: AddOnsModel.State) -> Row {
        var row = Row(id: addOn.id, name: addOn.name, detail: addOn.version ?? "", tooltip: tooltip(addOn))
        switch addOn.unmanaged {
        case .notForThisVersion: row.detail = "Not for this version of the game"
        case .link, .developmentCopy: row.detail = "Added by hand"
        case .curseForge: row.detail = [addOn.version, "CurseForge"].compactMap { $0 }.joined(separator: " · ")
        case .wago: row.detail = [addOn.version, "Wago"].compactMap { $0 }.joined(separator: " · ")
        case .unknown, nil: break
        }
        switch state.updates[addOn.id] {
        case .available(let release):
            row.detail = "\(addOn.version ?? "") → \(release.version)"
            let changed = state.failures[addOn.id] == changedMessage
            row.action = .update(evenIfChanged: changed)
            row.actionTitle = changed ? "Replace" : "Update"
        case .current(let release):
            if placement(of: addOn, in: state) == .others {
                row.detail = "\(addOn.version ?? "") · \(release.ref.source.displayName) has \(release.version)"
            }
        case .unavailable(.unavailable): row.detail = [addOn.version, "\(addOn.ref?.source.displayName ?? "The source") didn’t answer"].compactMap { $0 }.joined(separator: " · ")
        case .unavailable(.noRelease): row.detail = [addOn.version, "No longer available"].compactMap { $0 }.joined(separator: " · ")
        case .unavailable(.notForThisVersion): row.detail = [addOn.version, "No version for this game"].compactMap { $0 }.joined(separator: " · ")
        case nil: break
        }
        if let failure = state.failures[addOn.id] { row.detail = failure; row.isFailure = true }
        switch state.activity[addOn.id] {
        case .downloading(let fraction)?: row.progress = fraction; row.action = nil; row.actionTitle = nil
        case .removing?: row.detail = "Moving to the Trash…"; row.action = nil; row.actionTitle = nil; row.isFailure = false
        case nil: break
        }
        return row
    }

    public static func row(for result: AddOnSearchResult, in state: AddOnsModel.State) -> Row {
        var row = Row(id: result.id, name: result.name, detail: result.author.map { "by \($0)" } ?? "",
                      tooltip: "From \(result.ref.source.displayName)", action: .install, actionTitle: "Install")
        if let failure = state.failures[result.id] { row.detail = failure; row.isFailure = true }
        if case .downloading(let fraction)? = state.activity[result.id] { row.progress = fraction; row.action = nil; row.actionTitle = nil }
        return row
    }

    static func tooltip(_ addOn: InstalledAddOn) -> String {
        let folders = addOn.folders.count > 1 ? "Folders: \(addOn.folders.joined(separator: ", "))" : "Folder: \(addOn.folders.first ?? "")"
        guard let ref = addOn.ref else { return folders }
        return "From \(ref.source.displayName)\n\(folders)"
    }

    /// The line under the list, if any.
    public static func footer(_ state: AddOnsModel.State, gameName: String, flavorKnown: Bool, isRunning: Bool,
                              isSearching: Bool = false) -> String? {
        if !flavorKnown { return AddOnError.unknownGame.errorDescription }
        if let failure = state.scanFailure { return failure }
        if isRunning, state.changedWhileRunning { return "Restart \(gameName) to load the updated add-ons." }
        if !isSearching, state.hasScanned, !state.keepsCurrent, state.addOns.contains(where: \.isManaged) {
            return "After your first update or install here, Waypoint keeps these add-ons up to date on its own."
        }
        return nil
    }
}
