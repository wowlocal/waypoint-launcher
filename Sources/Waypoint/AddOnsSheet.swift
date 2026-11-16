import AppKit
import WaypointCore

/// One WoW version's add-ons, laid out like System Settings: section titles
/// over rounded groups, in a table (so the keyboard, VoiceOver and long
/// lists work as anywhere on the Mac). What needs an update, what's kept up
/// to date, what Waypoint can't update (one row to its own page), and
/// popular add-ons to add; each add-on has a page. What it says comes from
/// `AddOnListing`, which says only what's known.
@MainActor
final class AddOnsSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Page: Equatable { case list, others, detail(String) }

    /// A table row: a section title, a row of a group (with where it sits
    /// in it), the row to the others' page, or a line of text.
    private enum Line: Equatable {
        case header(String)
        case row(AddOnListing.Row, GroupPosition)
        case others(Int, GroupPosition)
        case note(String)
        case gap

        var key: String {
            switch self {
            case .header(let title): "h:\(title)"
            case .row(let row, let position): "r:\(row.id):\(position)"
            case .others(let count, _): "o:\(count)"
            case .note(let text): "n:\(text)"
            case .gap: "gap"
            }
        }
    }

    private let game: Game
    private let model: AppModel
    private var addOns: AddOnsModel { model.addOns }

    private var page: Page = .list
    /// The list a detail page was opened from: shown again, as it was, on Back.
    private var origin: Page = .list
    /// The list under the page now.
    private var listPage: Page { if case .detail = page { origin } else { page } }
    private var lines: [Line] = []
    private var searchText = ""
    private var results: [AddOnSearchResult] = []
    private var elsewhere: [String] = []
    private var searchFailure: String?
    private var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var detailTask: Task<Void, Never>?
    private var details: [String: AddOnDetails?] = [:]
    private var latest: [String: Result<AddOnRelease, AddOnSourceError>] = [:]
    private var entries: [String: AddOnIndex.Entry] = [:]
    private let initialDetail: String?
    private let initialOthers: Bool

    private let titleLabel = NSTextField.label(.title2)
    private let searchField = NSSearchField()
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let pageTitle = NSTextField.label(.title2)
    private let titleRow = NSStackView()
    private let navRow = NSStackView()
    private let table = AddOnTable()
    private let scroll = NSScrollView()
    private let detailView = AddOnDetailView()
    private let note = NSTextField(wrappingLabelWithString: " ")
    private let updateAllButton = NSButton(title: "Update All", target: nil, action: nil)
    private let finderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(game: Game, model: AppModel, search: String = "", othersExpanded: Bool = false, detail: String? = nil) {
        self.game = game
        self.model = model
        initialOthers = othersExpanded
        initialDetail = detail
        super.init(nibName: nil, bundle: nil)
        searchField.stringValue = search
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        for label in [titleLabel, pageTitle] { label.font = .boldSystemFont(ofSize: label.font?.pointSize ?? 17) }
        titleLabel.stringValue = "\(game.displayName) Add-Ons"
        searchField.placeholderString = "Search Add-Ons"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        titleRow.setViews([titleLabel, searchField], in: .leading)
        titleRow.distribution = .fill

        backButton.image = .symbol("chevron.left", pointSize: 15)
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.setAccessibilityLabel("Back")
        backButton.toolTip = "Back (⌘[)"
        navRow.setViews([backButton, pageTitle], in: .leading)
        navRow.spacing = 8
        navRow.isHidden = true
        let header = NSStackView.column([titleRow, navRow], spacing: 0)

        let column = NSTableColumn(identifier: .init("addOn"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.floatsGroupRows = false
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.open = { [weak self] in self?.openSelected() }
        table.setAccessibilityLabel("Add-ons")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        detailView.isHidden = true
        detailView.perform = { [weak self] action in self?.perform(action) }

        let content = NSView()
        for view in [scroll, detailView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        content.heightAnchor.constraint(equalToConstant: 440).isActive = true

        note.textColor = .secondaryLabelColor
        note.font = .preferredFont(forTextStyle: .callout)

        finderButton.target = self
        finderButton.action = #selector(showInFinder)
        updateAllButton.target = self
        updateAllButton.action = #selector(updateAll)
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([finderButton], in: .leading)
        buttons.setViews([updateAllButton, doneButton], in: .trailing)
        let line = NSBox.separator()

        let stack = NSStackView.column([header, content, line, note, buttons], spacing: 12)
        stack.setCustomSpacing(0, after: content)
        stack.setCustomSpacing(10, after: line)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 580),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            titleRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            navRow.heightAnchor.constraint(equalTo: titleRow.heightAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        Task { [weak self] in
            await addOns.refresh(game)
            guard let self else { return }
            if self.initialOthers { self.show(.others) }
            // By id or name (the screenshot hook passes a name).
            if let wanted = self.initialDetail {
                let state = self.state
                let id = state.addOns.first { $0.id == wanted || $0.name == wanted }?.id
                    ?? state.suggestions.first { $0.id == wanted || $0.name == wanted }?.id
                if let id { self.show(.detail(id)) }
            }
        }
        view.window?.makeFirstResponder(table)
        // ⌘F: search. ⌘[: back.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "f":
                self.show(.list)
                self.view.window?.makeFirstResponder(self.searchField)
                return nil
            case "[":
                guard self.page != .list else { return event }
                self.goBack()
                return nil
            default: return event
            }
        }
        if !searchField.stringValue.isEmpty { searchChanged() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        searchTask?.cancel()
        detailTask?.cancel()
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
        let items = AddOnListing.items(state, othersExpanded: listPage == .others, search: listPage == .list ? searchText : "",
                                       results: results, isSearching: isSearching, searchFailure: searchFailure,
                                       flavorKnown: flavorKnown, elsewhere: elsewhere)
        let newLines = Self.lines(items)
        if newLines.map(\.key) == lines.map(\.key) {
            lines = newLines
            for (index, line) in lines.enumerated() {
                if case .row(let row, _) = line { (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? AddOnCellView)?.show(row) }
            }
        } else {
            let selected = table.selectedRow >= 0 && table.selectedRow < lines.count ? lines[table.selectedRow].key : nil
            lines = newLines
            table.reloadData()
            if let selected, let index = lines.firstIndex(where: { $0.key == selected }) {
                table.selectRowIndexes([index], byExtendingSelection: false)
            }
        }
        if case .detail = page { renderDetail() }
        updateAllButton.isHidden = state.available.count < 2 || !searchText.isEmpty || page != .list
        // On a page, Return is its own button, not Done.
        doneButton.keyEquivalent = page == .list || page == .others ? "\r" : ""
        updateAllButton.isEnabled = state.activity.isEmpty
        finderButton.isHidden = page != .list
        // The line stays even when empty, so the buttons never move.
        let footer = AddOnListing.footer(state, gameName: game.displayName, flavorKnown: flavorKnown,
                                         isRunning: model.isRunning(game), isSearching: !searchText.isEmpty || page != .list)
        note.stringValue = footer ?? " "
    }

    /// The listing's items as table lines, each group row knowing whether
    /// it starts or ends its group.
    private static func lines(_ items: [AddOnListing.Item]) -> [Line] {
        var lines: [Line] = []
        var group: [Line] = []
        func flush() {
            for (index, line) in group.enumerated() {
                let position: GroupPosition = group.count == 1 ? .only : index == 0 ? .first : index == group.count - 1 ? .last : .middle
                switch line {
                case .row(let row, _): lines.append(.row(row, position))
                case .others(let count, _): lines.append(.others(count, position))
                default: lines.append(line)
                }
            }
            group = []
        }
        for item in items {
            switch item {
            case .header(let title): flush(); lines.append(.header(title))
            case .note(let text): flush(); lines.append(.note(text))
            case .row(let row): group.append(.row(row, .only))
            case .others(let count, _):
                flush()
                if !lines.isEmpty { lines.append(.gap) }
                group.append(.others(count, .only))
                flush()
            }
        }
        flush()
        return lines
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row] {
        case .header: return 34
        case .row: return 48
        case .others: return 40
        case .gap: return 16
        case .note(let text):
            let bounds = (text as NSString).boundingRect(with: NSSize(width: 520, height: 1000), options: .usesLineFragmentOrigin,
                                                          attributes: [.font: NSFont.preferredFont(forTextStyle: .body)])
            return ceil(bounds.height) + 24
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch lines[row] {
        case .row, .others: true
        default: false
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = AddOnGroupRowView()
        switch lines[row] {
        case .row(_, let position), .others(_, let position): view.position = position
        default: view.position = nil
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let title):
            let view = tableView.makeView(withIdentifier: AddOnTextCell.header, owner: self) as? AddOnTextCell ?? AddOnTextCell(.header)
            view.show(title)
            return view
        case .note(let text):
            let view = tableView.makeView(withIdentifier: AddOnTextCell.note, owner: self) as? AddOnTextCell ?? AddOnTextCell(.note)
            view.show(text)
            return view
        case .gap:
            return NSView()
        case .others(let count, _):
            let view = tableView.makeView(withIdentifier: AddOnTextCell.others, owner: self) as? AddOnTextCell ?? AddOnTextCell(.others)
            view.show(count == 1 ? "1 Other Add-On" : "\(count) Other Add-Ons")
            return view
        case .row(let row, _):
            let view = tableView.makeView(withIdentifier: AddOnCellView.id, owner: self) as? AddOnCellView ?? AddOnCellView()
            view.act = { [weak self] current in self?.perform(current.action, id: current.id) }
            view.open = { [weak self] current in self?.show(.detail(current.id)) }
            view.show(row)
            return view
        }
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < lines.count else { return }
        open(lines[row])
    }

    private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < lines.count else { return }
        open(lines[row])
    }

    private func open(_ line: Line) {
        switch line {
        case .row(let row, _): show(.detail(row.id))
        case .others: show(.others)
        default: break
        }
    }

    // MARK: Pages

    private func show(_ next: Page) {
        let previousList = listPage
        if case .detail = next {
            if case .detail = page {} else { origin = page }
        }
        page = next
        detailTask?.cancel()
        let isDetail = { if case .detail = next { true } else { false } }()
        scroll.isHidden = isDetail
        detailView.isHidden = !isDetail
        titleRow.isHidden = next != .list
        navRow.isHidden = next == .list
        switch next {
        case .list: pageTitle.stringValue = ""
        case .others: pageTitle.stringValue = "Other Add-Ons"
        case .detail(let id): pageTitle.stringValue = name(for: id) ?? ""
        }
        render()
        // A different list starts at its top; back to the same one, it's where it was.
        if listPage != previousList { table.scrollRowToVisible(0) }
        switch next {
        case .list, .others:
            view.window?.makeFirstResponder(table)
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        case .detail(let id):
            view.window?.makeFirstResponder(detailView.firstControl ?? backButton)
            NSAccessibility.post(element: detailView, notification: .layoutChanged)
            load(id)
        }
    }

    @objc private func goBack() {
        switch page {
        case .list: break
        case .others: show(.list)
        case .detail:
            show(origin)
        }
    }

    private func name(for id: String) -> String? {
        state.addOns.first { $0.id == id }?.name ?? (results + state.suggestions).first { $0.id == id }?.name
    }

    /// What the page needs from the network: the source's own words, and
    /// for an add-on not installed, its newest version for this game.
    private func load(_ id: String) {
        let state = state
        let installed = state.addOns.first { $0.id == id }
        guard let ref = installed?.ref ?? (results + state.suggestions).first(where: { $0.id == id })?.ref else { return }
        let (game, addOns) = (game, addOns)
        detailTask = Task { [weak self] in
            if self?.entries[id] == nil, let entry = await addOns.indexEntry(game, ref) { self?.entries[id] = entry }
            self?.renderDetail()
            if installed == nil, self?.latest[id] == nil {
                let latest = await addOns.latest(game, ref)
                guard !Task.isCancelled else { return }
                self?.latest[id] = latest
                self?.renderDetail()
            }
            if self?.details[id] == nil {
                let found = await addOns.details(game, ref)
                guard !Task.isCancelled else { return }
                self?.details[id] = .some(found)
                self?.renderDetail()
            }
        }
    }

    private func renderDetail() {
        guard case .detail(let id) = page else { return }
        let state = state
        let installed = state.addOns.first { $0.id == id }
        let result = (results + state.suggestions).first { $0.id == id }
        guard let content = AddOnListing.detail(installed: installed, result: result, entry: entries[id], latest: latest[id],
                                                details: details[id] ?? nil, in: state) else { show(.list); return }
        let loading = (installed?.ref ?? result?.ref) != nil && (details[id] == nil || (installed == nil && latest[id] == nil))
        detailView.show(content, isLoading: loading, isRunning: model.isRunning(game), isManaged: installed?.isManaged == true,
                        folder: installed.flatMap { game.addOnsLocation?.appendingPathComponent($0.folders[0]) })
    }

    // MARK: Actions

    private func perform(_ action: AddOnListing.Action?, id: String) {
        switch action {
        case .update(let evenIfChanged)?:
            guard let addOn = state.addOns.first(where: { $0.id == id }) else { return }
            addOns.update(game, addOn, evenIfChanged: evenIfChanged)
        case .install?:
            guard let result = (results + state.suggestions).first(where: { $0.id == id }) else { return }
            addOns.install(game, result)
        case nil:
            show(.detail(id))
        }
    }

    private func perform(_ action: AddOnDetailView.Action) {
        guard case .detail(let id) = page else { return }
        switch action {
        case .primary(let action): perform(action, id: id)
        case .remove:
            guard let addOn = state.addOns.first(where: { $0.id == id }) else { return }
            addOns.remove(game, addOn)
            show(.list)
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// Esc: back from a page, else close.
    override func cancelOperation(_ sender: Any?) {
        if page != .list { goBack() } else { dismiss(nil) }
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

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        searchChanged()
    }

    /// Return in the search field searches; it doesn't close the sheet.
    /// Down moves into the results.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { searchChanged(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) {
            view.window?.makeFirstResponder(table)
            if let first = lines.firstIndex(where: { if case .row = $0 { true } else { false } }) {
                table.selectRowIndexes([first], byExtendingSelection: false)
            }
            return true
        }
        return false
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
        if text.isEmpty { (results, elsewhere) = ([], []) }
        render()
        table.scrollRowToVisible(0)
        guard !text.isEmpty else { return }
        let (game, addOns) = (game, addOns)
        searchTask = Task { [weak self] in
            let index = await addOns.searchIndex(game, text)
            let notHere = await addOns.elsewhere(game, text)
            guard !Task.isCancelled, let self else { return }
            self.results = index + self.results.filter { $0.ref.source == .wowInterface && $0.name.lowercased().contains(text.lowercased()) }
            self.elsewhere = notHere
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
}

/// Where a row sits in its rounded group.
enum GroupPosition: Equatable { case first, middle, last, only }

/// The list: Return, Space or → opens the selected row.
private final class AddOnTable: NSTableView {
    var open: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49, 124: // Return, Enter, Space, →
            guard selectedRow >= 0 else { fallthrough }
            open?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Return opens a row before the sheet's Done button sees it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, selectedRow >= 0, [36, 76].contains(event.keyCode),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            open?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Draws a group like System Settings': a rounded panel the rows share,
/// with hairlines between them, and the selection inside it.
private final class AddOnGroupRowView: NSTableRowView {
    var position: GroupPosition?

    private func panel() -> NSBezierPath? {
        guard let position else { return nil }
        let radius: CGFloat = 10
        let rect = bounds
        let path = NSBezierPath()
        let top = position == .first || position == .only, bottom = position == .last || position == .only
        // The view is flipped: minY is the top.
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        if top {
            path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
            path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        if bottom {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
            path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.close()
        return path
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let panel = panel() else { return }
        NSColor.quaternarySystemFill.setFill()
        panel.fill()
        if position == .first || position == .middle {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.minX + 12, y: bounds.maxY - 1, width: bounds.width - 12, height: 1).fill()
        }
    }

    /// Labels keep their colors on the light selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let panel = panel() else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor)
            .withAlphaComponent(isEmphasized ? 0.35 : 1).setFill()
        panel.fill()
    }
}

/// A section title, a line of text, or the row to the others' page.
private final class AddOnTextCell: NSTableCellView {
    enum Kind { case header, note, others }
    static let header = NSUserInterfaceItemIdentifier("header")
    static let note = NSUserInterfaceItemIdentifier("note")
    static let others = NSUserInterfaceItemIdentifier("others")
    private let label: NSTextField
    private let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        label = kind == .note ? NSTextField(wrappingLabelWithString: "") : NSTextField.label(.body)
        super.init(frame: .zero)
        switch kind {
        case .header:
            identifier = Self.header
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        case .note:
            identifier = Self.note
            label.textColor = .secondaryLabelColor
            label.alignment = .center
        case .others:
            identifier = Self.others
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: kind == .others ? 12 : 4),
                           label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30)]
        switch kind {
        case .header: constraints.append(label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6))
        case .note:
            constraints += [label.centerYAnchor.constraint(equalTo: centerYAnchor),
                            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)]
        case .others:
            constraints.append(label.centerYAnchor.constraint(equalTo: centerYAnchor))
            let chevron = NSImageView(image: .symbol("chevron.right", pointSize: 11) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.setAccessibilityElement(false)
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)
            constraints += [chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String) {
        label.stringValue = text
        // A short line centered in the empty list; a paragraph reads from the left.
        if kind == .note { label.alignment = text.count > 80 ? .natural : .center }
        if kind == .others { setAccessibilityHelp(AddOnListing.othersHelp) }
    }
}

