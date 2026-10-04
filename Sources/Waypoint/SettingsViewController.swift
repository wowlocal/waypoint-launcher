import AppKit
import WaypointCore

/// Settings (⌘,): the region games sign in to, and the opt-in menu bar item.
@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let regionPopup = NSPopUpButton()
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "Show Waypoint in the menu bar", target: nil, action: nil)
    private let accountLabel = NSTextField(labelWithString: "")
    private let savedLoginNote = NSTextField(wrappingLabelWithString: "")
    private let saveLoginButton = NSButton(title: "Save Login…", target: nil, action: nil)
    private let forgetLoginButton = NSButton(title: "Forget Saved Login", target: nil, action: nil)
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
        saveLoginButton.target = self
        saveLoginButton.action = #selector(saveLogin)
        forgetLoginButton.target = self
        forgetLoginButton.action = #selector(forgetLogin)
        savedLoginNote.textColor = .secondaryLabelColor
        savedLoginNote.font = .preferredFont(forTextStyle: .subheadline)
        savedLoginNote.preferredMaxLayoutWidth = 320
        savedLoginNote.widthAnchor.constraint(equalToConstant: 320).isActive = true
        savedLoginNote.setContentCompressionResistancePriority(.required, for: .vertical)
        let loginButtons = NSStackView(views: [saveLoginButton, forgetLoginButton])
        loginButtons.spacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Region:"), regionPopup],
            [NSGridCell.emptyContentView, regionNote],
            [NSTextField(labelWithString: "Menu bar:"), menuBarCheckbox],
            [NSTextField(labelWithString: "Account:"), accountLabel],
            [NSGridCell.emptyContentView, savedLoginNote],
            [NSGridCell.emptyContentView, loginButtons],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.row(at: 2).topPadding = 12
        grid.row(at: 3).topPadding = 12

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
        observeChanges { [weak self] in self?.renderSavedLogin() }
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

    private func renderSavedLogin() {
        accountLabel.stringValue = model.activeAccount?.displayName ?? "Not Signed In"
        savedLoginNote.stringValue = model.savedLoginStatus
        saveLoginButton.title = model.hasSavedLogin ? "Update Saved Login…" : "Save Login…"
        saveLoginButton.isEnabled = model.activeAccount != nil && !model.isSigningIn
        forgetLoginButton.isEnabled = model.hasSavedLogin && !model.isSigningIn
        forgetLoginButton.isHidden = !model.hasSavedLogin
    }

    @objc private func saveLogin() { model.editSavedLogin() }
    @objc private func forgetLogin() { model.removeSavedLogin() }
}
