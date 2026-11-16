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
            case .others(let count, let open): "o:\(count):\(open)"
            }
        }
    }

    public enum Placement: Equatable, Sendable { case updates, kept, current, checking, unchecked, others }

    static let changedMessage = AddOnError.changedLocally.errorDescription!
    public static let othersHelp = "Waypoint keeps add-ons up to date when they’re published on GitHub, WoWInterface or Tukui and it can tell which add-on they are. It can’t for these: most come from CurseForge or Wago, which don’t let other apps download from them, and some are older there than the copy you have. Keep updating them where you got them."

    public static func placement(of addOn: InstalledAddOn, in state: AddOnsModel.State) -> Placement {
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
    /// `othersExpanded`: the "Other Add-Ons" page, those add-ons alone under
    /// the reason. `elsewhere`: well-known add-ons the search names that
    /// only CurseForge or Wago have.
    public static func items(_ state: AddOnsModel.State, othersExpanded: Bool, search: String = "",
                             results: [AddOnSearchResult] = [], isSearching: Bool = false, searchFailure: String? = nil,
                             flavorKnown: Bool = true, elsewhere: [String] = []) -> [Item] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        // Only punctuation is no search at all.
        if !AddOnIndex.words(text).isEmpty {
            // By name and main folder, at the start of a word: not by a
            // module folder ("spo" isn't BigWigs for BigWigs_Sporefall).
            let words = AddOnIndex.words(text)
            let installed = state.addOns.filter { AddOnIndex.matches(words, in: [$0.name] + $0.folders.prefix(1)) }
            var items: [Item] = []
            if !installed.isEmpty { items.append(.header("Installed")); items += installed.map { .row(row(for: $0, in: state)) } }
            let have = Set(state.addOns.compactMap(\.ref))
            let available = results.filter { !have.contains($0.ref) }
            // Not for one that's offered, or already installed.
            let offered = Set((available.map(\.name) + state.addOns.map(\.name)).map { $0.lowercased() })
            let notHere = elsewhere.filter { !offered.contains($0.lowercased()) }
            if !available.isEmpty || isSearching || notHere.isEmpty { items.append(.header("Available")) }
            if available.isEmpty {
                if let searchFailure { items.append(.note(searchFailure)) }
                else if isSearching { items.append(.note("Searching…")) }
                else if notHere.isEmpty { items.append(.note("No add-ons found.")) }
            } else {
                items += available.map { .row(row(for: $0, in: state)) }
                if isSearching { items.append(.note("Searching WoWInterface…")) }
            }
            for name in notHere {
                items.append(.note("\(name) is only on CurseForge or Wago, which don’t let other apps download from them."))
            }
            return items
        }
        guard state.hasScanned else { return [.note("Reading add-ons…")] }
        if othersExpanded {
            let others = state.addOns.filter { placement(of: $0, in: state) == .others }
            return [.note(othersHelp)] + others.map { .row(row(for: $0, in: state)) }
        }
        guard !state.addOns.isEmpty else {
            guard !state.suggestions.isEmpty else { return [.note("No add-ons yet. Search to add one.")] }
            return [.header("Popular")] + state.suggestions.map { .row(row(for: $0, in: state)) }
        }
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
            items.append(.others(count: others.count, isExpanded: false))
        }
        if !state.suggestions.isEmpty {
            items.append(.header("Popular"))
            items += state.suggestions.map { .row(row(for: $0, in: state)) }
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
        var row = Row(id: result.id, name: result.name, detail: result.summary ?? result.author.map { "by \($0)" } ?? "",
                      tooltip: "From \(result.ref.source.displayName)", action: .install, actionTitle: "Install")
        if let failure = state.failures[result.id] { row.detail = failure; row.isFailure = true }
        if case .downloading(let fraction)? = state.activity[result.id] { row.progress = fraction; row.action = nil; row.actionTitle = nil }
        return row
    }

    /// One sentence on why Waypoint doesn't keep this add-on up to date, for
    /// its page; nil when it does.
    public static func reason(for addOn: InstalledAddOn, in state: AddOnsModel.State) -> String? {
        switch addOn.unmanaged {
        case .curseForge: return "It comes from CurseForge, which doesn’t let other apps download from it. Keep updating it in the CurseForge app."
        case .wago: return "It comes from Wago, which doesn’t let other apps download from it. Keep updating it in the Wago app."
        case .unknown: return "Waypoint doesn’t know where this add-on comes from, so it leaves it alone."
        case .link, .developmentCopy: return "It was put here by hand (a link or a developer’s copy), so Waypoint leaves it alone."
        case .notForThisVersion: return "It isn’t made for this version of the game."
        case nil: break
        }
        switch state.updates[addOn.id] {
        case .current(let release)? where placement(of: addOn, in: state) == .others:
            return "\(release.ref.source.displayName)’s newest version, \(release.version), is older than this copy, so Waypoint leaves it alone."
        case .unavailable(.noRelease)?: return "It’s no longer available from \(addOn.ref?.source.displayName ?? "its source")."
        case .unavailable(.notForThisVersion)?: return "There’s no version of it for this version of the game yet."
        default: break
        }
        if state.keepsCurrent, addOn.isMatchedByName, addOn.record == nil {
            return "Waypoint recognizes it by its folder name. Update it once here and it’s kept up to date on its own."
        }
        return nil
    }

    /// An add-on's page, line by line.
    public struct Detail: Equatable, Sendable {
        public struct Fact: Equatable, Sendable {
            public var title: String
            public var value: String
        }
        public var name: String
        public var byline: String?
        public var summary: String?
        /// A problem, or why Waypoint doesn't keep it up to date.
        public var status: String?
        public var isFailure = false
        public var action: Action?
        public var actionTitle: String?
        public var progress: Double?
        public var facts: [Fact] = []
        public var webPage: URL?
        public var whatsNew: URL?
        public var canRemove = false
        /// Its folders, for the name's tooltip.
        public var tooltip: String?
    }

    /// The page of an installed add-on, or of one search or Popular offers.
    /// `latest`: what its source has for this game, when asked; `details`:
    /// what the source says about it; `entry`: the index's entry.
    public static func detail(installed: InstalledAddOn?, result: AddOnSearchResult?, entry: AddOnIndex.Entry?,
                              latest: Result<AddOnRelease, AddOnSourceError>?, details: AddOnDetails?,
                              in state: AddOnsModel.State) -> Detail? {
        let row: Row
        if let installed { row = Self.row(for: installed, in: state) }
        else if let result { row = Self.row(for: result, in: state) }
        else { return nil }
        let ref = installed?.ref ?? result?.ref
        var page = Detail(name: row.name)
        let author = installed?.author ?? result?.author ?? entry?.author
        page.byline = [author.map { "by \($0)" }, ref.map { "from \($0.source.displayName)" }].compactMap { $0 }.joined(separator: " · ")
        if page.byline?.isEmpty == true { page.byline = nil }
        page.summary = entry?.summary ?? details?.summary ?? installed?.notes ?? result?.summary
        page.action = row.action
        page.actionTitle = row.actionTitle
        page.progress = row.progress
        page.webPage = details?.website ?? ref?.webPage
        // CurseForge's own page, from the project ID in its TOC.
        if page.webPage == nil, case .curseForge(let id)? = installed?.unmanaged, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) {
            page.webPage = URL(string: "https://www.curseforge.com/projects/\(id)")
        }
        page.tooltip = installed.map(tooltip)
        page.canRemove = installed?.isManaged == true && state.activity[installed!.id] == nil

        func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
        if let installed {
            if row.isFailure { (page.status, page.isFailure) = (row.detail, true) }
            else { page.status = reason(for: installed, in: state) }
            if let version = installed.version { page.facts.append(.init(title: "Installed", value: version)) }
            switch state.updates[installed.id] {
            case .available(let release):
                page.facts.append(.init(title: "Newest", value: release.version))
                if let date = release.date { page.facts.append(.init(title: "Released", value: day(date))) }
                page.whatsNew = GitHubAddOnSource.releasePage(release) ?? page.webPage
            case .current(let release) where placement(of: installed, in: state) != .others:
                if let date = release.date { page.facts.append(.init(title: "Released", value: day(date))) }
            default: break
            }
        } else {
            switch latest {
            case .success(let release)?:
                page.facts.append(.init(title: "Version", value: release.version))
                if let date = release.date { page.facts.append(.init(title: "Released", value: day(date))) }
            case .failure(.notForThisVersion)?:
                page.status = "There’s no version of it for this game yet."
                (page.action, page.actionTitle) = (nil, nil)
            case .failure(.noRelease)?:
                page.status = "It has no download right now."
                (page.action, page.actionTitle) = (nil, nil)
            case .failure(.unavailable)?:
                page.status = "\(ref?.source.displayName ?? "Its source") didn’t answer. Try again later."
            case nil: break
            }
            if row.isFailure { (page.status, page.isFailure) = (row.detail, true) }
        }
        if let monthly = details?.popularity, ref?.source == .wowInterface {
            page.facts.append(.init(title: "Downloads", value: monthly))
        }
        return page
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
