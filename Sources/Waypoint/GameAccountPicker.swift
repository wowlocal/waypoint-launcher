import AppKit
import WaypointCore

/// Entirely native selection UI. No portal, cookies, or additional sign-in.
@MainActor
final class GameAccountPicker: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<GameAccountSelection?, Never>?
    private var accounts: [GameAccount] = []
    private let popup = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var useButton = NSButton()
    private var retryButton = NSButton()
    private var remembered: GameAccountSelection?
    private var region = ""
    private var task: Task<Void, Never>?
    private var loader: (@MainActor () async throws -> [GameAccount])?

    func run(account: Account, gameName: String, region: Region, selected: GameAccountSelection?,
             load: @escaping @MainActor () async throws -> [GameAccount]) async -> GameAccountSelection? {
        remembered = selected; self.region = region.rawValue; loader = load
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Select WoW account"
            window.isReleasedWhenClosed = false; window.delegate = self; self.window = window
            let heading = NSTextField(labelWithString: gameName)
            heading.font = .systemFont(ofSize: 20, weight: .semibold)
            let identity = NSTextField(labelWithString: "\(account.displayName) · \(region.displayName)")
            identity.textColor = .secondaryLabelColor
            status.textColor = .secondaryLabelColor
            spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
            useButton = NSButton(title: "Use account", target: self, action: #selector(choose))
            useButton.keyEquivalent = "\r"
            retryButton = NSButton(title: "Retry", target: self, action: #selector(refresh))
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancel.keyEquivalent = "\u{1b}"
            let progress = NSStackView(views: [spinner, status]); progress.spacing = 10
            let buttons = NSStackView(views: [retryButton, NSView(), cancel, useButton]); buttons.spacing = 10
            let stack = NSStackView(views: [heading, identity, popup, progress, NSView(), buttons])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
                popup.widthAnchor.constraint(equalTo: stack.widthAnchor),
                progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            popup.setAccessibilityLabel("World of Warcraft account")
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
            refresh()
        }
    }
    @objc private func refresh() {
        guard task == nil, let loader else { return }
        status.stringValue = "Retrieving your WoW accounts…"
        popup.isEnabled = false; useButton.isEnabled = false; retryButton.isHidden = true
        spinner.startAnimation(nil)
        task = Task { [weak self] in
            do {
                let accounts = try await loader()
                guard let self, self.continuation != nil, !Task.isCancelled else { return }
                self.accounts = accounts
                self.popup.removeAllItems()
                for account in accounts { self.popup.addItem(withTitle: account.name) }
                if let index = accounts.firstIndex(where: { $0.accountID == self.remembered?.accountID }) {
                    self.popup.selectItem(at: index)
                }
                self.popup.isEnabled = !accounts.isEmpty; self.useButton.isEnabled = !accounts.isEmpty
                self.status.stringValue = accounts.isEmpty ? "No WoW accounts were found in this region." : "This choice will be remembered for this title. The game checks subscription and edition access."
                self.window?.makeFirstResponder(self.popup)
            } catch {
                guard let self, self.continuation != nil, !Task.isCancelled else { return }
                self.status.stringValue = (error as? NativeGameAccounts.Failure)?.errorDescription
                    ?? "Couldn’t retrieve your accounts. Check your connection and try again."
            }
            guard let self else { return }
            self.spinner.stopAnimation(nil); self.retryButton.isHidden = false; self.task = nil
        }
    }
    @objc private func choose() {
        guard accounts.indices.contains(popup.indexOfSelectedItem) else { return }
        let account = accounts[popup.indexOfSelectedItem]
        finish(GameAccountSelection(accountID: account.accountID, name: account.name, region: region))
    }
    @objc private func cancel() { finish(nil) }
    private func finish(_ choice: GameAccountSelection?) {
        guard let continuation else { return }
        self.continuation = nil; task?.cancel(); task = nil; loader = nil
        window?.delegate = nil; window?.close(); window = nil
        continuation.resume(returning: choice)
    }
    func windowWillClose(_ notification: Notification) { finish(nil) }
}
