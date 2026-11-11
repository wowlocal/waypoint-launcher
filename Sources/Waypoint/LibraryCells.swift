import AppKit
import UniformTypeIdentifiers
import WaypointCore

/// What a game row shows, read from the model in one go: the library
/// re-renders when any of it changes (see `LibraryViewController.render`).
struct GameRowState {
    var game: Game
    var phase: AppModel.Phase
    var isRunning: Bool
    var update: UpdateCheck?
    var canPlay: Bool
    var canUpdate: Bool
    var showsEdition: Bool
    var download: DownloadControls
    // PROTOTYPE (banners, played time)
    /// The picture to show behind the row, if the person has put one there.
    var banner: URL?
    /// nil: Waypoint hasn't seen this game played.
    var played: PlayedTime?
}

/// PROTOTYPE: how long a game has been played, counted from its process.
struct PlayedTime: Equatable {
    var total: TimeInterval
    var lastSession: TimeInterval?
    /// How long it has been running now, while it runs.
    var runningFor: TimeInterval?

    /// "7h 48m", "8m", "under a minute".
    static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        // Past ten hours the minutes are noise.
        return minutes % 60 == 0 || minutes >= 600 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

extension GameRowState {
    @MainActor init(_ game: Game, model: AppModel) {
        self.init(game: game, phase: model.phase(of: game), isRunning: model.isRunning(game),
                  update: model.availableUpdate(for: game), canPlay: model.canPlay(game),
                  canUpdate: model.canUpdate(game), showsEdition: game.install.productCode == "hero" &&
                    (WindowsHeroes.isAvailable || model.heroesEdition(.windows) != nil),
                  download: DownloadControls(uid: game.id, model: model),
                  banner: GameBanners.shared.file(for: game.id), played: nil)
    }
}

/// A game being installed, or whose install failed.
struct InstallableRowState {
    var product: InstallableProduct
    var phase: AppModel.Phase
    /// The download job's key: the product's uid on the platform it installs for.
    var uid: String
    var download: DownloadControls
}

extension InstallableRowState {
    @MainActor init(_ product: InstallableProduct, phase: AppModel.Phase, model: AppModel) {
        let uid = model.installKey(for: product)
        self.init(product: product, phase: phase, uid: uid, download: DownloadControls(uid: uid, model: model))
    }
}

/// What a row's download buttons can do right now.
struct DownloadControls: Equatable {
    var canPause = false
    var canResume = false
    var canCancel = false
    var keepsMacAwake = false
    /// PROTOTYPE (download line): the rate right now, while it downloads.
    var bytesPerSecond: Double?
}

extension DownloadControls {
    @MainActor init(uid: String, model: AppModel) {
        self.init(canPause: model.canPauseDownload(uid: uid), canResume: model.canResumeDownload(uid: uid),
                  canCancel: model.canCancelDownload(uid: uid), keepsMacAwake: model.keepsMacAwake(uid: uid),
                  bytesPerSecond: model.downloadBytesPerSecond(uid: uid))
    }
}

/// An installed game: icon, name, one quiet line of status, and Play or
/// Update on the right. The … button (or a right-click) has the other ways
/// to play, and Uninstall.
@MainActor
final class GameCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("game")

