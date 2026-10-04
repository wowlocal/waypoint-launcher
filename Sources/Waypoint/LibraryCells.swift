import AppKit
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

struct InstallableRowState {
    var product: InstallableProduct
    var phase: AppModel.Phase
}

/// An installed game: icon, name, version and region, an update or progress
/// line, and Play or Update on the right. Right-click for the other ways to
/// play.
@MainActor
final class GameCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("game")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let subtitle = NSTextField.label(.caption1, color: .secondaryLabelColor)
    private let failure = NSTextField.label(.caption1, color: .systemRed)
    private let progress = NSProgressIndicator.bar()
    private let progressText = NSTextField.label(.caption2, color: .secondaryLabelColor, monospacedDigits: true)
    private let note = NSTextField.label(.caption1, color: .systemOrange)
    private let status = NSTextField.label(.callout, color: .secondaryLabelColor)
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
        button.bezelColor = .controlAccentColor
        let text = NSStackView.column([name, subtitle, failure, progress, progressText, note])
        layOutRow(in: self, icon: icon, text: text, trailing: [status, spinner, button])
        let barWidth = progress.widthAnchor.constraint(equalToConstant: 220)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([barWidth, progress.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: GameRowState, model: AppModel) {
        self.state = state
        self.model = model
        let game = state.game
        if icon.image == nil || iconPath != game.appURL?.path {
            iconPath = game.appURL?.path
            icon.image = iconPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? .symbol("questionmark.app", pointSize: 30)
        }
        name.stringValue = game.displayName
        subtitle.stringValue = Self.subtitle(of: game)

        failure.isHidden = true
        progress.isHidden = true
        progressText.isHidden = true
        note.isHidden = true
        if case .failed(let message) = state.phase {
            failure.stringValue = message
            failure.toolTip = message
            failure.isHidden = false
        }
        if case .updating(let update) = state.phase {
            progress.doubleValue = update?.fraction ?? 0
            progressText.stringValue = progressDescription(update, waiting: "Checking files…")
            progress.isHidden = false
            progressText.isHidden = false
        } else if let update = state.update {
            note.stringValue = GameUpdater.canUpdate(game.family)
                ? "Update available: \(update.latest.name)"
                : "Update \(update.latest.name) available in Battle.net"
            note.isHidden = false
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
                show(status: "Updating…")
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

    private static func subtitle(of game: Game) -> String {
        var parts: [String] = []
        if let version = game.install.version { parts.append(version) }
        if let region = game.install.region { parts.append(region.uppercased()) }
        if game.appURL != nil { parts.append(game.runsNatively ? "Apple silicon" : "Intel only") }
        return parts.joined(separator: " · ")
    }
}

/// A game that isn't installed yet: Install…, then progress.
@MainActor
final class InstallableCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("installable")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let progress = NSProgressIndicator.bar()
    private let progressText = NSTextField.label(.caption2, color: .secondaryLabelColor, monospacedDigits: true)
    private let notInstalled = NSTextField.label(.caption1, color: .secondaryLabelColor)
    private let failure = NSTextField.label(.caption1, color: .systemRed)
    private let status = NSTextField.label(.callout, color: .secondaryLabelColor)
    private let button = NSButton(title: "Install…", target: nil, action: nil)
    private var state: InstallableRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = .symbol("arrow.down.app", pointSize: 30)
        icon.contentTintColor = .secondaryLabelColor
        notInstalled.stringValue = "Not installed"
        status.stringValue = "Installing…"
        button.target = self
        button.action = #selector(install)
        let text = NSStackView.column([name, progress, progressText, notInstalled, failure])
        layOutRow(in: self, icon: icon, text: text, trailing: [status, button])
        let barWidth = progress.widthAnchor.constraint(equalToConstant: 220)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([barWidth, progress.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: InstallableRowState, model: AppModel) {
        self.state = state
        self.model = model
        name.stringValue = state.product.displayName
        progress.isHidden = true
        progressText.isHidden = true
        notInstalled.isHidden = false
        failure.isHidden = true
        switch state.phase {
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            progressText.stringValue = progressDescription(update, waiting: "Preparing…")
            progress.isHidden = false
            progressText.isHidden = false
            notInstalled.isHidden = true
        case .failed(let message):
            failure.stringValue = message
            failure.toolTip = message
            failure.isHidden = false
        default:
            break
        }
        let installing = if case .updating = state.phase { true } else { false }
        status.isHidden = !installing
        button.isHidden = installing
    }

    @objc private func install() {
        guard let state, let model else { return }
        window?.contentViewController?.presentAsSheet(InstallSheet(product: state.product, model: model))
    }
}

/// "Available to install", above the games that aren't installed yet.
@MainActor
final class HeaderCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("header")

    let title = NSTextField.label(.subheadline, color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = .systemFont(ofSize: title.font?.pointSize ?? 11, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A library row: a 40-point icon, a column of text that takes the free
/// width, and whatever of `trailing` is showing on the right.
@MainActor
private func layOutRow(in cell: NSView, icon: NSImageView, text: NSStackView, trailing: [NSView]) {
    icon.imageScaling = .scaleProportionallyUpOrDown
    text.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [icon, text] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 12
    row.detachesHiddenViews = true
    row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    NSLayoutConstraint.activate([
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
