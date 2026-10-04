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
    /// Battle.net session survives restarts and later tokens can be fetched
    /// silently.
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
final class LoginWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<LoginToken?, Never>?
    private var catcher: TokenCatcher?

    func run(_ url: URL, title: String, session: WebSessionID,
             preparedWebView: WKWebView? = nil, notice: String? = nil) async -> LoginToken? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = { [weak self] token in self?.finish(token) }

            let webView = preparedWebView ?? WKWebView(frame: .zero, configuration: WebSession.makeConfiguration(session))
            webView.navigationDelegate = catcher
            webView.underPageBackgroundColor = WebSession.launcherBackdropColor
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
            if let notice {
                let label = NSTextField(wrappingLabelWithString: notice)
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
                window.contentView = container
            } else {
                window.contentView = webView
            }
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(_ token: LoginToken?) {
        guard let continuation else { return }
        self.continuation = nil
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
