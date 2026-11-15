import AppKit
import WaypointCore

/// One WoW version's add-ons: what needs an update, what's current, what
/// Waypoint can't update; and search to add more. Opened from the game's
/// ••• menu. Updates also happen on their own (`AddOnsModel`); this is
/// where to see them, or do one now.
@MainActor
final class AddOnsSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private let game: Game
    private let model: AppModel
    private var addOns: AddOnsModel { model.addOns }

    private enum Item: Equatable {
        case header(String, help: Bool)
        case addOn(InstalledAddOn)
        case result(AddOnSearchResult)
        case note(String)

        var key: String {
            switch self {
            case .header(let title, _): "h:\(title)"
            case .addOn(let addOn): "a:\(addOn.id)"
            case .result(let result): "r:\(result.id)"
            case .note(let text): "n:\(text)"
            }
        }
    }

    private var items: [Item] = []
    private var searchText = ""
    private var results: [AddOnSearchResult] = []
    private var searchFailure: String?
    private var isSearching = false
    private var searchTask: Task<Void, Never>?

    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let updateAllButton = NSButton(title: "Update All", target: nil, action: nil)

    init(game: Game, model: AppModel) {
        self.game = game
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "\(game.displayName) Add-Ons"
        searchField.placeholderString = "Search Add-Ons"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let top = NSStackView(views: [title, searchField])
        top.distribution = .fill

        let column = NSTableColumn(identifier: .init("addOn"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true

        note.textColor = .secondaryLabelColor
        note.font = .preferredFont(forTextStyle: .callout)

        let finder = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder))
        updateAllButton.target = self
        updateAllButton.action = #selector(updateAll)
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([finder], in: .leading)
        buttons.setViews([updateAllButton, doneButton], in: .trailing)

        let stack = NSStackView.column([top, scroll, note, buttons], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 560),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = stack
        observeChanges { [weak self] in self?.render() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        addOns.shown.insert(game.id)
        let (game, addOns) = (game, addOns)
        Task { await addOns.refresh(game) }
        view.window?.makeFirstResponder(table)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        searchTask?.cancel()
        addOns.shown.remove(game.id)
        addOns.forget(game)
    }

    // MARK: Rendering

    private var state: AddOnsModel.State { addOns.state(for: game) }

    private func render() {
        let state = state
        let running = model.isRunning(game)
        var newItems: [Item] = []
        let lower = searchText.lowercased()
        let shown = lower.isEmpty ? state.addOns : state.addOns.filter {
            $0.name.lowercased().contains(lower) || $0.folders.contains { $0.lowercased().contains(lower) }
        }
        if !lower.isEmpty {
            if !shown.isEmpty { newItems.append(.header("Installed", help: false)) }
            newItems += shown.map(Item.addOn)
            let installed = Set(state.addOns.compactMap(\.ref))
            let available = results.filter { !installed.contains($0.ref) }
            newItems.append(.header("Available", help: false))
            if let searchFailure { newItems.append(.note(searchFailure)) }
            else if isSearching && available.isEmpty { newItems.append(.note("Searching…")) }
            else if available.isEmpty { newItems.append(.note("No add-ons found.")) }
            newItems += available.map(Item.result)
        } else if shown.isEmpty {
            newItems.append(.note(state.isScanning ? "" : "No add-ons yet. Search to add one."))
        } else {
            let updates = shown.filter { state.update(for: $0) != nil || state.activity[$0.id] != nil }
            let current = shown.filter { $0.isManaged && !updates.contains($0) }
            let others = shown.filter { !$0.isManaged }
            if !updates.isEmpty { newItems.append(.header("Updates", help: false)); newItems += updates.map(Item.addOn) }
            if !current.isEmpty { newItems.append(.header("Up to Date", help: false)); newItems += current.map(Item.addOn) }
            if !others.isEmpty { newItems.append(.header("Not Updated by Waypoint", help: true)); newItems += others.map(Item.addOn) }
        }

        let sameRows = newItems.map(\.key) == items.map(\.key)
        items = newItems
        if sameRows {
            for row in 0..<items.count {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? AddOnRowView)?.show(content(of: items[row]))
            }
        } else {
            table.reloadData()
        }

        updateAllButton.isHidden = state.available.count < 2 || !lower.isEmpty
        updateAllButton.isEnabled = state.activity.isEmpty
        if WoWFlavor.of(game.install) == nil {
            note.stringValue = AddOnError.unknownGame.errorDescription!
        } else if let failure = state.scanFailure {
            note.stringValue = failure
        } else if running {
            note.stringValue = "\(game.displayName) is open. Type /reload in the game to load updated add-ons."
        } else if state.isChecking {
            note.stringValue = "Checking for updates…"
        } else {
            note.stringValue = ""
        }
        note.isHidden = note.stringValue.isEmpty
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 28 }
        return 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title, let help):
            let id = NSUserInterfaceItemIdentifier("header")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? AddOnHeaderView ?? AddOnHeaderView(identifier: id)
            view.show(title, help: help ? Self.notUpdatedHelp : nil)
            return view
        case .note(let text):
            let id = NSUserInterfaceItemIdentifier("note")
            let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
                let label = NSTextField.label(.body, color: .secondaryLabelColor)
                label.identifier = id
                return label
            }()
            label.stringValue = text
            return label
        case .addOn, .result:
            let id = NSUserInterfaceItemIdentifier("row")
            let view = tableView.makeView(withIdentifier: id, owner: self) as? AddOnRowView ?? AddOnRowView(identifier: id)
            view.show(content(of: items[row]))
            return view
        }
    }

    static let notUpdatedHelp = "Waypoint updates add-ons published on GitHub, WoWInterface and Tukui. These come from somewhere else, such as CurseForge, which doesn’t let other apps download from it. Keep updating them where you got them."

    // MARK: Rows

    /// What a row shows.
    struct Row {
        var name: String
        var detail: String
        var isFailure: Bool
        var tooltip: String?
        var button: String?
        var progress: Double?
        var action: (() -> Void)?
    }

    private static let changedMessage = AddOnError.changedLocally.errorDescription!

    private func content(of item: Item) -> Row {
        let state = state
        switch item {
        case .addOn(let addOn):
            var row = Row(name: addOn.name, detail: addOn.version ?? "", isFailure: false, tooltip: tooltip(addOn))
            switch addOn.unmanaged {
            case .notForThisVersion: row.detail = "Not for this version of the game"
            case .link, .developmentCopy: row.detail = "Added by hand"
            default: break
            }
            if let release = state.update(for: addOn) {
                row.detail = "\(addOn.version ?? "") → \(release.version)"
                let changed = state.failures[addOn.id] == Self.changedMessage
                row.button = changed ? "Replace" : "Update"
                row.action = { [weak self] in self?.update(addOn, evenIfChanged: changed) }
            }
            if let failure = state.failures[addOn.id] { row.detail = failure; row.isFailure = true }
            if case .downloading(let fraction) = state.activity[addOn.id] { row.progress = fraction; row.button = nil }
            if state.activity[addOn.id] == .removing { row.detail = "Moving to the Trash…"; row.button = nil }
            return row
        case .result(let result):
            var row = Row(name: result.name, detail: result.author.map { "by \($0)" } ?? "", isFailure: false,
                          tooltip: "From \(result.ref.source.displayName)", button: "Install")
            row.action = { [weak self] in self?.install(result) }
            if let failure = state.failures[result.id] { row.detail = failure; row.isFailure = true }
            if case .downloading(let fraction) = state.activity[result.id] { row.progress = fraction; row.button = nil }
            return row
        case .header, .note:
            return Row(name: "", detail: "", isFailure: false)
        }
    }

    private func tooltip(_ addOn: InstalledAddOn) -> String {
        let folders = addOn.folders.count > 1 ? "Folders: \(addOn.folders.joined(separator: ", "))" : "Folder: \(addOn.folders[0])"
        guard let ref = addOn.ref else { return folders }
        return "From \(ref.source.displayName)\n\(folders)"
    }

    // MARK: Actions

    private func update(_ addOn: InstalledAddOn, evenIfChanged: Bool) {
        addOns.update(game, addOn, evenIfChanged: evenIfChanged)
    }

    private func install(_ result: AddOnSearchResult) {
        addOns.install(game, result)
    }

    @objc private func updateAll() {
        addOns.updateAll(game)
    }

    /// The AddOns folder, or the game until it has one.
    @objc private func showInFinder() {
        guard let folder = game.addOnsLocation else { return }
        if !NSWorkspace.shared.open(folder) {
            NSWorkspace.shared.activateFileViewerSelecting([game.finderItem])
        }
    }

    @objc private func done() {
        dismiss(nil)
    }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        searchChanged()
    }

    private func searchChanged() {
        searchTask?.cancel()
        searchText = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        results = []
        searchFailure = nil
        isSearching = !searchText.isEmpty
        render()
        guard !searchText.isEmpty else { return }
        let (game, addOns, text) = (game, addOns, searchText)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found: [AddOnSearchResult]
            var failure: String?
            do { found = try await addOns.search(game, text) } catch { found = []; failure = errorMessage(error) }
            guard !Task.isCancelled, let self else { return }
            self.results = found
            self.searchFailure = failure
            self.isSearching = false
            self.render()
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < items.count, case .addOn(let addOn) = items[row] else { return }
        let state = state
        let idle = state.activity[addOn.id] == nil
        if state.update(for: addOn) != nil {
            menu.addItem(ActionItem("Update", enabled: idle) { [weak self] in
                self?.update(addOn, evenIfChanged: state.failures[addOn.id] == Self.changedMessage)
            })
        }
        if addOn.isManaged {
            let (game, addOns) = (game, addOns)
            menu.addItem(ActionItem("Move to Trash", enabled: idle && !model.isRunning(game)) {
                addOns.remove(game, addOn)
            })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if let folder = game.addOnsLocation?.appendingPathComponent(addOn.folders[0]) {
            menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) })
        }
        if let page = addOn.ref?.webPage {
            menu.addItem(ActionItem("Open Web Page") { NSWorkspace.shared.open(page) })
        }
    }
}

