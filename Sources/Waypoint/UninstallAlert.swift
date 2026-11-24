import AppKit
import WaypointCore

/// Asks before uninstalling a game: what goes to the Trash and how much
/// space that is, and whether the player's own files go too: a WoW
/// version's add-ons, settings and screenshots, or a Windows game's saved
/// games and settings. They stay unless asked, as Battle.net leaves them.
///
/// Every text is a sentence or two in the player's words: games by name,
/// and no folder the player never opened (`_classic_era_`, `Data`).
@MainActor
final class UninstallAlert: NSObject {
    private let game: Game
    private let model: AppModel
    private var plan: UninstallPlan
    private let alert = NSAlert()
    private let sizeSpinner = NSProgressIndicator.spinner()
    private let sizeText = NSTextField(wrappingLabelWithString: "")
    private let removesUserFiles = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let keptNote = NSTextField(wrappingLabelWithString: "")
    private var sizeTask: Task<Void, Never>?

    /// Shows the confirmation as a sheet on `window`; uninstalls if confirmed.
    static func present(_ game: Game, model: AppModel, in window: NSWindow) {
        do {
            let plan = try model.uninstaller(for: game, keepingUserFiles: true).plan()
            UninstallAlert(game: game, model: model, plan: plan).begin(in: window)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Waypoint can’t uninstall \(game.displayName)"
            alert.informativeText = errorMessage(error)
            alert.beginSheetModal(for: window)
        }
    }

    private init(game: Game, model: AppModel, plan: UninstallPlan) {
        self.game = game
        self.model = model
        self.plan = plan
        super.init()
    }

    private func begin(in window: NSWindow) {
        alert.messageText = "Uninstall \(game.displayName)?"
        // Written once, from what keeping the user's files does: true either way.
        alert.informativeText = summary
        if let icon = Self.icon(for: game) { alert.icon = icon }
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = accessory()
        refreshSize()
        // The game starting (or an update) meanwhile disables Uninstall.
        observeChanges { [weak self] in self?.renderButton() }
        alert.beginSheetModal(for: window) { [self] response in
            sizeTask?.cancel()
            guard response == .alertFirstButtonReturn else { return }
            let (game, model, keeping) = (game, model, removesUserFiles.state == .off)
            Task { await model.uninstall(game, keepingUserFiles: keeping) }
        }
    }

    private var summary: String {
        let folder = plan.root.lastPathComponent
        if plan.removesFolder { return "The “\(folder)” folder will be moved to the Trash." }
        guard plan.sharesStorage else { return "Its files in “\(folder)” will be moved to the Trash." }
        let others = model.games.filter {
            $0.id != game.id && URL(fileURLWithPath: $0.install.installPath).standardizedFileURL == plan.root
        }
        // Named while that stays short: a folder can hold many WoW versions.
        let unaffected = switch others.count {
        case 1: "\(others[0].displayName) isn’t affected."
        case 2: "\(ListFormatter.localizedString(byJoining: others.map(\.displayName))) aren’t affected."
        default: "Other games in “\(folder)” aren’t affected."
        }
        // What only this game used of the data they share is deleted
        // (`GameUninstaller.cleanSharedStorage`): it can't go to the Trash.
        return "Its game data will be deleted and the rest moved to the Trash. \(unaffected)"
    }

    private func accessory() -> NSView {
        removesUserFiles.title = plan.windowsHome != nil ? "Also remove saved games and settings"
            : "Also remove add-ons, settings and screenshots"
        let width = max(320, removesUserFiles.fittingSize.width)
        for label in [sizeText, keptNote] {
            label.preferredMaxLayoutWidth = width - 24
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let sizeRow = NSStackView(views: [sizeSpinner, sizeText])
        sizeRow.alignment = .firstBaseline
        sizeRow.detachesHiddenViews = true
        var views: [NSView] = [sizeRow]
        if plan.hasUserFiles {
            removesUserFiles.target = self
            removesUserFiles.action = #selector(toggleUserFiles)
            views += [removesUserFiles, keptNote]
        }
        let stack = NSStackView.column(views, spacing: 8)
        // The checkbox is only arranged when this game has user files.
        if plan.hasUserFiles { stack.setCustomSpacing(4, after: removesUserFiles) }
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        // The alert doesn't grow later: sized for the largest size. The
        // note is one line whichever way the checkbox is.
        sizeText.stringValue = sizeDescription(999_900_000_000)
        renderKeptNote()
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        return stack
    }

    @objc private func toggleUserFiles() {
        if let plan = try? model.uninstaller(for: game, keepingUserFiles: removesUserFiles.state == .off).plan() {
            self.plan = plan
        }
        renderKeptNote()
        refreshSize()
    }

    /// What the checkbox does, either way. The checkbox names the files.
    private func renderKeptNote() {
        keptNote.stringValue = plan.keepsUserFiles ? "They stay for when you reinstall." : "They go to the Trash too."
    }

    private func renderButton() {
        alert.buttons.first?.isEnabled = model.canUninstall(game)
    }

    private func refreshSize() {
        sizeTask?.cancel()
        sizeSpinner.isHidden = false
        sizeSpinner.startAnimation(nil)
        sizeText.stringValue = "Calculating size…"
        let items = plan.trashed
        sizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = GameUninstaller.allocatedSize(of: items)
            guard !Task.isCancelled else { return }
            await self?.show(size: bytes)
        }
    }

    private func show(size bytes: UInt64) {
        sizeSpinner.stopAnimation(nil)
        sizeSpinner.isHidden = true
        sizeText.stringValue = sizeDescription(bytes)
    }

    /// "Frees 5.2 GB once you empty the Trash." In a folder shared with
    /// other games it's "Also frees": the game data deleted there is
    /// freed too, and how much that is isn't known until it's done. Nothing
    /// when nothing goes to the Trash.
    private func sizeDescription(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(plan.sharesStorage ? "Also frees" : "Frees") \(size) once you empty the Trash."
    }

    /// The icon the game's row shows.
    private static func icon(for game: Game) -> NSImage? {
        if let app = game.appURL { return NSWorkspace.shared.icon(forFile: app.path) }
        guard let title = WindowsTitle.forInstall(game.install),
              let data = WindowsExecutableIcon.data(at: URL(fileURLWithPath: game.install.installPath).appendingPathComponent(title.executablePath))
        else { return nil }
        if let bundle = try? SystemGameIcon.bundle(for: data) { return NSWorkspace.shared.icon(forFile: bundle.path) }
        return NSImage(data: data)
    }
}