    private let icon = GameIconView()
    private let name = NSTextField.label(.headline)
    private let downloadDetailsView = DownloadDetailsView()
    private var detail: NSTextField { downloadDetailsView.label }
    private let button = NSButton.rowAction("Play")
    private let moreButton = NSButton.rowIcon("ellipsis", label: "More")
    private let separator = NSBox.separator()
    private let row = NSStackView()
    private let text = NSStackView()
    // The rest is made when a row first shows it. Most rows never do, and
    // making it all took as long again as the views every row shows: that
    // was a fifth of the time from launch to the window.
    private var edition: NSPopUpButton?
    private var statusDot: NSImageView?
    private var status: NSTextField?
    private var spinner: NSProgressIndicator?
    private var downloadButtons: DownloadButtons?
    private var banner: BannerView?
    private var iconPath: String?
    private var state: GameRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        button.target = self
        button.action = #selector(primaryAction)
        moreButton.target = self
        moreButton.action = #selector(showMore)
        moreButton.toolTip = "More"
        layOutRow(row, in: self, icon: icon, text: text, lines: [name, downloadDetailsView], details: downloadDetailsView,
                  trailing: [button, moreButton], separator: separator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// PROTOTYPE: behind everything else. A picture is a rounded shape a
    /// little wider than the row's content; a wash of color has no edges and
    /// runs the row's full height, out to the window's edge.
    private func makeBanner() -> BannerView {
        let banner = BannerView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner, positioned: .below, relativeTo: row)
        let card = BannerView.style.isCard
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: card ? 8 : 16),
            banner.topAnchor.constraint(equalTo: topAnchor, constant: card ? 3 : 0),
            banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: card ? -3 : 0),
        ])
        self.banner = banner
        return banner
    }

    /// Heroes of the Storm's Windows or macOS choice, under the name.
    private func makeEdition() -> NSPopUpButton {
        let edition = NSPopUpButton()
        edition.addItems(withTitles: ["Windows (recommended)", "macOS"])
        edition.menu?.autoenablesItems = false
        edition.controlSize = .small
        edition.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        edition.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        edition.cell?.lineBreakMode = .byTruncatingTail
        edition.target = self
        edition.action = #selector(changeEdition)
        text.insert(edition, after: name)
        edition.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true
        self.edition = edition
        return edition
    }

    func configure(_ state: GameRowState, model: AppModel, showsSeparator: Bool) {
        self.state = state
        self.model = model
        // A picture is its own edge: no hairline above it.
        separator.isHidden = !showsSeparator || (state.banner != nil && BannerView.style.isCard)
        let game = state.game
        let app = game.appURL ?? (game.install.productCode == "hero" ? model.heroesEdition(.macOS)?.appURL : nil)
        let windows = WindowsTitle.forInstall(game.install).map {
            URL(fileURLWithPath: game.install.installPath).appendingPathComponent($0.executablePath)
        }
        let path = app?.path ?? windows?.path
        if icon.image == nil || iconPath != path {
            iconPath = path
            if app == nil, let windows, let data = WindowsExecutableIcon.data(at: windows), NSImage(data: data) != nil {
                icon.showWindowsArtwork(data)
            } else {
                if app == nil, windows != nil { iconPath = nil }
                icon.showFileIcon(at: path)
            }
        }
        if BannerView.style == .icontint, let app {
            let banner = banner ?? makeBanner()
            banner.show(iconAt: app.path)
            banner.isHidden = false
        } else if BannerView.style != .icontint, let file = state.banner {
            let banner = banner ?? makeBanner()
            banner.show(picture: file)
            banner.isHidden = false
        } else {
            banner?.isHidden = true
        }
        name.stringValue = game.displayName
        if state.showsEdition {
            let edition = edition ?? makeEdition()
            edition.isHidden = false
            edition.item(at: 0)?.title = WindowsHeroes.isAvailable ? "Windows (recommended)" : "Windows"
            edition.item(at: 0)?.isEnabled = WindowsHeroes.isAvailable
            edition.selectItem(at: game.install.platform == .windows ? 0 : 1)
            let isUninstalling = if case .uninstalling = state.phase { true } else { false }
            edition.isEnabled = !state.isRunning && !model.isSigningIn && state.phase != .launching && !isUninstalling
        } else {
            edition?.isHidden = true
        }
        let versionTooltip = game.install.version.map { "Version \($0)" }
        if name.toolTip != versionTooltip { name.toolTip = versionTooltip }

        var fraction: Double?
        var showsError = false
        var downloadTooltip: (() -> String)?
        var detailTooltip: String?
        detail.textColor = .secondaryLabelColor
        switch state.phase {
        case .preparingWindows(let update):
            if let update {
                fraction = update.fraction
                detail.stringValue = "Windows components: " + progressDescription(update, waiting: "Downloading…")
            } else {
                detail.stringValue = "Preparing Windows version…"
            }
        case .updating(let update):
            fraction = update?.fraction ?? 0
            detail.stringValue = progressDescription(update, waiting: "Checking files…", bytesPerSecond: state.download.bytesPerSecond)
            downloadTooltip = { [weak model] in
                downloadDetails(update, bytesPerSecond: model?.downloadBytesPerSecond(uid: game.id), status: "Downloading…")
            }
        case .pausing(let update), .paused(let update):
            fraction = update?.fraction ?? 0
            let pausing = if case .pausing = state.phase { true } else { false }
            detail.stringValue = downloadStatus(update, label: pausing ? "Pausing…" : "Paused")
            downloadTooltip = { downloadDetails(update, bytesPerSecond: nil, status: pausing ? "Pausing…" : "Paused") }
        case .uninstalling(let step):
            detail.stringValue = step
        case .failed(let message):
            detail.stringValue = message
            detailTooltip = message
            detail.textColor = .systemRed
            showsError = true
        default:
            if state.update != nil, !state.isRunning {
                detail.stringValue = GameUpdate.canUpdate(game.install) ? "Update available" : "Update available in Battle.net"
                detail.textColor = .systemOrange
            } else {
                detail.stringValue = Self.summary(of: game, played: state.played)
                if let last = state.played?.lastSession { detailTooltip = "Last session: \(PlayedTime.text(last))" }
            }
        }

        if detail.toolTip != detailTooltip { detail.toolTip = detailTooltip }
        downloadDetailsView.showsError = showsError
        downloadDetailsView.fraction = fraction
        downloadDetailsView.details = downloadTooltip
        if downloadButtons != nil || DownloadButtons.haveAny(for: state.download, phase: state.phase) {
            let buttons = downloadButtons ?? makeDownloadButtons()
            buttons.show(state.download, phase: state.phase, uid: game.id, model: model)
        }
        status?.isHidden = true
        statusDot?.isHidden = true
        spinner?.isHidden = true
        spinner?.stopAnimation(nil)
        var showsButton = false
        // Its own progress shows rather than Running or Unsupported.
        let hasDownloadControls: Bool = switch state.phase {
        case .updating, .pausing, .paused, .uninstalling: true
        default: false
        }
        if state.isRunning, case .launching = state.phase, !hasDownloadControls {
            showSpinner("Starting…")
        } else if state.isRunning, case .failed = state.phase, !hasDownloadControls {
            show(status: "Needs attention")
        } else if state.isRunning, !hasDownloadControls {
            showRunning(for: state.played?.runningFor)
        } else if !game.isSupported, !hasDownloadControls {
            show(status: !game.isInstalled ? "Not installed" : (game.install.platform == .windows ? "Windows support unavailable" : (game.runsNatively ? "Unsupported" : "Needs Rosetta")))
        } else {
            switch state.phase {
            case .signingIn:
                showSpinner("Signing in…")
            case .preparingWindows:
                showSpinner("Preparing Windows version…")
            case .launching:
                showSpinner("Starting…")
            case .updating, .pausing, .paused:
                break // The download buttons are showing.
            case .uninstalling(let step):
                showSpinner(step)
            case .idle, .failed:
                let updates = state.update != nil && GameUpdate.canUpdate(game.install)
                let retry = state.download.canResume
                let title = retry ? "Resume" : (updates ? "Update" : "Play")
                if button.title != title { button.title = title }
                // An update is the one thing in the list asking for attention.
                button.bezelColor = updates && !retry ? .controlAccentColor : nil
                button.isEnabled = retry || (updates ? state.canUpdate : state.canPlay)
                showsButton = true
            }
        }
        // Do not detach and reattach the buttons on every progress report:
        // that needlessly invalidates the surrounding stack's layout.
        button.isHidden = !showsButton
        moreButton.isHidden = !offersMenu
    }

    @objc private func changeEdition() {
        guard let model, let state, let edition, state.game.install.productCode == "hero" else { return }
        let platform: InstallPlatform = edition.indexOfSelectedItem == 0 ? .windows : .macOS
        guard platform == .macOS || WindowsHeroes.isAvailable else { return }
        if model.heroesEdition(platform)?.isInstalled == true {
            model.selectHeroesEdition(platform)
        } else if let product = InstallableProduct.forProduct("hero") {
            edition.selectItem(at: state.game.install.platform == .windows ? 0 : 1)
            window?.contentViewController?.presentAsSheet(InstallSheet(product: product, model: model, platform: platform))
        }
    }

    // The status, the spinner, and a download's keep-awake and pause buttons
    // go left of the main button. Only one of the three shows at a time (the
    // green dot comes with "Running"), so their order among them is free.

    private func show(status text: String) {
        let status = status ?? {
            let status = NSTextField.label(.body, color: .secondaryLabelColor)
            row.insert(status, before: button)
            self.status = status
            return status
        }()
        status.stringValue = text
        status.isHidden = false
    }

    /// "Running", after a green dot; "Running · 8m" when it's known since when.
    private func showRunning(for time: TimeInterval?) {
        show(status: time.map { "Running · \(PlayedTime.text($0))" } ?? "Running")
        let dot = statusDot ?? {
            let dot = NSImageView(image: .symbol("circle.fill", pointSize: 7) ?? NSImage())
            dot.contentTintColor = .systemGreen
            dot.setAccessibilityElement(false)
            row.insert(dot, before: status ?? button)
            row.setCustomSpacing(5, after: dot)
            statusDot = dot
            return dot
        }()
        dot.isHidden = false
    }

    private func showSpinner(_ help: String) {
        let spinner = spinner ?? {
            let spinner = NSProgressIndicator.spinner()
            row.insert(spinner, before: button)
            self.spinner = spinner
            return spinner
        }()
        spinner.toolTip = help
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    private func makeDownloadButtons() -> DownloadButtons {
        let buttons = DownloadButtons()
        buttons.place(in: row, around: button)
        downloadButtons = buttons
        return buttons
    }

    /// Resume (a download that stopped), Update or Play: what the button says.
    @objc private func primaryAction() {
        guard let state, let model else { return }
        let game = state.game
        switch state.phase {
        case .idle, .failed: break
        default: return
        }
        if model.canResumeDownload(uid: game.id) {
            Task { await model.resumeDownload(uid: game.id) }
        } else if state.update != nil, GameUpdate.canUpdate(game.install) {
            Task { await model.update(game) }
        } else {
            Task { await model.play(game) }
        }
    }

    @objc private func showMore() {
        // Below the button, as a pull-down's menu opens.
        makeMenu()?.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 6), in: moreButton)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    /// Whether `makeMenu` has anything to show, without building it.
    private var offersMenu: Bool {
        guard let state, !state.isRunning else { return false }
        switch state.phase {
        case .idle, .failed: return state.game.isSupported || state.game.isInstalled
        default: return false
        }
    }

    private func makeMenu() -> NSMenu? {
        guard let state, let model, !state.isRunning else { return nil }
        switch state.phase {
        case .idle, .failed: break
        default: return nil
        }
        let game = state.game
        let menu = NSMenu()
        menu.autoenablesItems = false
        if game.isSupported {
            if model.availableUpdate(for: game) != nil {
                menu.addItem(ActionItem("Play Without Updating") { Task { await model.play(game) } })
            }
            let others = model.accounts.filter { $0.id != model.activeAccount?.id }
            if !others.isEmpty {
                let playAs = NSMenuItem(title: "Play As", action: nil, keyEquivalent: "")
                playAs.submenu = NSMenu()
                for account in others {
                    let item = ActionItem(account.displayName) { Task { await model.play(game, as: account.id) } }
                    item.image = .account(account)
                    playAs.submenu?.addItem(item)
                }
                menu.addItem(playAs)
            }
            menu.addItem(ActionItem("Sign In Again and Play") { Task { await model.play(game, forceSignIn: true) } })
            if GameUpdate.canUpdate(game.install) {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Change Language…", enabled: state.canUpdate) { [weak self] in
                    self?.window?.contentViewController?.presentAsSheet(LanguageSheet(game: game, model: model))
                })
                menu.addItem(ActionItem("Verify Files", enabled: state.canUpdate) { Task { await model.update(game, verify: true) } })
            }
        }
        // Unsupported games too: removing one is the one thing left to do with it.
        if game.isInstalled {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let uninstall = ActionItem("Uninstall…", enabled: model.canUninstall(game)) { [weak self] in
                guard let window = self?.window else { return }
                UninstallAlert.present(game, model: model, in: window)
            }
            if !uninstall.isEnabled {
                let folder = URL(fileURLWithPath: game.install.installPath).lastPathComponent
                uninstall.toolTip = "Another game in “\(folder)” is running or has a download in progress."
            }
            menu.addItem(uninstall)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// "36.6.3 · EU", plus "Intel" for games that need Rosetta. The full
    /// version is in the name's tooltip.
    private static func summary(of game: Game, played: PlayedTime?) -> String {
        var parts: [String] = []
        if let version = game.install.version {
            parts.append(version.split(separator: ".").prefix(3).joined(separator: "."))
        }
        if let region = game.install.region { parts.append(region.uppercased()) }
        if game.install.platform == .windows {
            parts.append("Windows")
            if WindowsTitle.forInstall(game.install)?.isQualified == false { parts.append("Preview") }
        }
        else if game.appURL != nil, !game.runsNatively { parts.append("Intel") }
        if let played { parts.append("\(PlayedTime.text(played.total)) played") }
        return parts.joined(separator: " · ")
    }
}

