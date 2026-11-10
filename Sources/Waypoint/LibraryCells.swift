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
}

extension GameRowState {
    @MainActor init(_ game: Game, model: AppModel) {
        self.init(game: game, phase: model.phase(of: game), isRunning: model.isRunning(game),
                  update: model.availableUpdate(for: game), canPlay: model.canPlay(game),
                  canUpdate: model.canUpdate(game), showsEdition: game.install.productCode == "hero" &&
                    (WindowsHeroes.isAvailable || model.heroesEdition(.windows) != nil),
                  download: DownloadControls(uid: game.id, model: model))
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
}

extension DownloadControls {
    @MainActor init(uid: String, model: AppModel) {
        self.init(canPause: model.canPauseDownload(uid: uid), canResume: model.canResumeDownload(uid: uid),
                  canCancel: model.canCancelDownload(uid: uid), keepsMacAwake: model.keepsMacAwake(uid: uid))
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
    private var progress: NSProgressIndicator { downloadDetailsView.progress }
    private var detail: NSTextField { downloadDetailsView.label }
    private let statusDot = NSImageView(image: .symbol("circle.fill", pointSize: 7) ?? NSImage())
    private let status = NSTextField.label(.body, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator.spinner()
    private let button = NSButton.rowAction("Play")
    private let downloadButtons = DownloadButtons()
    private let moreButton = NSButton.rowIcon("ellipsis", label: "More")
    private let separator = NSBox.separator()
    private let edition = NSPopUpButton()
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
        statusDot.contentTintColor = .systemGreen
        statusDot.setAccessibilityElement(false)
        edition.addItems(withTitles: ["Windows (recommended)", "macOS"])
        edition.menu?.autoenablesItems = false
        edition.controlSize = .small
        edition.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        edition.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        edition.cell?.lineBreakMode = .byTruncatingTail
        edition.target = self
        edition.action = #selector(changeEdition)
        let row = layOutRow(in: self, icon: icon, text: [name, edition, downloadDetailsView], details: downloadDetailsView,
                            trailing: [statusDot, status, spinner] + downloadButtons.transferViews
                                + [button, downloadButtons.cancel, moreButton],
                            separator: separator)
        row.setCustomSpacing(5, after: statusDot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: GameRowState, model: AppModel, showsSeparator: Bool) {
        self.state = state
        self.model = model
        separator.isHidden = !showsSeparator
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
        name.stringValue = game.displayName
        edition.isHidden = !state.showsEdition
        edition.item(at: 0)?.title = WindowsHeroes.isAvailable ? "Windows (recommended)" : "Windows"
        edition.item(at: 0)?.isEnabled = WindowsHeroes.isAvailable
        edition.selectItem(at: game.install.platform == .windows ? 0 : 1)
        let isUninstalling = if case .uninstalling = state.phase { true } else { false }
        edition.isEnabled = !state.isRunning && !model.isSigningIn && state.phase != .launching && !isUninstalling
        let versionTooltip = game.install.version.map { "Version \($0)" }
        if name.toolTip != versionTooltip { name.toolTip = versionTooltip }

        var showsProgress = false
        var showsError = false
        var downloadTooltip: (() -> String)?
        var detailTooltip: String?
        detail.textColor = .secondaryLabelColor
        switch state.phase {
        case .preparingWindows(let update):
            if let update {
                progress.doubleValue = update.fraction
                showsProgress = true
                detail.stringValue = "Windows components: " + progressDescription(update, waiting: "Downloading…")
            } else {
                detail.stringValue = "Preparing Windows version…"
            }
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            showsProgress = true
            detail.stringValue = progressDescription(update, waiting: "Checking files…")
            downloadTooltip = { [weak model] in
                downloadDetails(update, bytesPerSecond: model?.downloadBytesPerSecond(uid: game.id), status: "Downloading…")
            }
        case .pausing(let update), .paused(let update):
            progress.doubleValue = update?.fraction ?? 0
            showsProgress = true
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
                detail.stringValue = Self.summary(of: game)
            }
        }

        if detail.toolTip != detailTooltip { detail.toolTip = detailTooltip }
        downloadDetailsView.showsError = showsError
        progress.isHidden = !showsProgress
        downloadDetailsView.details = downloadTooltip
        downloadButtons.show(state.download, phase: state.phase, uid: game.id, model: model)
        status.isHidden = true
        statusDot.isHidden = true
        spinner.isHidden = true
        spinner.stopAnimation(nil)
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
            show(status: "Running")
            statusDot.isHidden = false
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
        guard let model, let state, state.game.install.productCode == "hero" else { return }
        let platform: InstallPlatform = edition.indexOfSelectedItem == 0 ? .windows : .macOS
        guard platform == .macOS || WindowsHeroes.isAvailable else { return }
        if model.heroesEdition(platform)?.isInstalled == true {
            model.selectHeroesEdition(platform)
        } else if let product = InstallableProduct.forProduct("hero") {
            edition.selectItem(at: state.game.install.platform == .windows ? 0 : 1)
            window?.contentViewController?.presentAsSheet(InstallSheet(product: product, model: model, platform: platform))
        }
    }

    private func show(status text: String) {
        status.stringValue = text
        status.isHidden = false
    }

    private func showSpinner(_ help: String) {
        spinner.toolTip = help
        spinner.isHidden = false
        spinner.startAnimation(nil)
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
    private static func summary(of game: Game) -> String {
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
    private var progress: NSProgressIndicator { downloadDetailsView.progress }
    private var detail: NSTextField { downloadDetailsView.label }
    private let button = NSButton.rowAction("Try Again…")
    private let downloadButtons = DownloadButtons()
    private let separator = NSBox.separator()
    private var state: InstallableRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSWorkspace.shared.icon(for: .applicationBundle)
        button.target = self
        button.action = #selector(install)
        layOutRow(in: self, icon: icon, text: [name, downloadDetailsView], details: downloadDetailsView,
                  trailing: downloadButtons.transferViews + [button, downloadButtons.cancel], separator: separator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: InstallableRowState, model: AppModel, showsSeparator: Bool) {
        self.state = state
        self.model = model
        separator.isHidden = !showsSeparator
        name.stringValue = state.product.displayName
        var detailTooltip: String?
        detail.textColor = .secondaryLabelColor
        progress.isHidden = false
        var downloadTooltip: (() -> String)?
        var showsButton = false
        let uid = state.uid
        switch state.phase {
        case .failed(let message):
            progress.isHidden = true
            detail.stringValue = message
            detailTooltip = message
            detail.textColor = .systemRed
            let title = state.download.canResume ? "Resume" : "Try Again…"
            if button.title != title { button.title = title }
            showsButton = true
        case .pausing(let update), .paused(let update):
            let pausing = if case .pausing = state.phase { true } else { false }
            progress.doubleValue = update?.fraction ?? 0
            detail.stringValue = downloadStatus(update, label: pausing ? "Pausing…" : "Paused")
            downloadTooltip = { downloadDetails(update, bytesPerSecond: nil, status: pausing ? "Pausing…" : "Paused") }
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            detail.stringValue = progressDescription(update, waiting: "Preparing…")
            downloadTooltip = { [weak model] in
                downloadDetails(update, bytesPerSecond: model?.downloadBytesPerSecond(uid: uid), status: "Downloading…")
            }
        default:
            break
        }
        if detail.toolTip != detailTooltip { detail.toolTip = detailTooltip }
        downloadDetailsView.showsError = showsButton
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

/// A download's buttons, right of its progress: keep the Mac awake, pause or
/// resume, and cancel.
@MainActor
private final class DownloadButtons: NSObject {
    private let keepAwake = NSButton.downloadKeepAwake()
    private let pauseResume = NSButton.rowIcon("pause.fill", label: "Pause")
    /// Goes last in the row, after Resume or Try Again when one is showing.
    let cancel = NSButton.rowIcon("xmark", label: "Cancel download")
    private var uid: String?
    private weak var model: AppModel?

    /// Showing only while the download runs or is paused.
    var transferViews: [NSView] { [keepAwake, pauseResume] }

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

/// A library row: a 48-point icon, a column of text that takes the free
/// width, and whatever of `trailing` is showing on the right. `details` (the
/// progress bar's view) spans the text column. `separator` is the hairline
/// above the row, from the text's leading edge.
@MainActor
@discardableResult
private func layOutRow(in cell: NSView, icon: NSView, text views: [NSView], details: NSView, trailing: [NSView],
                       separator: NSView) -> NSStackView {
    (icon as? NSImageView)?.imageScaling = .scaleProportionallyUpOrDown
    let text = NSStackView.column(views, spacing: 3)
    text.setContentHuggingPriority(.init(1), for: .horizontal)
    // Keep the lines together rather than spread over the icon's height.
    text.setHuggingPriority(.defaultHigh, for: .vertical)
    let row = NSStackView(views: [icon, text] + trailing)
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
    NSLayoutConstraint.activate(views.map { $0.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor) } + [
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
    return row
}

/// "42% · 1.2 GB of 3 GB", or `waiting` before the first progress report.
private func progressDescription(_ progress: UpdateProgress?, waiting: String) -> String {
    guard let progress else { return waiting }
    let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
    return "\(Int(progress.fraction * 100))% · \(done) of \(total)"
}

private func downloadStatus(_ progress: UpdateProgress?, label: String) -> String {
    guard let progress else { return label }
    return "\(label) · \(progressDescription(progress, waiting: label))"
}
