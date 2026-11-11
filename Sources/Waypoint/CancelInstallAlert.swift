import AppKit
import WaypointCore

/// Asks what becomes of an install that never finished when it's cancelled:
/// what it downloaded stays for the next install to continue from, or goes
/// to the Trash. Only such an install is asked about (see
/// `AppModel.unfinishedInstall`); cancelling an update keeps its data.
@MainActor
final class CancelInstallAlert {
    private let install: AppModel.UnfinishedInstall
    private let alert = NSAlert()
    private let sizeText = NSTextField(wrappingLabelWithString: "")
    private var sizeTask: Task<Void, Never>?

    static func present(_ install: AppModel.UnfinishedInstall, uid: String, model: AppModel, in window: NSWindow) {
        CancelInstallAlert(install).begin(uid: uid, model: model, in: window)
    }

    private init(_ install: AppModel.UnfinishedInstall) { self.install = install }

    private func begin(uid: String, model: AppModel, in window: NSWindow) {
        alert.messageText = "Stop installing \(install.name)?"
        alert.informativeText = Self.summary(of: install.plan)
        alert.addButton(withTitle: "Keep Downloaded Data")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // What is on disk, not what the download counted: a folder can hold
        // an earlier attempt's data too, and all of it goes.
        sizeText.textColor = .secondaryLabelColor
        sizeText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeText.preferredMaxLayoutWidth = 228
        // The alert doesn't grow later: sized for the longest text.
        sizeText.stringValue = Self.sizeDescription(999_900_000_000)
        sizeText.frame = NSRect(origin: .zero, size: NSSize(width: 228, height: sizeText.fittingSize.height))
        sizeText.stringValue = "Calculating size…"
        alert.accessoryView = sizeText
        let items = install.plan.trashed
        sizeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = GameUninstaller.allocatedSize(of: items)
            guard !Task.isCancelled else { return }
            await self?.show(size: bytes)
        }
        alert.beginSheetModal(for: window) { [self] response in
            sizeTask?.cancel()
            switch response {
            case .alertFirstButtonReturn: model.cancelDownload(uid: uid)
            case .alertSecondButtonReturn: Task { await model.cancelDownloadMovingToTrash(uid: uid) }
            default: break
            }
        }
    }

    private func show(size bytes: UInt64) { sizeText.stringValue = Self.sizeDescription(bytes) }

    static func summary(of plan: UninstallPlan) -> String {
        let folder = plan.root.lastPathComponent
        let keeping = "What’s downloaded so far can stay for the next install to continue from"
        if plan.removesFolder { return "\(keeping), or the “\(folder)” folder can go to the Trash now." }
        return "\(keeping), or go to the Trash now. Everything that was in “\(folder)” before this install stays either way."
    }

    static func sizeDescription(_ bytes: UInt64) -> String {
        "The Trash would get \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). Empty it afterwards to get the space back."
    }
}
