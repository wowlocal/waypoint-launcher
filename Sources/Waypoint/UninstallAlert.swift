import AppKit
import WaypointCore

/// Asks before uninstalling a game: what goes to the Trash and how much
/// space that is, and whether the player's own files go too: a WoW
/// version's add-ons, settings and screenshots, or a Windows game's saved
/// games and settings. They stay unless asked, as Battle.net leaves them.
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
        let names = ListFormatter.localizedString(byJoining: others.map(\.displayName))
        return "Its own files will be moved to the Trash. Data it shares with \(names.isEmpty ? "the other games in “\(folder)”" : names) stays; the rest is deleted to free up space."
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
        // The alert doesn't grow later: sized for the longest texts.
        sizeText.stringValue = sizeDescription(999_900_000_000)
        keptNote.stringValue = keptDescription
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        renderKeptNote()
        return stack
    }

    @objc private func toggleUserFiles() {
        if let plan = try? model.uninstaller(for: game, keepingUserFiles: removesUserFiles.state == .off).plan() {
            self.plan = plan
        }
        renderKeptNote()
        refreshSize()
    }

    /// "Interface, WTF and Screenshots stay in “_retail_”, so…"
    private var keptDescription: String {
        guard plan.windowsHome == nil else { return "Saved games and settings stay, so reinstalling picks them up." }
        let names = plan.userFiles.map { URL(fileURLWithPath: $0).lastPathComponent }
        let folder = plan.userFiles.first.map { String($0.prefix { $0 != "/" }) } ?? ""
        return "\(ListFormatter.localizedString(byJoining: names)) stay in “\(folder)”, so reinstalling picks them up."
    }

    private func renderKeptNote() {
        keptNote.stringValue = plan.keepsUserFiles ? keptDescription : "They go to the Trash with the game."
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

    private func sizeDescription(_ bytes: UInt64) -> String {
        "Moves \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) to the Trash. Empty the Trash to get the space back."
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
