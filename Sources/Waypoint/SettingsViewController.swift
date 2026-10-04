import AppKit
import WaypointCore

/// Settings (⌘,): the region games sign in to, and the opt-in menu bar item.
@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let regionPopup = NSPopUpButton()
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "Show Waypoint in the menu bar", target: nil, action: nil)
    private var defaultsObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        regionPopup.addItem(withTitle: "As Installed")
        regionPopup.addItems(withTitles: Region.allCases.map(\.displayName))
        regionPopup.target = self
        regionPopup.action = #selector(regionChanged)
        let regionNote = NSTextField.label(.subheadline, color: .secondaryLabelColor)
        regionNote.stringValue = "The Battle.net region games sign in to."
        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(menuBarChanged)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Region:"), regionPopup],
            [NSGridCell.emptyContentView, regionNote],
            [NSTextField(labelWithString: "Menu bar:"), menuBarCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.row(at: 2).topPadding = 12

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        view = container

        observeChanges { [weak self] in self?.renderRegion() }
        // ⌘-dragging the item out of the menu bar turns the setting off.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderMenuBar() }
        }
        renderMenuBar()
    }

    private func renderRegion() {
        let region = model.regionOverride.flatMap { Region.allCases.firstIndex(of: $0) }
        regionPopup.selectItem(at: region.map { $0 + 1 } ?? 0)
    }

    private func renderMenuBar() {
        menuBarCheckbox.state = UserDefaults.standard.bool(forKey: MenuBarItem.defaultsKey) ? .on : .off
    }

    @objc private func regionChanged() {
        let index = regionPopup.indexOfSelectedItem
        model.regionOverride = index > 0 ? Region.allCases[index - 1] : nil
    }

    @objc private func menuBarChanged() {
        UserDefaults.standard.set(menuBarCheckbox.state == .on, forKey: MenuBarItem.defaultsKey)
    }
}
