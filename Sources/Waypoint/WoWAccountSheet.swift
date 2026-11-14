import AppKit
import WaypointCore

/// Finding licences is explicit. Choosing one happens in the game's menu.
@MainActor
final class WoWAccountSheet: NSViewController {
    private let load: @MainActor () async throws -> [WoWGameAccount]
    private let status = NSTextField(wrappingLabelWithString: "Close WoW on your other devices first.")
    private let spinner = NSProgressIndicator.spinner()
    private let findButton = NSButton(title: "Find Accounts", target: nil, action: nil)
    private var task: Task<Void, Never>?

    init(load: @escaping @MainActor () async throws -> [WoWGameAccount]) {
        self.load = load
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "Find WoW Accounts"
        status.textColor = .secondaryLabelColor
        spinner.isHidden = true
        let progress = NSStackView(views: [spinner, status])
        progress.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        findButton.target = self
        findButton.action = #selector(find)
        findButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancel, findButton], in: .trailing)
        let stack = NSStackView.column([title, progress, buttons], spacing: 16)
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
                if !accounts.isEmpty { self.dismiss(nil); return }
                self.status.stringValue = "No WoW accounts found."
            } catch {
                guard !Task.isCancelled else { return }
                self.status.textColor = .systemRed
                self.status.stringValue = error is CancellationError ? "Account lookup cancelled." : error.localizedDescription
            }
            self.findButton.title = "Try Again"
        }
    }

    @objc private func cancel() { dismiss(nil) }
}
