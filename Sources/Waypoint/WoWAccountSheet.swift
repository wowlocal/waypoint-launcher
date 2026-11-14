import AppKit
import WaypointCore

/// Finding licenses is explicit. With one, the model picks it; with several,
/// the sheet offers them right away, and later changes happen in the game's
/// menu.
@MainActor
final class WoWAccountSheet: NSViewController {
    private let load: @MainActor () async throws -> [WoWGameAccount]
    private let selected: @MainActor () -> WoWGameAccount?
    private let use: @MainActor (WoWGameAccount) throws -> Void
    private let status = NSTextField(wrappingLabelWithString: "Close WoW on your other devices first.")
    private let spinner = NSProgressIndicator.spinner()
    private let findButton = NSButton(title: "Find Accounts", target: nil, action: nil)
    private let popup = NSPopUpButton()
    private var accounts: [WoWGameAccount] = []
    private var task: Task<Void, Never>?

    init(load: @escaping @MainActor () async throws -> [WoWGameAccount],
         selected: @escaping @MainActor () -> WoWGameAccount?,
         use: @escaping @MainActor (WoWGameAccount) throws -> Void) {
        self.load = load
        self.selected = selected
        self.use = use
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "Find WoW Accounts"
        status.textColor = .secondaryLabelColor
        spinner.isHidden = true
        popup.isHidden = true
        popup.setAccessibilityLabel("WoW Account")
        let progress = NSStackView(views: [spinner, status])
        progress.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        findButton.target = self
        findButton.action = #selector(find)
        findButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancel, findButton], in: .trailing)
        let stack = NSStackView.column([title, progress, popup, buttons], spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 420),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = stack
    }

    override func viewWillDisappear() {
        task?.cancel()
        task = nil
        super.viewWillDisappear()
    }

    @objc private func find() {
        guard task == nil else { return }
        guard accounts.isEmpty else { return choose() }
        findButton.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Finding accounts…"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.findButton.isEnabled = true
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
            }
            do {
                let accounts = try await self.load()
                guard !Task.isCancelled else { return }
                if accounts.count == 1 { self.dismiss(nil); return }
                if accounts.count > 1 { return self.offer(accounts) }
                self.status.stringValue = "No WoW accounts found."
            } catch {
                guard !Task.isCancelled else { return }
                self.status.textColor = .systemRed
                self.status.stringValue = error is CancellationError ? "Account lookup canceled." : error.localizedDescription
                if Self.isFinal(error) { self.findButton.isHidden = true; return }
            }
            self.findButton.title = "Try Again"
        }
    }

    /// Several licenses: pick one now, or Cancel and WoW asks at login.
    private func offer(_ accounts: [WoWGameAccount]) {
        self.accounts = accounts
        let menu = NSMenu()
        for (index, account) in accounts.enumerated() {
            let item = NSMenuItem(title: Self.title(for: account, among: accounts), action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        popup.menu = menu
        if let current = selected(), let index = accounts.firstIndex(where: { $0.id == current.id }) {
            popup.selectItem(withTag: index)
        }
        popup.isHidden = false
        status.stringValue = "Choose the account to play with. You can change it later in the game’s menu."
        findButton.title = "Use Account"
        view.window?.makeFirstResponder(popup)
    }

    private func choose() {
        guard let tag = popup.selectedItem?.tag, accounts.indices.contains(tag) else { return }
        do {
            try use(accounts[tag])
            dismiss(nil)
        } catch {
            status.textColor = .systemRed
            status.stringValue = error.localizedDescription
            // The choice can still be made later in the game's menu.
            if Self.isFinal(error) {
                popup.isHidden = true
                findButton.isHidden = true
            }
        }
    }

    /// Errors trying again in this sheet can't fix.
    private static func isFinal(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == AppModel.wowScopeChanged.domain && error.code == AppModel.wowScopeChanged.code
    }

    @objc private func cancel() { dismiss(nil) }

    /// The license's name, with its id when two share a name.
    static func title(for account: WoWGameAccount, among accounts: [WoWGameAccount]) -> String {
        accounts.filter { $0.name == account.name }.count > 1 ? "\(account.name) (\(account.id))" : account.name
    }
}
