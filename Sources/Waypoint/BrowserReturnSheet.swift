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
    /// The pasteboard's change count when the field last changed: unchanged
    /// later, it still holds what was there then, most likely the address.
    private var pasteboardChangeCount: Int?

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

            let title = NSTextField(labelWithString: "Sign In with Browser")
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let instructions = NSTextField(wrappingLabelWithString: "Sign in on Blizzard’s page in your browser. When the browser shows a page that can’t be reached, copy the whole address from its address bar and paste it here. Keep it private: it signs in as you. A Private Window keeps it out of the browser’s history.")
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
            parent.beginSheet(panel)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        pasteboardChangeCount = NSPasteboard.general.changeCount
        signInButton.isEnabled = task == nil && hasText
    }

    private var hasText: Bool { !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @objc private func openBrowser() {
        guard let url else { return }
        // The default browser: any of them ends on the same unreachable address.
        if !NSWorkspace.shared.open(url) { status.stringValue = "Your browser couldn’t be opened." }
    }

    @objc private func signIn() {
        guard task == nil else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = BrowserLoginReturn.parse(text, expectedOwner: expectedOwner) else {
            status.stringValue = BrowserLoginReturn.parse(text) == nil
                ? "Paste the whole address from the browser’s address bar."
                : "That address signs in to a different Battle.net account."
            return
        }
        // Verifying signs in to the game service, which an open WoW would notice.
        guard !WoWAccountDiscovery.isWoWRunning() else {
            status.stringValue = "Close World of Warcraft, then try again."
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
                // The address signs in as the user: don't leave it lying around.
                let pasteboard = NSPasteboard.general
                if pasteboard.changeCount == self.pasteboardChangeCount { pasteboard.clearContents() }
                self.finish(token)
            } catch {
                guard !Task.isCancelled, self.continuation != nil else { return }
                Log.notice(.auth, "browser_return_unverified", nil, ["error": error])
                self.status.stringValue = switch error as? WoWAccountDiscovery.Failure {
                case .gameRunning: "Close World of Warcraft, then try again."
                case .unavailable, .timedOut, nil: "Couldn’t reach Blizzard. Check your connection and try again."
                default: "Blizzard didn’t accept this address. Sign in again in the browser and paste the new address."
                }
            }
        }
    }

    private func setVerifying(_ verifying: Bool) {
        field.isEnabled = !verifying
        openButton.isEnabled = !verifying
        signInButton.isEnabled = !verifying && hasText
        if verifying {
            spinner.startAnimation(nil)
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
