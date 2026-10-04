import AppKit
import SwiftUI
import WaypointCore
import WebKit

/// Watches a web view's navigations for the login redirect that carries the
/// token (`http://localhost:0/?ST=…`) and stops it from actually loading.
@MainActor
final class TokenCatcher: NSObject, WKNavigationDelegate {
    var onToken: ((LoginToken) -> Void)?
    var onPageLoaded: (() -> Void)?
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
        _ = check((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }
}

enum WebSession {
    /// Shared, persistent cookie jar (stored per bundle id), so the Battle.net
    /// session survives restarts and later tokens can be fetched silently.
    @MainActor static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Look like Safari; WKWebView's default user agent has no browser
        // token, which login and captcha pages may treat as unsupported.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return config
    }

    @MainActor static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let blizzard = records.filter {
            $0.displayName.contains("battle.net") || $0.displayName.contains("blizzard.com")
                || $0.displayName.contains("battlenet.com.cn")
        }
        await store.removeData(ofTypes: types, for: blizzard)
    }
}

/// Tries to get a token without showing anything, using the saved session.
@MainActor
final class SilentTokenFetcher {
    private var webView: WKWebView?
    /// Fresh per attempt; the web view only holds its delegate weakly.
    private var catcher: TokenCatcher?

    func fetch(_ url: URL, timeout: Duration = .seconds(12)) async -> LoginToken? {
        await withCheckedContinuation { (continuation: CheckedContinuation<LoginToken?, Never>) in
            var resumed = false
            let finish: (LoginToken?) -> Void = { [weak self] token in
                guard !resumed else { return }
                resumed = true
                self?.webView?.stopLoading()
                self?.webView = nil
                self?.catcher = nil
                continuation.resume(returning: token)
            }
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = finish
            // With a saved session the page redirects to the token right away.
            // If it settles on the login form instead, give up quickly.
            catcher.onPageLoaded = {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    finish(nil)
                }
            }
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700),
                                 configuration: WebSession.makeConfiguration())
            view.navigationDelegate = catcher
            webView = view
            view.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !resumed { Log.info(.auth, "web_session_timeout", nil, ["seconds": Int(timeout.components.seconds)]) }
                finish(nil)
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

    func run(_ url: URL, title: String) async -> LoginToken? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let catcher = TokenCatcher()
            self.catcher = catcher
            catcher.onToken = { [weak self] token in self?.finish(token) }

            let webView = WKWebView(frame: .zero, configuration: WebSession.makeConfiguration())
            webView.navigationDelegate = catcher
            webView.load(URLRequest(url: url))

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = title
            window.contentView = webView
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
