import AppKit
import WaypointCore

/// The library window: installed games with Play and Update, games being
/// installed, the Battle.net account games launch as (in the subtitle; a
/// toolbar menu switches it), a + toolbar menu to install more, and
/// Waypoint's own update status in a banner when it has something to say.
/// The list runs under the toolbar, as the system's own lists do.
@MainActor
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private enum Row {
        case game(GameRowState)
        case installable(InstallableRowState)
        case availableHeader(count: Int, expanded: Bool)
        /// `key`: the uid its install would have.
        case available(InstallableProduct, key: String, picture: URL?, icon: URL?)

        /// The same for a game while it is offered, being installed and
        /// installed, so its row moves from one place to the next rather
        /// than one row going and another appearing.
        var id: String {
            switch self {
            case .game(let row): "title \(row.game.id)"
            case .installable(let row): "title \(row.uid)"
            case .availableHeader: "available header"
            case .available(_, let key, _, _): "title \(key)"
            }
        }

        /// Which kind of cell shows the row.
        var kind: Int {
            switch self {
            case .game: 0
            case .installable: 1
            case .availableHeader: 2
            case .available: 3
            }
        }

        var hasBanner: Bool {
            switch self {
            case .game(let row): row.banner != nil
            case .installable(let row): row.picture != nil
            case .availableHeader, .available: false
            }
        }

        /// A game's or an install's row: the ones with a hairline between them.
        var isGame: Bool {
            switch self {
            case .game, .installable: true
            case .availableHeader, .available: false
            }
        }

        /// What changes a row's height: these optional views, and an error,
        /// which may take a second line. Other labels are single-line.
        var layout: (edition: Bool, progress: Bool, error: Bool) {
            switch self {
            case .game(let row):
                let progress: Bool = switch row.phase {
                case .preparingWindows(let update): update != nil
                case .updating, .pausing, .paused: true
                default: false
                }
                let error = if case .failed = row.phase { true } else { false }
                return (row.showsEdition, progress, error)
            case .installable(let row):
                if case .failed = row.phase { return (false, false, true) }
                return (false, true, false)
            case .availableHeader, .available:
                return (false, false, false)
            }
        }
    }

    private let model: AppModel
    private let appUpdater: AppUpdater
    private var rows: [Row] = []

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = NSStackView()
    private let emptyInstallButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let updateBanner = NSView()
    private let updateIcon = NSImageView()
    private let updateSpinner = NSProgressIndicator.spinner()
    private let updateText = NSTextField.label(.callout, color: .secondaryLabelColor)
    private let restartButton = NSButton(title: "Restart to Update", target: nil,
                                         action: #selector(AppDelegate.restartToUpdate(_:)))
    private let installMenu = NSMenu()
    private var installItem: NSMenuToolbarItem?
    private let accountMenu = NSMenu()
    private var accountItem: NSMenuToolbarItem?
    private var subtitle = ""
    /// Whether the games that can be installed show under their heading.
    private var showsAvailableGames = UserDefaults.standard.bool(forKey: "showsAvailableGames") {
        didSet { UserDefaults.standard.set(showsAvailableGames, forKey: "showsAvailableGames") }
    }

    private(set) lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "Library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    init(model: AppModel, appUpdater: AppUpdater) {
        self.model = model
        self.appUpdater = appUpdater
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("library"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .inset
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let emptyIcon = NSImageView(image: .symbol("gamecontroller", pointSize: 44) ?? NSImage())
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField.label(.title2)
        emptyTitle.font = .systemFont(ofSize: emptyTitle.font?.pointSize ?? 17, weight: .semibold)
        emptyTitle.stringValue = "No Games"
        let emptyDetail = NSTextField.label(.body, color: .secondaryLabelColor)
        emptyDetail.stringValue = "Blizzard games on this Mac appear here."
        emptyInstallButton.controlSize = .large
        if #available(macOS 26.0, *) { emptyInstallButton.borderShape = .capsule }
        emptyInstallButton.autoenablesItems = false
        emptyState.setViews([emptyIcon, emptyTitle, emptyDetail, emptyInstallButton], in: .center)
        emptyState.orientation = .vertical
        emptyState.spacing = 6
        emptyState.setCustomSpacing(12, after: emptyIcon)
        emptyState.setCustomSpacing(18, after: emptyDetail)

        let content = NSView()
        for view in [scrollView, emptyState] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        // The window's content runs under its toolbar: the scroll view insets
        // its rows itself, the empty state centers in what's left.
        let visible = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: visible.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: visible.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: visible.widthAnchor, constant: -32),
        ])
        content.setContentHuggingPriority(.init(1), for: .vertical)
        content.setContentCompressionResistancePriority(.init(1), for: .vertical)

        // Waypoint's own updates, inline instead of Sparkle's windows.
        if #available(macOS 26.0, *) { restartButton.borderShape = .capsule }
        restartButton.bezelColor = .controlAccentColor
        let updateBar = NSStackView()
        updateBar.setViews([updateSpinner, updateIcon, updateText], in: .leading)
        updateBar.setViews([restartButton], in: .trailing)
        updateBar.spacing = 8
        updateBar.detachesHiddenViews = true
        updateBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.borderWidth = 0
        card.cornerRadius = 12
        card.fillColor = .quaternarySystemFill
        card.contentViewMargins = .zero
        card.contentView = updateBar
        card.translatesAutoresizingMaskIntoConstraints = false
        updateBanner.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: updateBanner.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: updateBanner.trailingAnchor, constant: -10),
            card.topAnchor.constraint(equalTo: updateBanner.topAnchor),
            card.bottomAnchor.constraint(equalTo: updateBanner.bottomAnchor, constant: -10),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])

        let root = NSStackView(views: [content, updateBanner])
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 0
        root.detachesHiddenViews = true
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        view = root

        observeChanges { [weak self] in self?.render() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.subtitle = subtitle
    }

    /// Reads everything the window shows from the model, so `observeChanges`
    /// calls this again whenever any of it changes.
    private func render() {
        var rows = model.games.map { Row.game(GameRowState($0, model: model)) }
        var installChoices: [InstallableProduct] = []
        // The ones with no row above.
        var available: [Row] = []
        for product in model.installable {
            let phase = model.rowPhase(of: product)
            if phase != .idle {
                rows.append(.installable(InstallableRowState(product, phase: phase, model: model)))
            } else {
                let artwork = model.artwork(productCode: product.productCode)
                available.append(.available(product, key: model.installKey(for: product), picture: artwork.picture, icon: artwork.icon))
            }
            switch phase {
            case .updating, .pausing, .paused: continue
            default: break
            }
            installChoices.append(product)
        }
        // Under the installed ones. With none installed, the empty state
        // offers the same list.
        if !rows.isEmpty, !available.isEmpty {
            rows.append(.availableHeader(count: available.count, expanded: showsAvailableGames))
            if showsAvailableGames { rows += available }
        }
        show(rows)
        // Menu items belong to one menu, so each menu gets its own.
        let installMenuItems = { [weak self] in
            installChoices.map { product in ActionItem(product.displayName) { self?.install(product) } }
        }

        // NSMenuToolbarItem shows its menu as a pull-down button does: the
        // first item is the button's own and never appears. Without a
        // placeholder, a signed-out account menu's lone "Sign In…" did
        // nothing, and the account list lost its first row.
        installMenu.items = installChoices.isEmpty ? [] : [.pullDownPlaceholder(), .sectionHeader(title: "Install a Game")] + installMenuItems()
        installItem?.isEnabled = !installChoices.isEmpty
        // The same list under the empty state's button, whose title is the
        // pull-down's own first item.
        if rows.isEmpty {
            emptyInstallButton.menu?.items = [NSMenuItem(title: "Install a Game", action: nil, keyEquivalent: "")] + installMenuItems()
            emptyInstallButton.isEnabled = !installChoices.isEmpty
        }

        accountMenu.items = [.pullDownPlaceholder()] + AccountMenu.items(model: model)
        subtitle = model.activeAccount?.displayName ?? "Not signed in"
        view.window?.subtitle = subtitle
        let accountTooltip = model.activeAccount.map { "Signed in as \($0.displayName)" } ?? "Sign in to Battle.net"
        if accountItem?.toolTip != accountTooltip { accountItem?.toolTip = accountTooltip }
        accountItem?.image = .account(model.activeAccount)

        let ready = appUpdater.readyVersion != nil
        let recoveryError = model.downloadRecoveryError
        updateBanner.isHidden = appUpdater.status == nil && !ready && recoveryError == nil
        updateText.stringValue = appUpdater.status ?? recoveryError ?? ""
        let updateTooltip = appUpdater.status ?? recoveryError
        if updateText.toolTip != updateTooltip { updateText.toolTip = updateTooltip }
        updateSpinner.isHidden = !appUpdater.isBusy
        if appUpdater.isBusy { updateSpinner.startAnimation(nil) } else { updateSpinner.stopAnimation(nil) }
        updateIcon.isHidden = appUpdater.isBusy
        updateIcon.image = .symbol(ready ? "arrow.down.circle.fill" : "info.circle")
        updateIcon.contentTintColor = ready ? .controlAccentColor : .secondaryLabelColor
        restartButton.isHidden = !ready
    }

    private func show(_ newRows: [Row]) {
        var previousRows = rows
        rows = newRows
        scrollView.isHidden = rows.isEmpty
        emptyState.isHidden = !rows.isEmpty
        let current = rows.map(\.id)
        // Nothing on screen to move, or the person asked for less motion:
        // load the list as it is now.
        guard view.window?.isVisible == true, !previousRows.isEmpty, !rows.isEmpty,
              Set(previousRows.map(\.id)).count == previousRows.count, Set(current).count == current.count,
              previousRows.map(\.id) == current || !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if previousRows.map(\.id) != current || previousRows.map(\.kind) != rows.map(\.kind) {
                table.reloadData()
            } else {
                update(from: previousRows.map { $0 })
            }
            return
        }
        // A row that stays may need another cell: a game offered, then being
        // installed, then installed. It gets it where it is, before any row
        // moves: a cell swapped during the move came out the wrong size.
        let now = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let replaced = IndexSet(previousRows.indices.filter { row in
            guard let after = now[previousRows[row].id] else { return false }
            return after.kind != previousRows[row].kind
        })
        if !replaced.isEmpty {
            for row in replaced { previousRows[row] = now[previousRows[row].id] ?? previousRows[row] }
            rows = previousRows
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.removeRows(at: replaced, withAnimation: [])
                table.insertRows(at: replaced, withAnimation: [])
            }
            rows = newRows
        }
        // Rows came, went or changed places: slide them there.
        let previous = previousRows.map(\.id)
        if previous != current { arrange(from: previous, to: newRows) }
        let before = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, $0) })
        update(from: rows.map { before[$0.id] })
    }

    /// Shows the rows' new content (progress, say) in the cells they have,
    /// so a button under the pointer isn't swapped out mid-click. `previous`:
    /// each row as it was, nil for a new one, to tell which changed height.
    private func update(from previous: [Row?]) {
        table.enumerateAvailableRowViews { rowView, row in
            configure(rowView.view(atColumn: 0) as? NSView, at: row)
        }
        // Retiling the table on every progress report interrupts native
        // tooltips. Only invalidate heights when the row's layout changes.
        let resized = IndexSet(rows.indices.filter { row in previous[row].map { $0.layout != rows[row].layout } ?? false })
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: resized)
        }
    }

    /// Takes the table from the rows with the ids `previous` to `final`,
    /// animated: rows that are gone fade out, those that stay slide to
    /// their new places, new ones appear. The table applies each call to the
    /// rows as they are by then, so the steps are worked out the same way,
    /// and `rows` is what the table holds at each step, should it ask.
    private func arrange(from previous: [String], to final: [Row]) {
        let current = final.map(\.id)
        let staying = Set(previous).intersection(current)
        rows = final.filter { staying.contains($0.id) }
        table.beginUpdates()
        table.removeRows(at: IndexSet(previous.indices.filter { !staying.contains(previous[$0]) }), withAnimation: .effectFade)
        var order = previous.filter(staying.contains)
        for (place, id) in current.filter(staying.contains).enumerated() where order[place] != id {
            guard let from = order.firstIndex(of: id) else { continue }
            table.moveRow(at: from, to: place)
            order.remove(at: from)
            order.insert(id, at: place)
        }
        table.endUpdates()
        rows = final
        // New rows are put in place at once: added with the table's own
        // animation, several rows at a time keep its guess at their height
        // and overlap.
        let new = IndexSet(current.indices.filter { !staying.contains(current[$0]) })
        guard !new.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.insertRows(at: new, withAnimation: [])
        }
    }

    /// A hairline separates each game's row from the one above it, unless
    /// one of the two has a banner.
    private func configure(_ view: NSView?, at row: Int) {
        let separated = row > 0 && rows[row - 1].isGame && !rows[row - 1].hasBanner
        switch rows[row] {
        case .game(let state): (view as? GameCell)?.configure(state, model: model, showsSeparator: separated)
        case .installable(let state): (view as? InstallableCell)?.configure(state, model: model, showsSeparator: separated)
        case .availableHeader(let count, let expanded):
            let header = view as? AvailableHeaderCell
            header?.configure(count: count, expanded: expanded)
            header?.toggle = { [weak self] in
                guard let self else { return }
                self.showsAvailableGames.toggle()
                self.render()
            }
        case .available(let product, _, let picture, let icon):
            let cell = view as? AvailableGameCell
            cell?.configure(product, picture: picture, icon: icon)
            cell?.install = { [weak self] in self?.install(product) }
        }
    }

    private func install(_ product: InstallableProduct) {
        presentAsSheet(InstallSheet(product: product, model: model))
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .account {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = .account(model.activeAccount)
            item.label = "Account"
            item.toolTip = model.activeAccount.map { "Signed in as \($0.displayName)" } ?? "Sign in to Battle.net"
            item.showsIndicator = false
            accountMenu.autoenablesItems = false
            item.menu = accountMenu
            accountItem = item
            return item
        }
        guard identifier == .install else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = .symbol("plus")
        item.label = "Install"
        item.toolTip = "Install a game"
        item.showsIndicator = false
        item.autovalidates = false
        item.menu = installMenu
        item.isEnabled = !installMenu.items.isEmpty
        installItem = item
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .account, .install]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .account, .install]
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view: NSView = switch rows[row] {
        case .game: tableView.makeView(withIdentifier: GameCell.identifier, owner: nil) ?? GameCell()
        case .installable: tableView.makeView(withIdentifier: InstallableCell.identifier, owner: nil) ?? InstallableCell()
        case .availableHeader: tableView.makeView(withIdentifier: AvailableHeaderCell.identifier, owner: nil) ?? AvailableHeaderCell()
        case .available: tableView.makeView(withIdentifier: AvailableGameCell.identifier, owner: nil) ?? AvailableGameCell()
        }
        configure(view, at: row)
        return view
    }
}

private extension NSToolbarItem.Identifier {
    static let install = Self("install")
    static let account = Self("account")
}

extension NSMenuItem {
    /// The hidden first item a pull-down menu (NSMenuToolbarItem's) needs.
    static func pullDownPlaceholder() -> NSMenuItem { NSMenuItem(title: "", action: nil, keyEquivalent: "") }
}
