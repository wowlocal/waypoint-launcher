import AppKit
import WaypointCore

/// One WoW version's add-ons: what needs an update, what's kept up to date,
/// and one quiet row for what Waypoint can't update; search adds more.
/// Opened from the game's ••• menu. What it says comes from
/// `AddOnListing`, which says only what's known.
@MainActor
final class AddOnsSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private let game: Game
    private let model: AppModel
    private var addOns: AddOnsModel { model.addOns }

    private var items: [AddOnListing.Item] = []
    private var searchText = ""
    private var results: [AddOnSearchResult] = []
    private var searchFailure: String?
    private var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var othersExpanded = false
    private var keyMonitor: Any?

    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let updateAllButton = NSButton(title: "Update All", target: nil, action: nil)

    init(game: Game, model: AppModel, search: String = "", othersExpanded: Bool = false) {
        self.game = game
        self.model = model
        self.othersExpanded = othersExpanded
        super.init(nibName: nil, bundle: nil)
        searchField.stringValue = search
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
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.floatsGroupRows = false
        table.usesAutomaticRowHeights = false
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
        // ⌘F: search.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "f" else { return event }
            self.view.window?.makeFirstResponder(self.searchField)
            return nil
        }
        if !searchField.stringValue.isEmpty { searchChanged() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        searchTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        addOns.shown.remove(game.id)
        addOns.forget(game)
    }

    // MARK: Rendering

    private var state: AddOnsModel.State { addOns.state(for: game) }

    private func render() {
        let state = state
        let flavorKnown = WoWFlavor.of(game.install) != nil
        let newItems = AddOnListing.items(state, othersExpanded: othersExpanded, search: searchText, results: results,
                                          isSearching: isSearching, searchFailure: searchFailure, flavorKnown: flavorKnown)
        let sameRows = newItems.map(\.key) == items.map(\.key)
        items = newItems
        if sameRows {
            for row in 0..<items.count { configure(table.view(atColumn: 0, row: row, makeIfNecessary: false), with: items[row]) }
        } else {
            table.reloadData()
        }
        updateAllButton.isHidden = state.available.count < 2 || !searchText.isEmpty
        updateAllButton.isEnabled = state.activity.isEmpty
        // The line stays even when empty, so the buttons never move.
        note.stringValue = AddOnListing.footer(state, gameName: game.displayName, flavorKnown: flavorKnown,
                                               isRunning: model.isRunning(game), isSearching: !searchText.isEmpty) ?? " "
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header: 28
        case .note: 32
        case .others: 36
        case .row: 40
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let view: NSView
        switch item {
        case .header:
            view = tableView.makeView(withIdentifier: AddOnHeaderView.id, owner: self) ?? AddOnHeaderView()
        case .note:
            view = tableView.makeView(withIdentifier: AddOnNoteView.id, owner: self) ?? AddOnNoteView()
        case .others:
            view = tableView.makeView(withIdentifier: AddOnOthersView.id, owner: self) ?? AddOnOthersView()
        case .row:
            view = tableView.makeView(withIdentifier: AddOnRowView.id, owner: self) ?? AddOnRowView()
        }
        configure(view, with: item)
        return view
    }

    private func configure(_ view: NSView?, with item: AddOnListing.Item) {
        switch item {
        case .header(let title): (view as? AddOnHeaderView)?.show(title)
        case .note(let text): (view as? AddOnNoteView)?.show(text)
        case .others(let count, let open):
            (view as? AddOnOthersView)?.show(count: count, isExpanded: open) { [weak self] in
                self?.othersExpanded.toggle()
                self?.render()
            }
        case .row(let row):
            (view as? AddOnRowView)?.show(row) { [weak self] in self?.perform(row) }
        }
    }

    // MARK: Actions

    private func perform(_ row: AddOnListing.Row) {
        switch row.action {
        case .update(let evenIfChanged)?:
            guard let addOn = state.addOns.first(where: { $0.id == row.id }) else { return }
            addOns.update(game, addOn, evenIfChanged: evenIfChanged)
        case .install?:
            guard let result = results.first(where: { $0.id == row.id }) else { return }
            addOns.install(game, result)
        case nil: break
        }
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

    /// The sheet drawn into a PNG (for screenshots without the screen).
    func snapshot(to file: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // The sheet's own background isn't part of its view: paint it first.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    /// Return in the search field searches; it doesn't close the sheet.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        searchChanged()
        return true
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        searchChanged()
    }

    /// The index's matches at once; WoWInterface's after a pause in typing.
    /// What's shown stays until something newer replaces it: no blinking.
    private func searchChanged() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard text != searchText || searchTask == nil else { return }
        searchTask?.cancel()
        searchText = text
        searchFailure = nil
        isSearching = !text.isEmpty
        if text.isEmpty { results = [] }
        render()
        guard !text.isEmpty else { return }
        let (game, addOns) = (game, addOns)
        searchTask = Task { [weak self] in
            let index = await addOns.searchIndex(game, text)
            guard !Task.isCancelled, let self else { return }
            self.results = index + self.results.filter { $0.ref.source == .wowInterface && $0.name.lowercased().contains(text.lowercased()) }
            self.render()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var more: [AddOnSearchResult] = []
            var failure: String?
            do { more = try await addOns.searchWoWInterface(game, text) } catch {
                failure = index.isEmpty ? errorMessage(error) : nil
            }
            guard !Task.isCancelled else { return }
            self.results = index + more
            self.searchFailure = failure
            self.isSearching = false
            self.searchTask = nil
            self.render()
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = table.clickedRow
        guard index >= 0, index < items.count, case .row(let row) = items[index],
              let addOn = state.addOns.first(where: { $0.id == row.id }) else { return }
        let idle = state.activity[addOn.id] == nil
        if let action = row.action, let title = row.actionTitle {
            menu.addItem(ActionItem(title, enabled: idle) { [weak self] in
                guard case .update = action else { return }
                self?.perform(row)
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

/// A section title.
private final class AddOnHeaderView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("header")
    private let title = NSTextField.label(.headline, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String) {
        title.stringValue = text
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
}

/// A line of quiet text in the list.
private final class AddOnNoteView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("note")
    private let label = NSTextField.label(.body, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String) { label.stringValue = text }
}

/// "28 Other Add-Ons": opens the add-ons Waypoint doesn't update, with the
/// reason one click away.
private final class AddOnOthersView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("others")
    private let disclosure = NSButton(title: "", target: nil, action: nil)
    private let title = NSButton(title: "", target: nil, action: nil)
    private let help = NSButton(title: "", target: nil, action: nil)
    private var toggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.imagePosition = .imageLeading
        disclosure.target = self
        disclosure.action = #selector(pressed)
        title.target = self
        title.action = #selector(pressed)
        title.isBordered = false
        // VoiceOver: the disclosure is the control; the title repeats it.
        title.setAccessibilityElement(false)
        help.bezelStyle = .helpButton
        help.controlSize = .small
        help.target = self
        help.action = #selector(showHelp)
        help.setAccessibilityLabel("Why Waypoint doesn’t update these")
        let stack = NSStackView(views: [disclosure, title, help])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(count: Int, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.toggle = toggle
        disclosure.state = isExpanded ? .on : .off
        let text = count == 1 ? "1 Other Add-On" : "\(count) Other Add-Ons"
        title.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .headline), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        disclosure.setAccessibilityLabel(text)
        disclosure.setAccessibilityHelp(AddOnListing.othersHelp)
    }

    @objc private func pressed() { toggle?() }

    @objc private func showHelp() {
        let label = NSTextField(wrappingLabelWithString: AddOnListing.othersHelp)
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

/// An add-on: name and one quiet line on the left; on the right, in a
/// column of its own so rows line up, one button or a progress bar.
private final class AddOnRowView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("row")
    private let name = NSTextField.label(.body)
    private let detail = NSTextField.label(.callout, color: .secondaryLabelColor)
    private let button = NSButton(title: "", target: nil, action: nil)
    private let bar = NSProgressIndicator.bar()
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(press)
        let text = NSStackView.column([name, detail], spacing: 1)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = NSView()
        for view in [button, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailing.addSubview(view)
        }
        for view in [text, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 96),
            trailing.heightAnchor.constraint(equalToConstant: 24),
            button.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: AddOnListing.Row, action: @escaping () -> Void) {
        name.stringValue = row.name
        name.toolTip = row.tooltip
        detail.stringValue = row.detail
        detail.textColor = row.isFailure ? .systemRed : .secondaryLabelColor
        detail.toolTip = row.isFailure ? row.detail : nil
        detail.isHidden = row.detail.isEmpty
        button.title = row.actionTitle ?? ""
        button.isHidden = row.actionTitle == nil
        self.action = action
        bar.isHidden = row.progress == nil
        bar.doubleValue = row.progress ?? 0
        setAccessibilityLabel([row.name, row.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        button.setAccessibilityLabel(row.actionTitle.map { "\($0) \(row.name)" })
    }

    @objc private func press() { action?() }
}
