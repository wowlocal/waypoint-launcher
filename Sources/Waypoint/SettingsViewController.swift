import AppKit
import WaypointCore

/// Settings (⌘,): sign-in, download speed, game artwork and the opt-in menu
/// bar item.
@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let regionPopup = NSPopUpButton()
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "Show Waypoint in the menu bar", target: nil, action: nil)
    private let artworkCheckbox = NSButton(checkboxWithTitle: "Show game artwork", target: nil, action: nil)
    private let speedSlider = NSSlider(value: Double(DownloadSpeedLimit.choices.count - 1), minValue: 0,
                                       maxValue: Double(DownloadSpeedLimit.choices.count - 1), target: nil, action: nil)
    private let speedValue = NSTextField.label(.body, monospacedDigits: true)
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
        artworkCheckbox.target = self
        artworkCheckbox.action = #selector(artworkChanged)
        let artworkNote = NSTextField(wrappingLabelWithString: "A picture behind each game, and icons for games that aren’t installed. Downloaded from Blizzard’s catalog (about 7 MB); turning this off deletes the downloaded files.")
        artworkNote.font = .preferredFont(forTextStyle: .subheadline)
        artworkNote.textColor = .secondaryLabelColor
        artworkNote.preferredMaxLayoutWidth = 320
        artworkNote.widthAnchor.constraint(equalToConstant: 320).isActive = true
        speedSlider.numberOfTickMarks = DownloadSpeedLimit.choices.count
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.setAccessibilityLabel("Download speed limit")
        speedValue.alignment = .right
        speedValue.widthAnchor.constraint(equalToConstant: 90).isActive = true
        speedSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let speedRow = NSStackView(views: [speedSlider, speedValue])
        speedRow.spacing = 10
        let speedNote = NSTextField(wrappingLabelWithString: "Total for all game downloads. Changes apply immediately.")
        speedNote.font = .preferredFont(forTextStyle: .subheadline)
        speedNote.textColor = .secondaryLabelColor
        speedNote.preferredMaxLayoutWidth = 320
        speedNote.widthAnchor.constraint(equalToConstant: 320).isActive = true
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
            [NSTextField(labelWithString: "Artwork:"), artworkCheckbox],
            [NSGridCell.emptyContentView, artworkNote],
            [NSTextField(labelWithString: "Download speed:"), speedRow],
            [NSGridCell.emptyContentView, speedNote],
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
        grid.row(at: 5).topPadding = 12
        grid.row(at: 7).topPadding = 12

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
        observeChanges { [weak self] in self?.renderArtwork() }
        // ⌘-dragging the item out of the menu bar turns the setting off.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderMenuBar()
                self?.renderSpeed()
            }
        }
        renderMenuBar()
        renderSpeed()
    }

    private func renderRegion() {
        let region = model.regionOverride.flatMap { Region.allCases.firstIndex(of: $0) }
        regionPopup.selectItem(at: region.map { $0 + 1 } ?? 0)
    }

    private func renderMenuBar() {
        menuBarCheckbox.state = UserDefaults.standard.bool(forKey: MenuBarItem.defaultsKey) ? .on : .off
    }

    private func renderArtwork() {
        artworkCheckbox.state = model.showsArtwork ? .on : .off
    }

    @objc private func artworkChanged() {
        model.showsArtwork = artworkCheckbox.state == .on
    }

    @objc private func regionChanged() {
        let index = regionPopup.indexOfSelectedItem
        model.regionOverride = index > 0 ? Region.allCases[index - 1] : nil
    }

    @objc private func menuBarChanged() {
        UserDefaults.standard.set(menuBarCheckbox.state == .on, forKey: MenuBarItem.defaultsKey)
    }

    private func renderSpeed() {
        let limit = DownloadSpeedLimit.load()
        speedSlider.integerValue = DownloadSpeedLimit.choices.firstIndex(of: limit)!
        speedValue.stringValue = limit.label
        speedSlider.setAccessibilityValueDescription(limit.label)
        DownloadBandwidthLimiter.shared.bytesPerSecond = limit.bytesPerSecond
    }

    @objc private func speedChanged() {
        let index = min(max(speedSlider.integerValue, 0), DownloadSpeedLimit.choices.count - 1)
        DownloadSpeedLimit.choices[index].save()
        renderSpeed()
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
