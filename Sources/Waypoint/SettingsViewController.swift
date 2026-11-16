import AppKit
import ServiceManagement
import WaypointCore

/// Settings (⌘,): a toolbar of panes, each a short column of titled sections.
@MainActor
final class SettingsViewController: NSTabViewController {
    init(model: AppModel, appUpdater: AppUpdater, backgroundServices: BackgroundServices) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        add(GeneralSettings(model: model, updater: appUpdater), "General", symbol: "gearshape")
        add(AutomaticUpdateSettings(model: model), "Downloads", symbol: "arrow.down.circle")
        add(AccountSettings(model: model), "Account", symbol: "person.crop.circle")
        add(BackgroundSettings(services: backgroundServices), "Background", symbol: "menubar.rectangle")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func add(_ pane: NSViewController, _ title: String, symbol: String) {
        pane.title = title
        let item = NSTabViewItem(viewController: pane)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let toolbar = view.window?.toolbar else { return }
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }
}

/// One pane: titled sections stacked top to bottom, sized to fit what they show.
@MainActor
class SettingsPane: NSViewController {
    static let width: CGFloat = 420
    let stack = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: Self.width - 48),
        ])
        view = root
        build()
    }

    /// Adds the pane's sections to `stack`.
    func build() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// The tab view controller sizes the window to this when the pane shows.
    func fit() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    /// A titled group. Its own stack, so the gap between sections holds when
    /// a section's last view is hidden.
    @discardableResult
    func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        let section = NSStackView(views: [label] + views)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.setCustomSpacing(10, after: label)
        stack.addArrangedSubview(section)
        return section
    }

    func note(_ text: String = "") -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .preferredFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.width - 48
        note.setContentCompressionResistancePriority(.required, for: .vertical)
        return note
    }
}

// MARK: General

@MainActor
private final class GeneralSettings: SettingsPane {
    private let model: AppModel
    private let regionPopup = NSPopUpButton()
    private let artworkCheckbox = NSButton(checkboxWithTitle: "Show game artwork", target: nil, action: nil)
    private let speedSlider = NSSlider(value: Double(DownloadSpeedLimit.choices.count - 1), minValue: 0,
                                       maxValue: Double(DownloadSpeedLimit.choices.count - 1), target: nil, action: nil)
    private let speedValue = NSTextField.label(.body, monospacedDigits: true)
    private var defaultsObserver: NSObjectProtocol?
    private let updater: AppUpdater
    private let tipsCheckbox = NSButton(checkboxWithTitle: "Get tip builds", target: nil, action: nil)
    private let tipsStatus = NSTextField(wrappingLabelWithString: "")
    private let restartButton = NSButton(title: "Restart to Update", target: nil, action: nil)

