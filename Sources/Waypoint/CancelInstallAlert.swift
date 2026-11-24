import AppKit
import WaypointCore

/// Asks what becomes of an install that never finished when it's cancelled:
/// what it downloaded stays for the next install to continue from, or goes.
/// It goes to the Trash, except in a folder shared with other games, where
/// it's deleted (see `UninstallPlan.unfinishedStorage`). Only such an
/// install is asked about (see `AppModel.unfinishedInstall`); cancelling an
/// update keeps its data.
@MainActor
final class CancelInstallAlert {
    private let install: AppModel.UnfinishedInstall
    private let alert = NSAlert()
    private var sizeTask: Task<Void, Never>?

    static func present(_ install: AppModel.UnfinishedInstall, uid: String, model: AppModel, in window: NSWindow) {
        CancelInstallAlert(install).begin(uid: uid, model: model, in: window)
    }

    private init(_ install: AppModel.UnfinishedInstall) { self.install = install }

    private func begin(uid: String, model: AppModel, in window: NSWindow) {
        let plan = install.plan
        alert.messageText = "Stop installing \(install.name)?"
        alert.informativeText = Self.summary(of: plan)
        alert.addButton(withTitle: "Keep Downloaded Data")
        alert.addButton(withTitle: Self.removeTitle(for: plan)).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // The size joins the button's title once it's known. Three buttons
        // stack at the alert's full width, so the longer title moves nothing.
        // It's what is on disk, not what the download counted: a folder can
        // hold an earlier attempt's data too, and all of it goes.
        sizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = GameUninstaller.unfinishedSize(of: plan)
            guard !Task.isCancelled else { return }
            await self?.show(size: bytes)
        }
        alert.beginSheetModal(for: window) { [self] response in
            sizeTask?.cancel()
            switch response {
            case .alertFirstButtonReturn: model.cancelDownload(uid: uid)
            case .alertSecondButtonReturn: Task { await model.cancelDownloadMovingToTrash(uid: uid, in: window) }
            default: break
            }
        }
    }

    private func show(size bytes: UInt64) { alert.buttons[1].title = Self.removeTitle(for: install.plan, bytes: bytes) }

    /// One sentence for the choice the buttons give, and one more when the
    /// folder holds other things, to say they're safe.
    static func summary(of plan: UninstallPlan) -> String {
        let folder = plan.root.lastPathComponent
        let keeping = "Keep what’s downloaded for next time"
        if plan.unfinishedStorage != nil {
            return "\(keeping), or delete it. Other games in “\(folder)” aren’t affected."
        }
        if plan.removesFolder { return "\(keeping), or move it to the Trash." }
        return "\(keeping), or move it to the Trash. Everything else in “\(folder)” stays."
    }

    /// "Move 801.7 MB to Trash", or "Delete 801.7 MB" in a shared folder:
    /// what the install added to the shared game data can't go to the Trash.
    /// Without the size while it's being worked out, or when there's none.
    static func removeTitle(for plan: UninstallPlan, bytes: UInt64? = nil) -> String {
        let size = bytes.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : nil }
        if plan.unfinishedStorage != nil { return size.map { "Delete \($0)" } ?? "Delete" }
        return size.map { "Move \($0) to Trash" } ?? "Move to Trash"
    }
}
