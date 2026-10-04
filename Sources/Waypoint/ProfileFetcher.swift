import AppKit
import WaypointCore
import WebKit

/// What Blizzard's account page says about the account signed in to a web session.
struct AccountProfile {
    var accountID: String?
    var battleTag: String?
    var email: String?
}

/// Reads the BattleTag and email of the account signed in to a web session,
/// from the JSON API behind Blizzard's account page (account.battle.net). The
/// page's own OAuth sign-in goes through without a prompt while the session
/// is alive. Nothing is shown.
@MainActor
final class ProfileFetcher: NSObject, WKNavigationDelegate {
    enum Result {
        case signedIn(AccountProfile)
        case signedOut
        case failed
    }

    /// The account page's sign-in: OAuth with Blizzard's login, then back.
    private static let start = URL(string: "https://account.battle.net/oauth2/authorization/account-settings")!

    /// Runs in the page, like the account page's own scripts: `POST /api/`
    /// says who is signed in, `GET /api/details` has the BattleTag and email.
    private static let script = """
        const auth = await fetch('/api/', { method: 'POST', credentials: 'include' });
        if (auth.status !== 200 && auth.status !== 401) throw new Error('auth state: HTTP ' + auth.status);
        const state = await auth.json();
        if (!state.authenticated) return { authenticated: false };
        const headers = { 'Content-Type': 'application/json' };
        const xsrf = document.cookie.match(/XSRF-TOKEN=([^;]+)/);
        if (xsrf) headers['X-XSRF-TOKEN'] = xsrf[1];
        const response = await fetch('/api/details', { credentials: 'include', headers });
        if (!response.ok) throw new Error('details: HTTP ' + response.status);
        const details = await response.json();
        return {
            authenticated: true,
            accountId: state.accountId == null ? null : String(state.accountId),
            battleTag: details.battleTag || null,
            email: details.email || null,
        };
        """

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Result, Never>?
    private var reading = false
    private var giveUp: Task<Void, Never>?

    func fetch(session: WebSessionID, timeout: Duration = .seconds(20)) async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 700),
                                 configuration: WebSession.makeConfiguration(session))
            view.navigationDelegate = self
            webView = view
            view.load(URLRequest(url: Self.start))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if self?.continuation != nil { Log.info(.auth, "profile_timeout", nil, ["seconds": Int(timeout.components.seconds)]) }
                self?.finish(.failed)
            }
        }
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        giveUp?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(returning: result)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        giveUp?.cancel()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, let host = url.host else { return }
        if url.path.hasPrefix("/login") || url.path.contains("/login/") {
            // Settled on the login form: the session has expired. Wait a
            // moment in case a script carries the sign-in on.
            giveUp?.cancel()
            giveUp = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self?.finish(.signedOut) }
            }
        } else if host == "account.battle.net", !url.path.hasPrefix("/oauth2"), !url.path.hasPrefix("/callback") {
            read(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.info(.auth, "profile_page_failed", nil, ["error": error])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.info(.auth, "profile_page_failed", nil, ["error": error])
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled { finish(.failed) }
    }

    private func read(_ webView: WKWebView) {
        guard !reading else { return }
        reading = true
        Task {
            defer { reading = false }
            do {
                let value = try await webView.callAsyncJavaScript(Self.script, contentWorld: .defaultClient)
                guard let fields = value as? [String: Any] else { return finish(.failed) }
                guard fields["authenticated"] as? Bool == true else { return finish(.signedOut) }
                finish(.signedIn(AccountProfile(accountID: fields["accountId"] as? String,
                                                battleTag: fields["battleTag"] as? String,
                                                email: fields["email"] as? String)))
            } catch {
                Log.info(.auth, "profile_read_failed", nil, ["error": error])
                // If the page moved on meanwhile, its next load tries again.
                if !webView.isLoading { finish(.failed) }
            }
        }
    }
}