    init(model: AppModel, updater: AppUpdater) {
        self.model = model
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func build() {
        regionPopup.addItem(withTitle: "As Installed")
        regionPopup.addItems(withTitles: Region.allCases.map(\.displayName))
        regionPopup.target = self
        regionPopup.action = #selector(regionChanged)
        regionPopup.setAccessibilityLabel("Region")
        section("Region", [regionPopup, note("The Battle.net region games sign in to.")])

        artworkCheckbox.target = self
        artworkCheckbox.action = #selector(artworkChanged)
        section("Artwork", [artworkCheckbox, note("A picture behind each game, and icons for games that aren’t installed. Downloaded from Blizzard’s catalog (about 7 MB); turning this off deletes the downloaded files.")])

        speedSlider.numberOfTickMarks = DownloadSpeedLimit.choices.count
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(speedChanged)
        speedSlider.setAccessibilityLabel("Download speed limit")
        speedValue.alignment = .right
        speedValue.widthAnchor.constraint(equalToConstant: 90).isActive = true
        speedSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let speedRow = NSStackView(views: [speedSlider, speedValue])
        speedRow.spacing = 10
        section("Download Speed", [speedRow, note("Total for all game downloads. Changes apply immediately.")])

        // Development builds don't update themselves: no choice to offer.
        if updater.canUpdate {
            tipsCheckbox.target = self
            tipsCheckbox.action = #selector(tipsChanged)
            tipsStatus.font = .preferredFont(forTextStyle: .subheadline)
            tipsStatus.preferredMaxLayoutWidth = Self.width - 48
            restartButton.target = self
            restartButton.action = #selector(restart)
            let running = updater.running == .tip
                ? " This copy is tip build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")."
                : ""
            section("Updates", [tipsCheckbox,
                                note("Try what’s next before it’s released: new features, which may be unfinished. Turning this off goes back to the latest release.\(running)"),
                                tipsStatus, restartButton])
            observeChanges { [weak self] in self?.renderUpdates() }
        }

        observeChanges { [weak self] in self?.renderRegion() }
        observeChanges { [weak self] in self?.renderArtwork() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderSpeed() }
        }
        renderSpeed()
    }

    private func renderRegion() {
        let region = model.regionOverride.flatMap { Region.allCases.firstIndex(of: $0) }
        regionPopup.selectItem(at: region.map { $0 + 1 } ?? 0)
    }

    @objc private func regionChanged() {
        let index = regionPopup.indexOfSelectedItem
        model.regionOverride = index > 0 ? Region.allCases[index - 1] : nil
    }

    private func renderArtwork() { artworkCheckbox.state = model.showsArtwork ? .on : .off }

    private func renderUpdates() {
        tipsCheckbox.state = updater.receivesTips ? .on : .off
        tipsStatus.stringValue = updater.status ?? ""
        tipsStatus.isHidden = updater.status == nil
        restartButton.isHidden = updater.readyVersion == nil
        // Only while General shows: another pane must keep its own height.
        if view.window != nil { fit() }
    }

    @objc private func tipsChanged() { updater.setReceivesTips(tipsCheckbox.state == .on) }
    @objc private func restart() { updater.restartToUpdate() }
    @objc private func artworkChanged() { model.showsArtwork = artworkCheckbox.state == .on }

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
}

// MARK: Account

@MainActor
private final class AccountSettings: SettingsPane {
    private let model: AppModel
    private let accountLabel = NSTextField(labelWithString: "")
    private lazy var savedLoginNote = note()
    private let saveLoginButton = NSButton(title: "Save Login…", target: nil, action: nil)
    private let forgetLoginButton = NSButton(title: "Forget Saved Login", target: nil, action: nil)

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func build() {
        saveLoginButton.target = self
        saveLoginButton.action = #selector(saveLogin)
        forgetLoginButton.target = self
        forgetLoginButton.action = #selector(forgetLogin)
        let buttons = NSStackView(views: [saveLoginButton, forgetLoginButton])
        buttons.spacing = 8
        section("Battle.net Account", [accountLabel, savedLoginNote, buttons])
            .setCustomSpacing(12, after: savedLoginNote)
        observeChanges { [weak self] in self?.render() }
    }

    private func render() {
        accountLabel.stringValue = model.activeAccount?.displayName ?? "Not Signed In"
        savedLoginNote.stringValue = model.savedLoginStatus
        saveLoginButton.title = model.hasSavedLogin ? "Update Saved Login…" : "Save Login…"
        saveLoginButton.isEnabled = model.activeAccount != nil && !model.isSigningIn
        forgetLoginButton.isEnabled = model.hasSavedLogin && !model.isSigningIn
        forgetLoginButton.isHidden = !model.hasSavedLogin
        if view.window != nil { fit() }
    }

    @objc private func saveLogin() { model.editSavedLogin() }
    @objc private func forgetLogin() { model.removeSavedLogin() }
}

// MARK: Background

