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
}

extension GameRowState {
    @MainActor init(_ game: Game, model: AppModel) {
        self.init(game: game, phase: model.phase(of: game), isRunning: model.running.contains(game.id),
                  update: model.availableUpdate(for: game), canPlay: model.canPlay(game),
                  canUpdate: model.canUpdate(game))
    }
}

/// A game being installed, or whose install failed.
struct InstallableRowState {
    var product: InstallableProduct
    var phase: AppModel.Phase
}

/// An installed game: icon, name, one quiet line of status, and Play or
/// Update on the right. Right-click for the other ways to play.
@MainActor
final class GameCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("game")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let progress = NSProgressIndicator.bar()
    private let detail = NSTextField.label(.subheadline, color: .secondaryLabelColor, monospacedDigits: true)
    private let status = NSTextField.label(.body, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator.spinner()
    private let button = NSButton(title: "Play", target: nil, action: nil)
    private var iconPath: String?
    private var state: GameRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        button.target = self
        button.action = #selector(primaryAction)
        layOutRow(in: self, icon: icon, text: [name, progress, detail], trailing: [status, spinner, button])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: GameRowState, model: AppModel) {
        self.state = state
        self.model = model
        let game = state.game
        if icon.image == nil || iconPath != game.appURL?.path {
            iconPath = game.appURL?.path
            icon.image = iconPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        }
        name.stringValue = game.displayName
        toolTip = game.install.version.map { "Version \($0)" }

        progress.isHidden = true
        detail.textColor = .secondaryLabelColor
        detail.toolTip = nil
        switch state.phase {
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            progress.isHidden = false
            detail.stringValue = progressDescription(update, waiting: "Checking files…")
        case .failed(let message):
            detail.stringValue = message
            detail.toolTip = message
            detail.textColor = .systemRed
        default:
            if state.update != nil, !state.isRunning {
                detail.stringValue = GameUpdater.canUpdate(game.family) ? "Update available" : "Update available in Battle.net"
                detail.textColor = .systemOrange
            } else {
                detail.stringValue = Self.summary(of: game)
            }
        }

        status.isHidden = true
        spinner.isHidden = true
        spinner.stopAnimation(nil)
        button.isHidden = true
        if state.isRunning {
            show(status: "Running")
        } else if !game.isSupported {
            show(status: game.appURL == nil ? "Not installed" : (game.runsNatively ? "Unsupported" : "Needs Rosetta"))
        } else {
            switch state.phase {
            case .signingIn:
                showSpinner("Signing in…")
            case .launching:
                showSpinner("Starting…")
            case .updating:
                break
            case .idle, .failed:
                let updates = state.update != nil && GameUpdater.canUpdate(game.family)
                button.title = updates ? "Update" : "Play"
                button.isEnabled = updates ? state.canUpdate : state.canPlay
                button.isHidden = false
            }
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

    @objc private func primaryAction() {
        guard let state, let model else { return }
        let game = state.game
        if state.update != nil, GameUpdater.canUpdate(game.family) {
            Task { await model.update(game) }
        } else {
            Task { await model.play(game) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state, let model, state.game.isSupported, !state.isRunning else { return nil }
        switch state.phase {
        case .idle, .failed: break
        default: return nil
        }
        let game = state.game
        let menu = NSMenu()
        if model.availableUpdate(for: game) != nil {
            menu.addItem(ActionItem("Play Without Updating") { Task { await model.play(game) } })
        }
        menu.addItem(ActionItem("Sign In Again and Play") { Task { await model.play(game, forceSignIn: true) } })
        if GameUpdater.canUpdate(game.family) {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Verify Files") { Task { await model.update(game, verify: true) } })
        }
        return menu
    }

    /// "36.6.3 · EU", plus "Intel" for games that need Rosetta. The full
    /// version is in the row's tooltip.
    private static func summary(of game: Game) -> String {
        var parts: [String] = []
        if let version = game.install.version {
            parts.append(version.split(separator: ".").prefix(3).joined(separator: "."))
        }
        if let region = game.install.region { parts.append(region.uppercased()) }
        if game.appURL != nil, !game.runsNatively { parts.append("Intel") }
        return parts.joined(separator: " · ")
    }
}

/// A game being installed (progress), or whose install failed (Try Again).
@MainActor
final class InstallableCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("installable")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let progress = NSProgressIndicator.bar()
    private let detail = NSTextField.label(.subheadline, color: .secondaryLabelColor, monospacedDigits: true)
    private let button = NSButton(title: "Try Again…", target: nil, action: nil)
    private var state: InstallableRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSWorkspace.shared.icon(for: .applicationBundle)
        button.target = self
        button.action = #selector(install)
        layOutRow(in: self, icon: icon, text: [name, progress, detail], trailing: [button])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: InstallableRowState, model: AppModel) {
        self.state = state
        self.model = model
        name.stringValue = state.product.displayName
        if case .failed(let message) = state.phase {
            progress.isHidden = true
            detail.stringValue = message
            detail.toolTip = message
            detail.textColor = .systemRed
            button.isHidden = false
        } else {
            let update: UpdateProgress? = if case .updating(let update) = state.phase { update } else { nil }
            progress.doubleValue = update?.fraction ?? 0
            progress.isHidden = false
            detail.stringValue = progressDescription(update, waiting: "Preparing…")
            detail.toolTip = nil
            detail.textColor = .secondaryLabelColor
            button.isHidden = true
        }
    }

    @objc private func install() {
        guard let state, let model else { return }
        window?.contentViewController?.presentAsSheet(InstallSheet(product: state.product, model: model))
    }
}

/// A library row: a 40-point icon, a column of text that takes the free
/// width, and whatever of `trailing` is showing on the right.
@MainActor
private func layOutRow(in cell: NSView, icon: NSImageView, text views: [NSView], trailing: [NSView]) {
    icon.imageScaling = .scaleProportionallyUpOrDown
    let text = NSStackView.column(views, spacing: 3)
    text.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [icon, text] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 10
    row.detachesHiddenViews = true
    row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    let barWidth = views.compactMap { $0 as? NSProgressIndicator }.map { bar in
        let width = bar.widthAnchor.constraint(equalToConstant: 200)
        width.priority = .defaultHigh
        return [width, bar.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor)]
    }
    NSLayoutConstraint.activate(barWidth.flatMap { $0 } + [
        row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        row.topAnchor.constraint(equalTo: cell.topAnchor),
        row.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        icon.widthAnchor.constraint(equalToConstant: 40),
        icon.heightAnchor.constraint(equalToConstant: 40),
    ])
}

/// "42% · 1.2 GB of 3 GB", or `waiting` before the first progress report.
private func progressDescription(_ progress: UpdateProgress?, waiting: String) -> String {
    guard let progress else { return waiting }
    let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
    return "\(Int(progress.fraction * 100))% · \(done) of \(total)"
}
