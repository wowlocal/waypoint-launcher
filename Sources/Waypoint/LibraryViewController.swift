import AppKit
import WaypointCore

/// The library window: installed games with Play and Update, games being
/// installed, the Battle.net account games launch as (in the subtitle; a
/// toolbar menu switches it), a + toolbar menu to install more, and
/// Waypoint's own update status when it has something to say.
@MainActor
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private enum Row {
        case game(GameRowState)
        case installable(InstallableRowState)

        var id: String {
            switch self {
            case .game(let row): "game \(row.game.id)"
            case .installable(let row): "installable \(row.product.uid)"
            }
        }
    }

    private let model: AppModel
    private let appUpdater: AppUpdater
    private var rows: [Row] = []

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = NSStackView()
    private let updateBar = NSStackView()
    private let updateSeparator = NSBox.separator()
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

        let emptyIcon = NSImageView(image: .symbol("gamecontroller", pointSize: 36) ?? NSImage())
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField.label(.title3)
        emptyTitle.font = .boldSystemFont(ofSize: emptyTitle.font?.pointSize ?? 15)
        emptyTitle.stringValue = "No Games"
        let emptyDetail = NSTextField.label(.body, color: .secondaryLabelColor)
        emptyDetail.stringValue = "Install one with the + button."
        emptyState.setViews([emptyIcon, emptyTitle, emptyDetail], in: .center)
        emptyState.orientation = .vertical
        emptyState.spacing = 6

        let content = NSView()
        for view in [scrollView, emptyState] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        content.setContentHuggingPriority(.init(1), for: .vertical)
        content.setContentCompressionResistancePriority(.init(1), for: .vertical)

        // Waypoint's own updates, inline instead of Sparkle's windows.
        restartButton.controlSize = .small
        restartButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateBar.setViews([updateSpinner, updateIcon, updateText], in: .leading)
        updateBar.setViews([restartButton], in: .trailing)
        updateBar.spacing = 8
        updateBar.detachesHiddenViews = true
        updateBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let root = NSStackView(views: [content, updateSeparator, updateBar])
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
        var installMenuItems: [NSMenuItem] = []
        for product in model.installable {
            let phase = model.phase(of: product)
            if phase != .idle { rows.append(.installable(InstallableRowState(product: product, phase: phase))) }
            if case .updating = phase { continue }
            installMenuItems.append(ActionItem(product.displayName) { [weak self] in self?.install(product) })
        }
        show(rows)

        installMenu.items = installMenuItems.isEmpty ? [] : [.sectionHeader(title: "Install a Game")] + installMenuItems
        installItem?.isEnabled = !installMenuItems.isEmpty

        accountMenu.items = AccountMenu.items(model: model)
        subtitle = model.activeAccount?.displayName ?? "Not signed in"
        view.window?.subtitle = subtitle
        accountItem?.toolTip = model.activeAccount.map { "Signed in as \($0.displayName)" } ?? "Sign in to Battle.net"
        accountItem?.image = .account(model.activeAccount)

        let ready = appUpdater.readyVersion != nil
        updateBar.isHidden = appUpdater.status == nil && !ready
        updateSeparator.isHidden = updateBar.isHidden
        updateText.stringValue = appUpdater.status ?? ""
        updateText.toolTip = appUpdater.status
        updateSpinner.isHidden = !appUpdater.isBusy
        if appUpdater.isBusy { updateSpinner.startAnimation(nil) } else { updateSpinner.stopAnimation(nil) }
        updateIcon.isHidden = appUpdater.isBusy
        updateIcon.image = .symbol(ready ? "arrow.down.circle.fill" : "info.circle")
        updateIcon.contentTintColor = ready ? .controlAccentColor : .secondaryLabelColor
        restartButton.isHidden = !ready
    }

    private func show(_ newRows: [Row]) {
        let sameRows = newRows.map(\.id) == rows.map(\.id)
        rows = newRows
        scrollView.isHidden = rows.isEmpty
        emptyState.isHidden = !rows.isEmpty
        guard sameRows else {
            table.reloadData()
            return
        }
        // Same rows, new content (progress, say): update them in place, so a
        // button under the pointer isn't swapped out mid-click.
        table.enumerateAvailableRowViews { rowView, row in
            configure(rowView.view(atColumn: 0) as? NSView, as: rows[row])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    private func configure(_ view: NSView?, as row: Row) {
        switch row {
        case .game(let state): (view as? GameCell)?.configure(state, model: model)
        case .installable(let state): (view as? InstallableCell)?.configure(state, model: model)
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
        }
        configure(view, as: rows[row])
        return view
    }
}

private extension NSToolbarItem.Identifier {
    static let install = Self("install")
    static let account = Self("account")
}