/// The opt-in ways Waypoint keeps running without its window.
@MainActor
private final class BackgroundSettings: SettingsPane {
    private let services: BackgroundServices
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "Show Waypoint in the menu bar", target: nil, action: nil)
    private let hideDockCheckbox = NSButton(checkboxWithTitle: "Hide Dock icon", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Waypoint at login", target: nil, action: nil)
    private lazy var loginNote = note()
    private let loginItemsButton = NSButton(title: "Login Items Settings…", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "Notify me about updates", target: nil, action: nil)
    private lazy var notificationsNote = note()
    /// While macOS applies a click, its checkbox keeps showing what was
    /// clicked: redrawing from the old status would flip it back and forth.
    private var changingLogin = false
    private var changingNotifications = false
    private var defaultsObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    init(services: BackgroundServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func build() {
        for (button, action) in [
            (menuBarCheckbox, #selector(menuBarChanged)),
            (hideDockCheckbox, #selector(hideDockChanged)),
            (loginCheckbox, #selector(loginChanged)),
            (loginItemsButton, #selector(openLoginItems)),
            (notificationsCheckbox, #selector(notificationsChanged)),
        ] { button.target = self; button.action = action }
        // Without the Dock icon, the menu bar item is the way back to
        // Waypoint, so the one goes with the other.
        let hideDockRow = NSStackView(views: [hideDockCheckbox])
        hideDockRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        section("Menu Bar", [menuBarCheckbox, hideDockRow])
        section("Login", [loginCheckbox, loginNote, loginItemsButton])
            .setCustomSpacing(10, after: loginNote)
        section("Notifications", [notificationsCheckbox, notificationsNote])

        observeChanges { [weak self] in self?.render() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        // Approval may have changed in System Settings meanwhile.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window?.isVisible == true else { return }
                self.services.refreshStatus()
            }
        }
    }

    override func viewWillAppear() {
        services.refreshStatus()
        super.viewWillAppear()
    }

    private func render() {
        let defaults = UserDefaults.standard
        let menuBar = defaults.bool(forKey: MenuBarItem.defaultsKey)
        menuBarCheckbox.state = menuBar ? .on : .off
        hideDockCheckbox.state = defaults.bool(forKey: BackgroundPreferences.hideDockKey) ? .on : .off
        hideDockCheckbox.isEnabled = menuBar

        let integrated = services.supportsSystemIntegration
        let status = services.loginStatus
        if !changingLogin { loginCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off }
        loginCheckbox.isEnabled = integrated
        let needsApproval = status == .requiresApproval
        loginItemsButton.isHidden = !needsApproval
        show(loginNote, needsApproval ? "Allow Waypoint in Login Items to finish." : services.loginError)

        let notifications = defaults.bool(forKey: BackgroundPreferences.notificationsKey)
        if !changingNotifications { notificationsCheckbox.state = notifications ? .on : .off }
        notificationsCheckbox.isEnabled = integrated
        show(notificationsNote, notifications && services.notificationStatus == .denied
             ? "Notifications for Waypoint are turned off in System Settings." : services.notificationsError)
        // Only a note appearing or going changes the pane's height.
        let shape = [loginNote.isHidden, loginItemsButton.isHidden, notificationsNote.isHidden]
        if shape != lastShape, view.window != nil { fit() }
        lastShape = shape
    }

    private var lastShape: [Bool] = []

    private func show(_ note: NSTextField, _ text: String?) {
        note.stringValue = text ?? ""
        note.isHidden = text == nil
    }

    @objc private func menuBarChanged() {
        UserDefaults.standard.set(menuBarCheckbox.state == .on, forKey: MenuBarItem.defaultsKey)
    }

    @objc private func hideDockChanged() { services.setHideDock(hideDockCheckbox.state == .on) }

    @objc private func loginChanged() {
        let enabled = loginCheckbox.state == .on
        // A click while the last one is applied: the box stays as it shows.
        guard !changingLogin else { loginCheckbox.state = enabled ? .off : .on; return }
        changingLogin = true
        Task {
            await services.setLoginEnabled(enabled)
            changingLogin = false; render()
        }
    }

    @objc private func notificationsChanged() {
        let enabled = notificationsCheckbox.state == .on
        guard !changingNotifications else { notificationsCheckbox.state = enabled ? .off : .on; return }
        changingNotifications = true
        Task {
            await services.setNotificationsEnabled(enabled)
            changingNotifications = false; render()
        }
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
