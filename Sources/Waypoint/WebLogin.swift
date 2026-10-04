import AppKit
import WaypointCore
import WebKit

/// Watches a web view's navigations for the login redirect that carries the
/// token (`http://localhost:0/?ST=…`) and stops it from actually loading.
@MainActor
final class TokenCatcher: NSObject, WKNavigationDelegate {
    var onToken: ((LoginToken) -> Void)?
    var onPageLoaded: (() -> Void)?
    var onFailure: (() -> Void)?
    var onHTTPError: ((Int) -> Void)?
    private var done = false

    private func check(_ url: URL?) -> Bool {
        guard !done, let url, let token = BattleNetLogin.token(fromCallback: url) else { return false }
        done = true
        onToken?(token)
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(check(navigationAction.request.url) || done ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if check(webView.url) { webView.stopLoading() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !done { onPageLoaded?() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A redirect to localhost:0 can fail before we see it as a navigation
        // action; the failing URL still carries the token.
        if !check((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL), !done,
           (error as NSError).code != NSURLErrorCancelled { onFailure?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !done, (error as NSError).code != NSURLErrorCancelled { onFailure?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            onHTTPError?(response.statusCode)
        }
    }
}

enum WebSession {
    /// A persistent cookie jar per account (see `WebSessionID`), so each
    /// Battle.net session survives restarts, for the saved login and the
    /// account page.
    @MainActor static func makeConfiguration(_ session: WebSessionID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store(session)
        // Look like Safari; WKWebView's default user agent has no browser
        // token, which login and captcha pages may treat as unsupported.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.userContentController.addUserScript(WKUserScript(source: launcherBackdrop, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return config
    }

    /// The backdrop Blizzard's login pages expect: they're drawn for the
    /// launcher's dark window (transparent, light text), so on WKWebView's
    /// white the heading, logo and links were invisible. Pages with their
    /// own background or dark text are left alone.
    static let launcherBackdropColor = NSColor(red: 13 / 255, green: 15 / 255, blue: 20 / 255, alpha: 1)
    private static let launcherBackdrop = #"""
    (function () {
      // Blizzard's login pages are drawn for the dark window of its launcher: a
      // transparent page with light text. On WKWebView's white they vanish, so
      // such a page gets the launcher's dark backdrop. Light pages are left alone.
      function clear(color) { return color === 'transparent' || /rgba\(\d+, \d+, \d+, 0\)/.test(color); }
      function fix() {
        var html = document.documentElement, body = document.body;
        if (!body || html.dataset.waypointBackdrop) return;
        if (!clear(getComputedStyle(html).backgroundColor) || !clear(getComputedStyle(body).backgroundColor)) return;
        var rgb = (getComputedStyle(body).color.match(/\d+(\.\d+)?/g) || []).map(Number);
        if (rgb.length < 3 || (0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]) / 255 < 0.6) return;
        html.dataset.waypointBackdrop = '1';
        html.style.backgroundColor = '#0d0f14';
      }
      document.addEventListener('DOMContentLoaded', fix);
      window.addEventListener('load', fix);
    })();
    """#

    @MainActor static func store(_ session: WebSessionID) -> WKWebsiteDataStore {
        switch session {
        case .shared: .default()
        case .own(let id): WKWebsiteDataStore(forIdentifier: id)
        }
    }

    /// Whether the session has any Battle.net cookies, without going online.
    @MainActor static func hasCookies(_ session: WebSessionID) async -> Bool {
        await store(session).httpCookieStore.allCookies().contains { isBlizzard($0.domain) }
    }

    /// Signs the session out for good: its own store is deleted, the shared
    /// one loses its Blizzard data.
    @MainActor static func delete(_ session: WebSessionID) async {
        if case .own(let id) = session {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                // A web view still using the store keeps it alive; empty it instead.
                Log.warning(.auth, "web_session_remove_failed", nil, ["error": error])
            }
        }
        let store = store(session)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: session == .shared ? records.filter { isBlizzard($0.displayName) } : records)
    }

    /// Deletes every account store except `kept`.
    @MainActor static func deleteAll(except kept: Set<WebSessionID>) async {
        // Listing stores before anything else has started WebKit crashes it
        // (null main run loop, macOS 27); getting a store starts it.
        _ = WKWebsiteDataStore.default()
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !kept.contains(.own(id)) {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch {
                Log.warning(.auth, "web_session_remove_failed", nil, ["error": error])
            }
        }
    }

    private static func isBlizzard(_ domain: String) -> Bool {
        domain.contains("battle.net") || domain.contains("blizzard.com") || domain.contains("battlenet.com.cn")
    }
}

/// Tries to get a token without showing anything, using the saved session.
@MainActor
final class SilentTokenFetcher {
    enum Result {
        case token(LoginToken)
        case signedOut
        case failed
    }
    private var webView: WKWebView?
    /// Fresh per attempt; the web view only holds its delegate weakly.
    private var catcher: TokenCatcher?

    func fetch(_ url: URL, session: WebSessionID, timeout: Duration = .seconds(12)) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            var resumed = false
            let finish: (Result) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                self?.webView?.stopLoading()
                self?.webView = nil
                self?.catcher = nil
                continuation.resume(returning: result)
            }
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = { finish(.token($0)) }
            catcher.onFailure = { finish(.failed) }
            catcher.onHTTPError = { _ in finish(.failed) }
            // With a saved session the page redirects to the token right away.
            // If it settles on the login form instead, give up quickly.
            catcher.onPageLoaded = { [weak self] in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !resumed, let view = self?.webView, !view.isLoading else { return }
                    finish(LoginForm.isTrusted(view.url, expectedHost: url.host!) ? .signedOut : .failed)
                }
            }
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700),
                                 configuration: WebSession.makeConfiguration(session))
            view.navigationDelegate = catcher
            webView = view
            view.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !resumed { Log.info(.auth, "web_session_timeout", nil, ["seconds": Int(timeout.components.seconds)]) }
                finish(.failed)
            }
        }
    }
}

/// The interactive login, shown in its own small window.
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<LoginToken?, Never>?
    private var catcher: TokenCatcher?
    private weak var webView: WKWebView?
    /// What was typed into the login form's "Email or Phone" field during the
    /// last `run`, to name the account by: Blizzard's account page doesn't
    /// see this login's session, so it can't say the BattleTag or email.
    private(set) var typedAccountName: String?
    /// Covers the page while the known email or phone goes in, until the
    /// password step shows; it also takes the clicks meant for the page.
    private var loadingOverlay: NSView?
    /// The email or phone this `run` filled in, which nobody typed.
    private var filledAccountName: String?

    /// WebKit lets only browsers and the site's own apps use passkeys, so
    /// Blizzard's passkey sign-in can't finish in this window.
    private static let passkeyNotice = "Passkeys don’t work in Waypoint. If Battle.net asks for one, sign in with your password instead."
    /// Hides the page's buttons that start a passkey sign-in ("Use passkey"
    /// next to the password), which can only fail here. Only those: a "can't
    /// use your passkey?" link may be the way back to the password. The page
    /// swaps its steps in place, so it keeps watching. It's always the English
    /// one (`/login/en/`).
    private static let hidePasskeyScript = #"""
        (function () {
          if (window.__waypointNoPasskey) return;
          window.__waypointNoPasskey = true;
          function hide() {
            document.querySelectorAll('button, a, [role="button"], input[type="submit"], input[type="button"]').forEach(function (e) {
              var text = (e.textContent || e.value || '').replace(/\s+/g, ' ').trim();
              if (/^(use|sign in with|log in with|continue with)( a| your)? passkeys?$/i.test(text))
                e.style.setProperty('display', 'none', 'important');
            });
          }
          hide();
          new MutationObserver(hide).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """#

    private static let accountNameHandler = "waypointAccountName"
    /// Reports the login form's account name (`#accountName`) when it's
    /// submitted, however the page submits it.
    private static let accountNameScript = #"""
        (function () {
          if (window.__waypointAccountName) return;
          window.__waypointAccountName = true;
          function send() {
            var field = document.getElementById('accountName');
            var value = field && field.value && field.value.trim();
            if (value) window.webkit.messageHandlers.waypointAccountName.postMessage(value);
          }
          document.addEventListener('submit', send, true);
          document.addEventListener('change', function (e) { if (e.target && e.target.id === 'accountName') send(); }, true);
          document.addEventListener('keydown', function (e) { if (e.key === 'Enter') send(); }, true);
          document.addEventListener('click', function (e) {
            if (e.target && e.target.closest && e.target.closest('button, [type=submit]')) send();
          }, true);
        })();
        """#

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.accountNameHandler, let name = message.body as? String else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count <= 254, trimmed != filledAccountName { typedAccountName = trimmed }
    }

    /// `accountName`: the email or phone of the account being signed in to.
    /// It's filled into the form's first step, which is submitted once; the
    /// page shows once it's at the password.
    func run(_ url: URL, title: String, session: WebSessionID, accountName: String? = nil,
             preparedWebView: WKWebView? = nil, notice: String? = nil) async -> LoginToken? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = { [weak self] token in self?.finish(token) }
            catcher.onFailure = { [weak self] in self?.reveal() }
            catcher.onHTTPError = { [weak self] _ in self?.reveal() }

            let webView = preparedWebView ?? WKWebView(frame: .zero, configuration: WebSession.makeConfiguration(session))
            webView.navigationDelegate = catcher
            webView.underPageBackgroundColor = WebSession.launcherBackdropColor
            typedAccountName = nil
            filledAccountName = nil
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.accountNameHandler)
            controller.add(WeakMessageHandler(self), name: Self.accountNameHandler)
            controller.addUserScript(WKUserScript(source: Self.accountNameScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            controller.addUserScript(WKUserScript(source: Self.hidePasskeyScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            if preparedWebView != nil { // the page it's already on
                webView.evaluateJavaScript(Self.accountNameScript)
                webView.evaluateJavaScript(Self.hidePasskeyScript)
            }
            self.webView = webView
            // It may have reached the token during the delegate hand-off.
            if let callback = webView.url, let token = BattleNetLogin.token(fromCallback: callback) {
                self.continuation = nil
                self.catcher = nil
                continuation.resume(returning: token)
                return
            }
            if preparedWebView == nil { webView.load(URLRequest(url: url)) }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = title
            let label = NSTextField(wrappingLabelWithString: [notice, Self.passkeyNotice].compactMap { $0 }.joined(separator: "\n\n"))
            label.textColor = .secondaryLabelColor
            label.font = .preferredFont(forTextStyle: .subheadline)
            let container = NSView()
            for view in [label, webView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                webView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            if let accountName, preparedWebView == nil, let host = url.host {
                // Transparent, not hidden: WebKit throttles pages it thinks are
                // hidden. The page's own dark backdrop shows meanwhile.
                webView.alphaValue = 0
                let backdrop = NSView()
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = WebSession.launcherBackdropColor.cgColor
                // Above the page: AppKit's hit-testing ignores alpha, so it
                // would take clicks while invisible.
                let overlay = NSView()
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.appearance = NSAppearance(named: .darkAqua)
                for view in [backdrop, overlay, spinner] { view.translatesAutoresizingMaskIntoConstraints = false }
                container.addSubview(backdrop, positioned: .below, relativeTo: webView)
                container.addSubview(overlay, positioned: .above, relativeTo: webView)
                overlay.addSubview(spinner)
                for view in [backdrop, overlay] {
                    NSLayoutConstraint.activate([
                        view.topAnchor.constraint(equalTo: webView.topAnchor),
                        view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
                        view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
                    ])
                }
                NSLayoutConstraint.activate([
                    spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                ])
                spinner.startAnimation(nil)
                loadingOverlay = overlay
                filledAccountName = accountName
                Task { await signIn(as: accountName, expectedHost: host, in: webView) }
            }
            window.contentView = container
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Fills the known email or phone into the first step and submits it,
    /// then shows the page at the password step, or as soon as it wants
    /// something else (an error, a CAPTCHA, another page); at the latest
    /// after 8 s. Uses the saved login's form logic (`LoginForm`): it checks
    /// the page is Blizzard's login form and gets the value as an argument,
    /// never as script source.
    private func signIn(as accountName: String, expectedHost: String, in view: WKWebView) async {
        defer { reveal(view) }
        let deadline = ContinuousClock.now + .seconds(8)
        var submitted = false
        // Once shown (a failed load, an HTTP error), the page is the user's.
        var waiting: Bool { webView === view && loadingOverlay != nil }
        while ContinuousClock.now < deadline, waiting, continuation != nil {
            try? await Task.sleep(for: .milliseconds(200))
            guard !view.isLoading, let pageURL = view.url else { continue }
            guard LoginForm.isTrusted(pageURL, expectedHost: expectedHost) else { return }
            var arguments: [String: Any] = ["expectedHost": expectedHost, "username": accountName, "password": "",
                                            "allowUsername": !submitted, "allowPassword": true, "submit": false]
            let step = try? await view.callAsyncJavaScript(LoginForm.script, arguments: arguments, contentWorld: .defaultClient)
            guard waiting else { return }
            switch step as? String {
            case "username":
                submitted = true
                arguments["allowPassword"] = false
                arguments["submit"] = true
                // nil: the submission already took the page elsewhere.
                let submission = try? await view.callAsyncJavaScript(LoginForm.script, arguments: arguments,
                                                                     contentWorld: .defaultClient) as? String
                guard submission == "username" || submission == nil else { return }
                Log.info(.auth, "account_name_filled")
            case "waiting", nil:
                continue // still loading, or the page swapping steps
            default:
                return // the password step, or something only the user can answer
            }
        }
    }

    /// `view`: only if it's still this window's page, not a later sign-in's.
    private func reveal(_ view: WKWebView? = nil) {
        guard let overlay = loadingOverlay, view == nil || view === webView else { return }
        loadingOverlay = nil
        overlay.removeFromSuperview()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            webView?.animator().alphaValue = 1
        }
    }

    private func finish(_ token: LoginToken?) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.accountNameHandler)
        webView = nil
        loadingOverlay = nil
        window?.delegate = nil
        window?.close()
        window = nil
        catcher = nil
        continuation.resume(returning: token)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}

/// WKUserContentController keeps its message handlers strongly; this keeps
/// the login window from living as long as the web view.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
