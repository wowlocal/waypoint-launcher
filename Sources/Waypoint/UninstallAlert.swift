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
    private var sharedTask: Task<Void, Never>?
    /// What goes to the Trash; nil while it's being measured.
    private var trashBytes: UInt64?
    /// In a folder shared with other games, what deleting this one's game
    /// data frees: measured once, while the sheet is open.
    private var shared: SharedSize = .none
    private enum SharedSize { case none, measuring, measured(UInt64), unknown }

    /// Measurements by game and by what's installed in its folder (its
    /// `.build.info`): opening the sheet again doesn't redo seconds of work.
    private static var measuredShared: [String: UInt64] = [:]

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
        if plan.sharesStorage { measureShared() }
        refreshSize()
        // The game starting (or an update) meanwhile disables Uninstall.
        observeChanges { [weak self] in self?.renderButton() }
        alert.beginSheetModal(for: window) { [self] response in
            sizeTask?.cancel()
            sharedTask?.cancel()
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
        // The spinner after the text: the text stays put when it goes.
        let sizeRow = NSStackView(views: [sizeText, sizeSpinner])
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
        // Nothing moves once sizes come in: the line is as tall as the
        // tallest text it can show, at the largest sizes. The note is one
        // line whichever way the checkbox is.
        let largest: UInt64 = 999_900_000_000
        let texts = [sizeDescription(trash: largest, shared: .none), sizeDescription(trash: largest, shared: .measuring),
                     sizeDescription(trash: largest, shared: .measured(largest)), sizeDescription(trash: largest, shared: .unknown)]
        let height = texts.map { text -> CGFloat in
            sizeText.stringValue = text
            return sizeText.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 24, height: 10_000)).height ?? 0
        }.max() ?? 0
        sizeText.heightAnchor.constraint(equalToConstant: height).isActive = true
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

    /// What goes to the Trash, measured again whenever the checkbox
    /// changes it. Under a second; the game data's share takes longer.
    private func refreshSize() {
        sizeTask?.cancel()
        trashBytes = nil
        renderSize()
        let items = plan.trashed
        sizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = GameUninstaller.allocatedSize(of: items)
            guard !Task.isCancelled else { return }
            await self?.showTrash(bytes)
        }
    }

    /// The game data only this game uses, in a folder it shares: deleted
    /// rather than trashed, and worked out from every version's file
    /// tables (seconds). Uninstall stays available meanwhile.
    private func measureShared() {
        let uninstaller = model.uninstaller(for: game, keepingUserFiles: true)
        let buildInfo = plan.root.appendingPathComponent(".build.info"), id = game.id
        shared = .measuring
        sharedTask = Task.detached(priority: .userInitiated) { [weak self] in
            let key = "\(id)\n" + ((try? String(contentsOf: buildInfo, encoding: .utf8)) ?? "")
            if let known = await Self.measuredShared[key] {
                await self?.showShared(.measured(known))
                return
            }
            let bytes = try? await uninstaller.sharedStorageSavings()
            // Kept even if the sheet closed meanwhile: reopening it is instant.
            if let bytes { await MainActor.run { Self.measuredShared[key] = bytes } }
            guard !Task.isCancelled else { return }
            await self?.showShared(bytes.map { .measured($0) } ?? .unknown)
        }
    }

    private func showTrash(_ bytes: UInt64) {
        trashBytes = bytes
        renderSize()
    }

    private func showShared(_ size: SharedSize) {
        shared = size
        renderSize()
    }

    private func renderSize() {
        let measuring = if case .measuring = shared { true } else { false }
        let busy = trashBytes == nil || measuring
        sizeSpinner.isHidden = !busy
        if busy { sizeSpinner.startAnimation(nil) } else { sizeSpinner.stopAnimation(nil) }
        sizeText.stringValue = trashBytes.map { sizeDescription(trash: $0, shared: shared) } ?? "Calculating size…"
    }

    /// "Frees 5.2 GB once you empty the Trash." In a folder shared with
    /// other games, the game data deleted there counts too (it's freed
    /// sooner, but the total is there once the Trash is emptied). While
    /// that's being worked out, what's known so far, "at least"; and "at
    /// least" the Trash part if it can't be. One line each, so the sheet
    /// stays as it is when the size comes in.
    private func sizeDescription(trash: UInt64, shared: SharedSize) -> String {
        func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        switch shared {
        case .none, .measured(0):
            return trash > 0 ? "Frees \(size(trash)) once you empty the Trash." : ""
        case .measuring:
            return trash > 0 ? "Frees at least \(size(trash))…" : "Calculating size…"
        case .measured(let data):
            return trash > 0 ? "Frees \(size(trash + data)) once you empty the Trash." : "Frees \(size(data))."
        case .unknown:
            return trash > 0 ? "Frees at least \(size(trash)) once you empty the Trash." : ""
        }
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
