import AppKit
import WaypointCore
import WebKit

/// One hidden attempt. Challenges and rejected passwords are handed to the
/// interactive window in the SAME web view, with no second submission.
@MainActor
final class CredentialTokenFetcher {
    enum Result {
        case token(LoginToken)
        case interaction(WKWebView)
        case failed
    }

    private var webView: WKWebView?
    private var catcher: TokenCatcher?
    private var continuation: CheckedContinuation<Result, Never>?
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func fetch(_ url: URL, session: WebSessionID, credentials: SavedCredentials,
               timeout: Duration = .seconds(25)) async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = { [weak self] in self?.finish(.token($0)) }
            catcher.onFailure = { [weak self] in self?.finish(.failed) }
            catcher.onHTTPError = { [weak self] status in
                guard let self, let view = self.webView else { return }
                self.finish(status == 429 || status == 401 || status == 403 ? .interaction(view) : .failed)
            }
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                                 configuration: WebSession.makeConfiguration(session))
            webView = view
            view.navigationDelegate = catcher
            view.load(URLRequest(url: url))
            pollTask = Task { [weak self] in
                var submittedUsername = false
                var submittedPassword = false
                while !Task.isCancelled, self?.continuation != nil {
                    if !view.isLoading, let pageURL = view.url {
                        guard LoginForm.isTrusted(pageURL, expectedHost: url.host!) else {
                            self?.finish(.interaction(view))
                            return
                        }
                        do {
                            var arguments: [String: Any] = [
                                "expectedHost": url.host!, "username": credentials.username, "password": credentials.password,
                                "allowUsername": !submittedUsername && !submittedPassword,
                                "allowPassword": !submittedPassword,
                                "submit": false,
                            ]
                            let result = try await view.callAsyncJavaScript(LoginForm.script, arguments: arguments,
                                                                           contentWorld: .defaultClient) as? String
                            guard !Task.isCancelled, self?.continuation != nil else { return }
                            switch result {
                            case "username", "password":
                                // Consume the submission BEFORE calling JS:
                                // redirects can destroy its result context.
                                if result == "password" { submittedPassword = true } else { submittedUsername = true }
                                arguments["allowUsername"] = result == "username"
                                arguments["allowPassword"] = result == "password"
                                arguments["submit"] = true
                                let submission = try await view.callAsyncJavaScript(LoginForm.script, arguments: arguments,
                                                                                    contentWorld: .defaultClient) as? String
                                if submission == "interaction", !Task.isCancelled {
                                    self?.finish(.interaction(view))
                                    return
                                }
                                if submission == "temporary", !Task.isCancelled {
                                    self?.finish(.failed)
                                    return
                                }
                            case "temporary":
                                self?.finish(.failed)
                                return
                            case "interaction":
                                self?.finish(.interaction(view))
                                return
                            default: break
                            }
                        } catch {
                            // A redirect can destroy the JS context. Wait for
                            // the next page; never include JS errors in logs.
                        }
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.continuation != nil else { return }
                // A settled page may be an unsupported form, a challenge or
                // a rejected login. Pause rather than retry that password.
                self.finish(view.isLoading ? .failed : .interaction(view))
            }
        }
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        pollTask?.cancel()
        timeoutTask?.cancel()
        pollTask = nil
        timeoutTask = nil
        if case .interaction = result {} else { webView?.stopLoading() }
        webView?.navigationDelegate = nil
        webView = nil
        catcher = nil
        continuation.resume(returning: result)
    }
}

@MainActor
enum CredentialEditor {
    /// The old password is deliberately not filled in: replacing it requires
    /// entering the current one explicitly.
    static func run(account: Account, username: String?, replacing: Bool) -> SavedCredentials? {
        let alert = NSAlert()
        alert.messageText = replacing ? "Update Saved Battle.net Login" : "Save Battle.net Login"
        alert.informativeText = "Save the login for \(account.displayName) in this Mac’s Keychain. Waypoint will use it when your session expires. You may still need to approve two-factor authentication."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let email = NSTextField(string: username ?? account.email ?? "")
        email.placeholderString = "Email or phone"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Current password"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Login:"), email],
            [NSTextField(labelWithString: "Password:"), password],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        password.widthAnchor.constraint(equalTo: email.widthAnchor).isActive = true
        alert.accessoryView = grid
        alert.window.initialFirstResponder = email.stringValue.isEmpty ? email : password
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let username = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.stringValue.isEmpty else {
            let error = NSAlert()
            error.messageText = "Enter a login and password"
            error.informativeText = "No saved login was changed."
            error.runModal()
            return nil
        }
        return SavedCredentials(username: username, password: password.stringValue)
    }
}