/// An add-on: name and one quiet line; on the right its button (or a
/// progress bar) and a chevron to its page.
private final class AddOnCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("row")
    var act: ((AddOnListing.Row) -> Void)?
    private let name = NSTextField.label(.body)
    private let detail = NSTextField.label(.subheadline, color: .secondaryLabelColor)
    private let button = NSButton(title: "", target: nil, action: nil)
    private let bar = NSProgressIndicator.bar()
    private var row: AddOnListing.Row?

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(press)
        let chevron = NSImageView(image: .symbol("chevron.right", pointSize: 11) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setAccessibilityElement(false)
        let text = NSStackView.column([name, detail], spacing: 2)
        let trailing = NSView()
        for view in [button, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailing.addSubview(view)
        }
        for view in [text, trailing, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 90),
            trailing.heightAnchor.constraint(equalToConstant: 24),
            button.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: AddOnListing.Row) {
        guard row != self.row else { return }
        self.row = row
        name.stringValue = row.name
        detail.stringValue = row.detail
        detail.textColor = row.isFailure ? .systemRed : .secondaryLabelColor
        detail.isHidden = row.detail.isEmpty
        button.title = row.actionTitle ?? ""
        button.isHidden = row.actionTitle == nil
        button.setAccessibilityLabel(row.actionTitle.map { "\($0) \(row.name)" })
        bar.isHidden = row.progress == nil
        bar.doubleValue = row.progress ?? 0
        bar.setAccessibilityLabel("Downloading \(row.name)")
        toolTip = row.tooltip
        setAccessibilityLabel([row.name, row.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    var open: ((AddOnListing.Row) -> Void)?

    /// The row as it is now, not as it was when the cell was made.
    @objc private func press() { if let row { act?(row) } }
    override func accessibilityPerformPress() -> Bool {
        guard let row else { return false }
        open?(row)
        return true
    }
}

/// An add-on's page: what it does, who makes it, where it comes from,
/// what's installed and newest, and what can be done with it.
private final class AddOnDetailView: NSView {
    enum Action { case primary(AddOnListing.Action?), remove, open(URL), reveal(URL) }

    var perform: ((Action) -> Void)?
    /// The first control, to take the focus when the page opens.
    var firstControl: NSView? { primary.isHidden ? (webButton.isHidden ? nil : webButton) : primary }

    private let byline = NSTextField.label(.body, color: .secondaryLabelColor)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let bar = NSProgressIndicator.bar()
    private let webButton = NSButton(title: "Open Web Page", target: nil, action: nil)
    private let newsButton = NSButton(title: "What’s New", target: nil, action: nil)
    private let finderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let trashButton = NSButton(title: "Move to Trash…", target: nil, action: nil)
    private let spinner = NSProgressIndicator.spinner()
    private let facts = NSStackView()
    private var content: AddOnListing.Detail?
    private var folder: URL?

    init() {
        super.init(frame: .zero)
        for (button, action) in [(primary, #selector(pressPrimary)), (webButton, #selector(openWeb)), (newsButton, #selector(openNews)),
                                 (finderButton, #selector(reveal)), (trashButton, #selector(trash))] {
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        primary.bezelColor = .controlAccentColor
        primary.contentTintColor = .white
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        spinner.setAccessibilityLabel("Loading")
        let actions = NSStackView(views: [primary, bar, newsButton, webButton, finderButton])
        actions.spacing = 8
        summary.isSelectable = true
        summary.font = .preferredFont(forTextStyle: .body)
        facts.orientation = .vertical
        facts.alignment = .leading
        facts.spacing = 6
        let stack = NSStackView.column([byline, summary, status, actions, spinner, facts], spacing: 14)
        stack.setCustomSpacing(8, after: byline)
        let bottom = NSStackView(views: [trashButton])
        for view in [stack, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bottom.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ content: AddOnListing.Detail, isLoading: Bool, isRunning: Bool, isManaged: Bool, folder: URL?) {
        self.content = content
        self.folder = folder
        byline.stringValue = content.byline ?? ""
        byline.isHidden = content.byline == nil
        byline.toolTip = content.tooltip
        summary.stringValue = content.summary ?? ""
        summary.isHidden = content.summary == nil
        status.stringValue = content.status ?? ""
        status.textColor = content.isFailure ? .systemRed : .secondaryLabelColor
        status.isHidden = content.status == nil
        primary.title = content.actionTitle ?? ""
        primary.isHidden = content.actionTitle == nil
        primary.keyEquivalent = content.actionTitle == nil ? "" : "\r"
        bar.isHidden = content.progress == nil
        bar.doubleValue = content.progress ?? 0
        newsButton.isHidden = content.whatsNew == nil
        webButton.isHidden = content.webPage == nil
        finderButton.isHidden = folder == nil
        // Only for add-ons Waypoint manages; disabled, not gone, while busy.
        trashButton.isHidden = folder == nil || !isManaged
        trashButton.isEnabled = content.canRemove && !isRunning
        trashButton.toolTip = isRunning ? "Quit the game to move this add-on to the Trash." : nil

        spinner.isHidden = !isLoading
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        for view in facts.arrangedSubviews { view.removeFromSuperview() }
        for fact in content.facts {
            let label = NSTextField(labelWithString: fact.title)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let value = NSTextField(wrappingLabelWithString: fact.value)
            value.isSelectable = true
            let line = NSStackView(views: [label, value])
            line.alignment = .firstBaseline
            line.spacing = 12
            facts.addArrangedSubview(line)
        }
        facts.isHidden = content.facts.isEmpty
    }

    @objc private func pressPrimary() { perform?(.primary(content?.action)) }
    @objc private func openWeb() { if let url = content?.webPage { perform?(.open(url)) } }
    @objc private func openNews() { if let url = content?.whatsNew { perform?(.open(url)) } }
    @objc private func reveal() { if let folder { perform?(.reveal(folder)) } }

    /// Asks first: everything else on this page can be undone by doing it
    /// again, this can't from here.
    @objc private func trash() {
        guard let window, let name = content?.name else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(name) to the Trash?"
        alert.informativeText = "Its settings stay, so it’s as it was if you install it again."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.perform?(.remove) }
        }
    }
}