/// A game being installed (progress), or whose install was interrupted (Resume).
@MainActor
final class InstallableCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("installable")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let downloadDetailsView = DownloadDetailsView()
    private var detail: NSTextField { downloadDetailsView.label }
    private let button = NSButton.rowAction("Try Again…")
    private let downloadButtons = DownloadButtons()
    private let separator = NSBox.separator()
    private let row = NSStackView()
    private var state: InstallableRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSWorkspace.shared.icon(for: .applicationBundle)
        button.target = self
        button.action = #selector(install)
        layOutRow(row, in: self, icon: icon, text: NSStackView(), lines: [name, downloadDetailsView], details: downloadDetailsView,
                  trailing: [button], separator: separator)
        downloadButtons.place(in: row, around: button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: InstallableRowState, model: AppModel, showsSeparator: Bool) {
        self.state = state
        self.model = model
        separator.isHidden = !showsSeparator
        name.stringValue = state.product.displayName
        var detailTooltip: String?
        detail.textColor = .secondaryLabelColor
        // Before the first report: an empty bar.
        var fraction: Double? = 0
        var downloadTooltip: (() -> String)?
        var showsButton = false
        let uid = state.uid
        switch state.phase {
        case .failed(let message):
            fraction = nil
            detail.stringValue = message
            detailTooltip = message
            detail.textColor = .systemRed
            let title = state.download.canResume ? "Resume" : "Try Again…"
            if button.title != title { button.title = title }
            showsButton = true
        case .pausing(let update), .paused(let update):
            let pausing = if case .pausing = state.phase { true } else { false }
            fraction = update?.fraction ?? 0
            detail.stringValue = downloadStatus(update, label: pausing ? "Pausing…" : "Paused")
            downloadTooltip = { downloadDetails(update, bytesPerSecond: nil, status: pausing ? "Pausing…" : "Paused") }
        case .updating(let update):
            fraction = update?.fraction ?? 0
            detail.stringValue = progressDescription(update, waiting: "Preparing…", bytesPerSecond: state.download.bytesPerSecond)
            downloadTooltip = { [weak model] in
                downloadDetails(update, bytesPerSecond: model?.downloadBytesPerSecond(uid: uid), status: "Downloading…")
            }
        default:
            break
        }
        if detail.toolTip != detailTooltip { detail.toolTip = detailTooltip }
        downloadDetailsView.showsError = showsButton
        downloadDetailsView.fraction = fraction
        downloadDetailsView.details = downloadTooltip
        downloadButtons.show(state.download, phase: state.phase, uid: uid, model: model)
        button.isHidden = !showsButton
    }

    /// Resume an install that stopped; one that can't resume starts over
    /// from the install sheet.
    @objc private func install() {
        guard let state, let model, case .failed = state.phase else { return }
        if model.canResumeDownload(uid: state.uid) {
            Task { await model.resumeDownload(uid: state.uid) }
        } else {
            window?.contentViewController?.presentAsSheet(InstallSheet(product: state.product, model: model))
        }
    }
}

