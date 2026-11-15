import AppKit
import WaypointCore
import ServiceManagement

/// Settings (⌘,): sign-in, download speed, game artwork and the opt-in menu
/// bar item.
@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let backgroundServices: BackgroundServices
    private let hideDockCheckbox = NSButton(checkboxWithTitle: "Hide Dock icon (menu bar only)", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start Waypoint at login", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "Notify me when updates are available", target: nil, action: nil)
    private let testNotificationButton = NSButton(title: "Send Test Notification", target: nil, action: nil)
    private let notificationTestNote = NSTextField(wrappingLabelWithString: "")
    private let backgroundNote = NSTextField(wrappingLabelWithString: "")
    private let loginSettings = NSButton(title: "Login Items Settings…", target: nil, action: nil)
    private var changingLogin = false
    private var changingNotifications = false
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

    init(model: AppModel, backgroundServices: BackgroundServices) {
        self.model = model
        self.backgroundServices = backgroundServices
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

        for (button, action) in [
            (hideDockCheckbox, #selector(hideDockChanged)),
            (loginCheckbox, #selector(loginChanged)),
            (notificationsCheckbox, #selector(notificationsChanged)),
            (loginSettings, #selector(openLoginSettings)),
            (testNotificationButton, #selector(sendTestNotification)),
        ] { button.target = self; button.action = action }
        notificationTestNote.font = .preferredFont(forTextStyle: .subheadline)
        notificationTestNote.textColor = .secondaryLabelColor
        notificationTestNote.preferredMaxLayoutWidth = 360
        notificationTestNote.widthAnchor.constraint(equalToConstant: 360).isActive = true
        backgroundNote.font = .preferredFont(forTextStyle: .subheadline)
        backgroundNote.textColor = .secondaryLabelColor
        backgroundNote.preferredMaxLayoutWidth = 360
        backgroundNote.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let backgroundOptions = NSStackView(views: [menuBarCheckbox, hideDockCheckbox, loginCheckbox, loginSettings])
        backgroundOptions.orientation = .vertical
        backgroundOptions.alignment = .leading
        backgroundOptions.spacing = 8
        let updateOptions = NSStackView(views: [notificationsCheckbox, testNotificationButton, notificationTestNote, backgroundNote])
        updateOptions.orientation = .vertical
        updateOptions.alignment = .leading
        updateOptions.spacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Region:"), regionPopup],
            [NSGridCell.emptyContentView, regionNote],
            [NSTextField(labelWithString: "Background:"), backgroundOptions],
            [NSTextField(labelWithString: "Artwork:"), artworkCheckbox],
            [NSGridCell.emptyContentView, artworkNote],
            [NSTextField(labelWithString: "Download speed:"), speedRow],
            [NSGridCell.emptyContentView, speedNote],
            [NSTextField(labelWithString: "Account:"), accountLabel],
            [NSGridCell.emptyContentView, savedLoginNote],
            [NSGridCell.emptyContentView, loginButtons],
            [NSTextField(labelWithString: "Updates:"), updateOptions],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.row(at: 2).topPadding = 12
        grid.row(at: 3).topPadding = 12
        grid.row(at: 5).topPadding = 12
        grid.row(at: 7).topPadding = 12
        grid.row(at: 10).topPadding = 12

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

        observeChanges { [weak self] in self?.renderBackground() }
        observeChanges { [weak self] in self?.renderRegion() }
        observeChanges { [weak self] in self?.renderSavedLogin() }
        observeChanges { [weak self] in self?.renderArtwork() }
        // ⌘-dragging the item out of the menu bar turns the setting off.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderBackground()
                self?.renderMenuBar()
                self?.renderSpeed()
            }
        }
        renderMenuBar()
        renderSpeed()
    }

    private func renderBackground() {
        let defaults = UserDefaults.standard
        hideDockCheckbox.state = defaults.bool(forKey: UpdatePreferences.hideDockKey) ? .on : .off
        notificationsCheckbox.state = defaults.bool(forKey: UpdatePreferences.notificationsKey) ? .on : .off
        loginCheckbox.state = backgroundServices.loginStatus == .enabled || backgroundServices.loginStatus == .requiresApproval ? .on : .off
        loginCheckbox.isEnabled = !changingLogin && backgroundServices.supportsSystemIntegration
        notificationsCheckbox.isEnabled = !changingNotifications && backgroundServices.supportsSystemIntegration
        notificationTestNote.stringValue = backgroundServices.notificationTestStatus ?? ""
        notificationTestNote.isHidden = backgroundServices.notificationTestStatus == nil
        testNotificationButton.isEnabled = !backgroundServices.isTestingNotification && backgroundServices.supportsSystemIntegration &&
            defaults.bool(forKey: UpdatePreferences.notificationsKey) && backgroundServices.notificationStatus == .authorized
        loginSettings.isHidden = backgroundServices.loginStatus != .requiresApproval
        var note = "Checks installed games every 30 minutes while Waypoint is running. Game updates require your approval."
        if !backgroundServices.supportsSystemIntegration { note += " Notifications and login items require an installed app bundle." }
        if backgroundServices.loginStatus == .requiresApproval { note += " Approve Waypoint in Login Items Settings." }
        if backgroundServices.notificationStatus == .denied { note += " Notifications are blocked in macOS Notification Settings." }
        if let error = backgroundServices.errorMessage { note += " " + error }
        backgroundNote.stringValue = note
    }

    @objc private func hideDockChanged() { backgroundServices.setHideDock(hideDockCheckbox.state == .on) }
    @objc private func loginChanged() {
        let enabled = loginCheckbox.state == .on
        changingLogin = true; renderBackground()
        Task {
            await backgroundServices.setLoginEnabled(enabled)
            changingLogin = false; renderBackground()
        }
    }
    @objc private func notificationsChanged() {
        let enabled = notificationsCheckbox.state == .on
        changingNotifications = true; renderBackground()
        Task {
            await backgroundServices.setNotificationsEnabled(enabled)
            changingNotifications = false; renderBackground()
            if UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey) {
                await model.checkForUpdates(force: true)
            }
        }
    }
    @objc private func sendTestNotification() { Task { await backgroundServices.sendTestNotification() } }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

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
