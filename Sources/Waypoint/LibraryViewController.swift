import AppKit
import WaypointCore

/// The library window: installed games with Play and Update, games
/// available to install, Waypoint's own update status, and a footer with the
/// region and the update buttons.
@MainActor
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case game(GameRowState)
        case header(String)
        case installable(InstallableRowState)

        var id: String {
            switch self {
            case .game(let row): "game \(row.game.id)"
            case .header(let title): "header \(title)"
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
    private let regionPopup = NSPopUpButton()

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
        table.floatsGroupRows = false
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let emptyIcon = NSImageView(image: .symbol("gamecontroller", pointSize: 40) ?? NSImage())
        emptyIcon.contentTintColor = .secondaryLabelColor
        let emptyTitle = NSTextField.label(.title2)
        emptyTitle.font = .boldSystemFont(ofSize: emptyTitle.font?.pointSize ?? 17)
        emptyTitle.stringValue = "No games found"
        let emptyDetail = NSTextField.label(.body, color: .secondaryLabelColor)
        emptyDetail.stringValue = "Install a game, then rescan."
        emptyState.setViews([emptyIcon, emptyTitle, emptyDetail], in: .center)
        emptyState.orientation = .vertical
        emptyState.spacing = 8

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
        updateBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        regionPopup.addItem(withTitle: "Region: as installed")
        regionPopup.addItems(withTitles: Region.allCases.map(\.displayName))
        regionPopup.target = self
        regionPopup.action = #selector(regionChanged)
        let checkButton = NSButton(title: "Check for Updates", target: nil,
                                   action: #selector(AppDelegate.checkForUpdates(_:)))
        let rescanButton = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        let footer = NSStackView()
        footer.setViews([regionPopup], in: .leading)
        footer.setViews([checkButton, rescanButton], in: .trailing)
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let root = NSStackView(views: [content, NSBox.separator(), updateBar, updateSeparator, footer])
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

    /// Reads everything the window shows from the model, so `observeChanges`
    /// calls this again whenever any of it changes.
    private func render() {
        var rows = model.games.map { Row.game(GameRowState($0, model: model)) }
        let installable = model.installable
        if !installable.isEmpty {
            rows.append(.header("Available to install"))
            rows += installable.map { .installable(InstallableRowState(product: $0, phase: model.phase(of: $0))) }
        }
        show(rows)

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

        let region = model.regionOverride.flatMap { Region.allCases.firstIndex(of: $0) }
        regionPopup.selectItem(at: region.map { $0 + 1 } ?? 0)
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
        case .header(let title): (view as? HeaderCell)?.title.stringValue = title
        }
    }

    @objc private func regionChanged() {
        let index = regionPopup.indexOfSelectedItem
        model.regionOverride = index > 0 ? Region.allCases[index - 1] : nil
    }

    @objc private func rescan() {
        model.reload()
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view: NSView = switch rows[row] {
        case .game: tableView.makeView(withIdentifier: GameCell.identifier, owner: nil) ?? GameCell()
        case .installable: tableView.makeView(withIdentifier: InstallableCell.identifier, owner: nil) ?? InstallableCell()
        case .header: tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) ?? HeaderCell()
        }
        configure(view, as: rows[row])
        return view
    }
}