/// PROTOTYPE (available games): the heading over the games that can be
/// installed. Clicking it shows or hides them.
@MainActor
final class AvailableHeaderCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("available header")

    private let button = NSButton(title: "", target: nil, action: nil)
    var toggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(count: Int, expanded: Bool) {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let title = NSMutableAttributedString(string: " Available Games", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: "  \(count)", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        button.attributedTitle = title
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        button.contentTintColor = .tertiaryLabelColor
        button.setAccessibilityLabel("Available Games, \(count)")
        button.setAccessibilityValue(expanded ? "expanded" : "collapsed")
    }

    @objc private func clicked() { toggle?() }
}

/// PROTOTYPE (available games): a game that isn't installed. Smaller and
/// quieter than an installed one: its icon (its initial, without one), its
/// name, Install, and its picture fainter than an installed game's.
@MainActor
final class AvailableGameCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("available")

    private let icon = ProductIconView()
    private let name = NSTextField.label(.body)
    private let button = NSButton(title: "Install", target: nil, action: nil)
    private let row = NSStackView()
    private var banner: BannerView?
    var install: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        if #available(macOS 26.0, *) { button.borderShape = .capsule }
        button.target = self
        button.action = #selector(clicked)
        button.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        row.setViews([icon, name, button], in: .leading)
        row.orientation = .horizontal
        row.alignment = .centerY
        // The icon sits in the middle of the installed games' icon column,
        // the name starts where their names do.
        row.setCustomSpacing(20, after: icon)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ product: InstallableProduct) {
        name.stringValue = product.displayName
        icon.letter = String(product.displayName.prefix(1)).uppercased()
        icon.image = GameBanners.shared.file(for: product.uid + ".icon").flatMap(NSImage.init(contentsOf:))
        button.setAccessibilityLabel("Install \(product.displayName)")
        if BannerView.style.isCard, let file = GameBanners.shared.file(for: product.uid) {
            let banner = banner ?? {
                let banner = BannerView()
                banner.strength = 0.75
                banner.translatesAutoresizingMaskIntoConstraints = false
                addSubview(banner, positioned: .below, relativeTo: row)
                NSLayoutConstraint.activate([
                    banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
                    banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
                    banner.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                    banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                ])
                self.banner = banner
                return banner
            }()
            banner.show(picture: file)
            banner.isHidden = false
        } else {
            banner?.isHidden = true
        }
    }

    @objc private func clicked() { install?() }
}

