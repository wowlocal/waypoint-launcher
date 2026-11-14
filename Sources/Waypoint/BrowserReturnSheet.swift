import AppKit
import WaypointCore

/// Signs in to WoW in the user's own browser, for its password manager or a
/// passkey. Blizzard's page ends on `http://localhost:0/?ST=…`, which no
/// browser can open; the user pastes that address here. Nothing is read from
/// the browser or the pasteboard on its own; reading the pasteboard would
/// also have macOS ask the user whether to allow it.
///
/// A pasted address is only a claim: it's used once the game service signed
/// in with its ticket and said whose it is.
@MainActor
final class BrowserReturnSheet: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    /// Who the game service said the ticket belongs to, once it did.
    private(set) var verifiedProfile: NativeAccountProfile?
    private var window: NSWindow?
    private weak var parent: NSWindow?
    private var continuation: CheckedContinuation<LoginToken?, Never>?
    private let field = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var signInButton = NSButton()
    private var openButton = NSButton()
    private var url: URL?
    private var expectedOwner: String?
    private var task: Task<Void, Never>?
    /// The pasteboard's change count when the user last pasted into the
    /// field: unchanged later, it still holds what was pasted.
    private var pasteboardChangeCount: Int?
    /// A Paste menu item (⌘V among them) is being sent.
    private var isPasting = false

    /// `expectedOwner`: the account being signed in to again, if any; an
    /// address for another one is refused.
    func run(on parent: NSWindow, url: URL, expectedOwner: String? = nil) async -> LoginToken? {
        self.parent = parent
        self.url = url
        self.expectedOwner = expectedOwner
        verifiedProfile = nil
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            self.window = panel

            let title = NSTextField.label(.title2)
            title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
            title.stringValue = "Sign In with Browser"
            let instructions = NSTextField(wrappingLabelWithString: "Sign in on Blizzard’s page in your browser. It ends on a page that can’t be reached: copy that page’s address and paste it here. The address signs in as you, so keep it private.")
            instructions.textColor = .secondaryLabelColor
            openButton = NSButton(title: "Open Browser", target: self, action: #selector(openBrowser))
            field.placeholderString = "http://localhost:0/?ST=…"
            field.setAccessibilityLabel("Address from the browser")
            field.delegate = self
            signInButton = NSButton(title: "Sign In", target: self, action: #selector(signIn))
            signInButton.keyEquivalent = "\r"
            signInButton.isEnabled = false
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancel.keyEquivalent = "\u{1b}"
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            status.textColor = .secondaryLabelColor
            let progress = NSStackView(views: [spinner, status])
            progress.spacing = 8
            let buttons = NSStackView(views: [NSView(), cancel, signInButton])
            buttons.spacing = 12
            let stack = NSStackView(views: [title, instructions, openButton, field, progress, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.setCustomSpacing(20, after: progress)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = panel.contentView!
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                field.widthAnchor.constraint(equalTo: stack.widthAnchor),
                progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(menuWillSend), name: NSMenu.willSendActionNotification, object: nil)
            center.addObserver(self, selector: #selector(menuDidSend), name: NSMenu.didSendActionNotification, object: nil)
            parent.beginSheet(panel)
        }
    }

    /// Edit › Paste and ⌘V are sent by a menu item, and so is a context
    /// menu's Paste; the field changes while it's being sent.
    @objc private func menuWillSend(_ notification: Notification) {
        let action = (notification.userInfo?["MenuItem"] as? NSMenuItem)?.action
        isPasting = [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:))].contains(action)
    }

    @objc private func menuDidSend(_ notification: Notification) { isPasting = false }

    func controlTextDidChange(_ notification: Notification) {
        if isPasting { pasteboardChangeCount = NSPasteboard.general.changeCount }
        signInButton.isEnabled = task == nil && hasText
    }

    /// The address signs in as the user: once it's been used or given up on,
    /// don't leave it on the pasteboard. Only if the pasteboard still holds
    /// what was pasted, never something copied since, and only if that was
    /// an address: something else pasted by mistake is the user's.
    private func clearPastedAddress() {
        defer { pasteboardChangeCount = nil }
        let pasteboard = NSPasteboard.general
        guard let pasteboardChangeCount, pasteboard.changeCount == pasteboardChangeCount,
              BrowserLoginReturn.parse(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return }
        pasteboard.clearContents()
    }

    private static let busyMessage = "Waypoint is busy with Blizzard. Try again in a moment."

    private func showError(_ message: String) {
        status.textColor = .systemRed
        status.stringValue = message
        clearPastedAddress()
    }

    private var hasText: Bool { !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @objc private func openBrowser() {
        guard let url else { return }
        // The default browser: any of them ends on the same unreachable address.
        if !NSWorkspace.shared.open(url) {
            status.textColor = .systemRed
            status.stringValue = "Your browser couldn’t be opened."
        }
    }

    @objc private func signIn() {
        guard task == nil else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = BrowserLoginReturn.parse(text, expectedOwner: expectedOwner) else {
            showError(BrowserLoginReturn.parse(text) == nil
                ? "Paste the whole address from the browser’s address bar."
                : "That address signs in to a different Battle.net account.")
            return
        }
        // Verifying signs in to the game service, which an open WoW would
        // notice, and which a WoW account lookup is doing already.
        guard !WoWAccountDiscovery.isWoWRunning() else {
            showError("Close World of Warcraft, then try again.")
            return
        }
        guard !WoWAccountDiscovery.hasOpenSession else {
            showError(Self.busyMessage)
            return
        }
        setVerifying(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.setVerifying(false)
            }
            do {
                // Works without WoW installed: the build is the live one.
                let build = try await WoWAccountDiscovery.liveBuild(region: .us)
                guard !Task.isCancelled, self.continuation != nil else { return }
                let profile = try await WoWAccountDiscovery().profile(token: token, build: build, region: .us)
                guard !Task.isCancelled, self.continuation != nil else { return }
                guard profile.accountID == token.accountID else { throw WoWAccountDiscovery.Failure.identityMismatch }
                self.verifiedProfile = profile
                self.finish(token)
            } catch {
                guard !Task.isCancelled, self.continuation != nil else { return }
                Log.notice(.auth, "browser_return_unverified", nil, ["error": error])
                let message = switch error as? WoWAccountDiscovery.Failure {
                case .gameRunning: "Close World of Warcraft, then try again."
                case .busy: Self.busyMessage
                case .unavailable, .timedOut, nil: "Couldn’t reach Blizzard. Check your connection and try again."
                default: "Blizzard didn’t accept this address. Sign in again in the browser and paste the new address."
                }
                self.showError(message)
            }
        }
    }

    private func setVerifying(_ verifying: Bool) {
        field.isEnabled = !verifying
        openButton.isEnabled = !verifying
        signInButton.isEnabled = !verifying && hasText
        if verifying {
            spinner.startAnimation(nil)
            status.textColor = .secondaryLabelColor
            status.stringValue = "Checking with Blizzard…"
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc func cancel() { finish(nil) }

    private func finish(_ token: LoginToken?) {
        guard let continuation else { return }
        self.continuation = nil
        if token == nil { verifiedProfile = nil }
        task?.cancel()
        NotificationCenter.default.removeObserver(self, name: NSMenu.willSendActionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didSendActionNotification, object: nil)
        isPasting = false
        clearPastedAddress()
        field.stringValue = ""
        if let window {
            window.delegate = nil
            parent?.endSheet(window)
            window.orderOut(nil)
        }
        window = nil
        url = nil
        continuation.resume(returning: token)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }
}