private extension Array where Element == InstalledAddOn {
    func contains(_ addOn: InstalledAddOn) -> Bool { contains { $0.id == addOn.id } }
}

/// A section title, with a help button for "Not Updated by Waypoint".
private final class AddOnHeaderView: NSTableCellView {
    private let title = NSTextField.label(.headline, color: .secondaryLabelColor)
    private let help = NSButton(title: "", target: nil, action: nil)
    private var helpText: String?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        help.bezelStyle = .helpButton
        help.controlSize = .small
        help.target = self
        help.action = #selector(showHelp)
        help.setAccessibilityLabel("Why these aren’t updated")
        let stack = NSStackView(views: [title, help])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, help helpText: String?) {
        title.stringValue = text
        self.helpText = helpText
        help.isHidden = helpText == nil
    }

    @objc private func showHelp() {
        guard let helpText else { return }
        let label = NSTextField(wrappingLabelWithString: helpText)
        label.preferredMaxLayoutWidth = 280
        let content = NSViewController()
        let container = NSStackView(views: [label])
        container.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: help.bounds, of: help, preferredEdge: .maxY)
    }
}

/// An add-on: name, one quiet line, and at most one button or a progress bar.
private final class AddOnRowView: NSTableCellView {
    private let name = NSTextField.label(.body)
    private let detail = NSTextField.label(.callout, color: .secondaryLabelColor)
    private let button = NSButton(title: "", target: nil, action: nil)
    private let bar = NSProgressIndicator.bar()
    private var action: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(press)
        button.setContentHuggingPriority(.required, for: .horizontal)
        bar.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let text = NSStackView.column([name, detail], spacing: 1)
        let stack = NSStackView(views: [text, bar, button])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: AddOnsSheet.Row) {
        name.stringValue = row.name
        name.toolTip = row.tooltip
        detail.stringValue = row.detail
        detail.textColor = row.isFailure ? .systemRed : .secondaryLabelColor
        detail.toolTip = row.isFailure ? row.detail : nil
        detail.isHidden = row.detail.isEmpty
        button.title = row.button ?? ""
        button.isHidden = row.button == nil
        action = row.action
        bar.isHidden = row.progress == nil
        bar.doubleValue = row.progress ?? 0
        setAccessibilityLabel([row.name, row.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @objc private func press() { action?() }
}