/// A game's icon from the catalog on a rounded tile, as most of them come;
/// some come as a bare emblem, which gets the same tile. Without an icon, the
/// game's initial.
@MainActor
private final class ProductIconView: NSView {
    var letter = "" { didSet { if letter != oldValue { needsDisplay = true } } }
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        guard let image else {
            NSColor.quaternarySystemFill.setFill()
            tile.fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        // The dark blue of Blizzard's own tiles.
        NSColor(srgbRed: 0.11, green: 0.15, blue: 0.26, alpha: 1).setFill()
        tile.fill()
        tile.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        // A bare emblem reaches the picture's edges; keep it off the tile's.
        let bare = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: 1, y: 1) }
            .map { $0.alphaComponent < 0.5 } ?? false
        image.draw(in: bare ? bounds.insetBy(dx: 4, dy: 4) : bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A download's buttons, right of its progress: keep the Mac awake, pause or
/// resume, and cancel.
@MainActor
private final class DownloadButtons: NSObject {
    private let keepAwake = NSButton.downloadKeepAwake()
    private let pauseResume = NSButton.rowIcon("pause.fill", label: "Pause")
    private let cancel = NSButton.rowIcon("xmark", label: "Cancel download")
    private var uid: String?
    private weak var model: AppModel?

    /// Whether `show` would leave any button showing: a row with none
    /// needn't make them.
    static func haveAny(for controls: DownloadControls, phase: AppModel.Phase) -> Bool {
        switch phase {
        case .updating, .pausing, .paused: true
        default: controls.canCancel
        }
    }

    /// Adds the buttons to `row`: keep-awake and pause left of `button`
    /// (they show only while the download runs or is paused), cancel right
    /// of it, after Resume or Try Again when one is showing.
    func place(in row: NSStackView, around button: NSView) {
        row.insert(cancel, after: button)
        row.insert(keepAwake, before: button)
        row.insert(pauseResume, before: button)
    }

    override init() {
        super.init()
        keepAwake.target = self
        keepAwake.action = #selector(toggleKeepAwake)
        pauseResume.target = self
        pauseResume.action = #selector(togglePause)
        cancel.target = self
        cancel.action = #selector(cancelDownload)
        cancel.toolTip = "Stop this download. Downloaded data is kept for next time."
    }

    func show(_ controls: DownloadControls, phase: AppModel.Phase, uid: String, model: AppModel) {
        self.uid = uid
        self.model = model
        var transfers = true
        switch phase {
        case .updating:
            pauseResume.showSymbol("pause.fill", label: "Pause")
            pauseResume.isEnabled = controls.canPause
        case .pausing:
            pauseResume.showSymbol("pause.fill", label: "Pausing…")
            pauseResume.isEnabled = false
        case .paused:
            pauseResume.showSymbol("play.fill", label: "Resume")
            pauseResume.isEnabled = controls.canResume
        default:
            transfers = false
        }
        pauseResume.isHidden = !transfers
        keepAwake.isHidden = !transfers
        keepAwake.showKeepAwake(controls.keepsMacAwake)
        keepAwake.isEnabled = controls.canPause || controls.canResume
        cancel.isHidden = !controls.canCancel
    }

    @objc private func togglePause() {
        guard let uid, let model else { return }
        if model.canPauseDownload(uid: uid) {
            model.pauseDownload(uid: uid)
        } else if model.canResumeDownload(uid: uid) {
            Task { await model.resumeDownload(uid: uid) }
        }
    }

    @objc private func cancelDownload() {
        guard let uid, let model else { return }
        model.cancelDownload(uid: uid)
    }

    @objc private func toggleKeepAwake() {
        guard let uid, let model else { return }
        model.toggleKeepAwake(uid: uid)
        keepAwake.showKeepAwake(model.keepsMacAwake(uid: uid))
    }
}

/// A library row: a 48-point icon, a column of text (`lines`, in `text`)
/// that takes the free width, and whatever of `trailing` is showing on the
/// right. `details` (the progress bar's view) spans the text column.
/// `separator` is the hairline above the row, from the text's leading edge.
/// A cell adds the views it makes later to `row` and `text` itself.
@MainActor
private func layOutRow(_ row: NSStackView, in cell: NSView, icon: NSView, text: NSStackView, lines: [NSView],
                       details: NSView, trailing: [NSView], separator: NSView) {
    (icon as? NSImageView)?.imageScaling = .scaleProportionallyUpOrDown
    text.setViews(lines, in: .leading)
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.detachesHiddenViews = true
    text.setContentHuggingPriority(.init(1), for: .horizontal)
    // Keep the lines together rather than spread over the icon's height.
    text.setHuggingPriority(.defaultHigh, for: .vertical)
    row.setViews([icon, text] + trailing, in: .leading)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 8
    row.setCustomSpacing(12, after: icon)
    row.setCustomSpacing(12, after: text)
    row.detachesHiddenViews = true
    // Above the table's own hold on a row's current height (500), so a row
    // gets shorter again when its progress bar or error goes away. Below the
    // labels' resistance to being squeezed (750), so it never clips them.
    row.setHuggingPriority(.init(600), for: .vertical)
    for view in [row, separator] {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
    }
    // Reserve padding outside the stack so automatic table row heights
    // include it even when the edition picker or download adds lines.
    NSLayoutConstraint.activate(lines.map { $0.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor) } + [
        details.widthAnchor.constraint(equalTo: text.widthAnchor),
        row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        row.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
        row.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -10),
        icon.widthAnchor.constraint(equalToConstant: 48),
        icon.heightAnchor.constraint(equalToConstant: 48),
        separator.topAnchor.constraint(equalTo: cell.topAnchor),
        separator.leadingAnchor.constraint(equalTo: text.leadingAnchor),
        separator.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
    ])
}

/// "42% · 1.2 GB of 3 GB", or `waiting` before the first progress report.
/// PROTOTYPE: with a rate, "… · 43 MB/s · 5 min left".
private func progressDescription(_ progress: UpdateProgress?, waiting: String, bytesPerSecond: Double? = nil) -> String {
    guard let progress else { return waiting }
    let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
    let percent = "\(Int(progress.fraction * 100))%"
    guard let bytesPerSecond, bytesPerSecond > 0, progress.totalBytes > progress.completedBytes else {
        return "\(percent) · \(done) of \(total)"
    }
    // The line has to fit beside three buttons in a narrow window: the
    // amount done is left to the tooltip.
    let rate = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
    let minutes = max(1, Int((Double(progress.totalBytes - progress.completedBytes) / bytesPerSecond / 60).rounded()))
    let left = minutes < 90 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    return "\(percent) of \(total) · \(rate)/s · \(left) left"
}

private func downloadStatus(_ progress: UpdateProgress?, label: String) -> String {
    guard let progress else { return label }
    return "\(label) · \(progressDescription(progress, waiting: label))"
}
