import AppKit
import Testing
import WebKit
@testable import WaypointCore

/// Real WebKit DOM fixtures: no requests to Blizzard and no real passwords.
@MainActor
private final class LoginPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var loaded: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        super.init()
        view.navigationDelegate = self
    }

    func load(_ html: String, url: String = "https://eu.battle.net/login/en/") async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: URL(string: url)!)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(URLError(.timedOut))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: (any Error)? = nil) {
        timeout?.cancel()
        timeout = nil
        if let error { loaded?.resume(throwing: error) } else { loaded?.resume() }
        loaded = nil
    }

    func step(usernameAllowed: Bool = true, passwordAllowed: Bool = true, submit: Bool = true) async throws -> String? {
        try await view.callAsyncJavaScript(LoginForm.script, arguments: [
            "expectedHost": "eu.battle.net", "username": "name+'\\\"@example.com", "password": "пароль ' \\\"",
            "allowUsername": usernameAllowed, "allowPassword": passwordAllowed, "submit": submit,
        ], contentWorld: .defaultClient) as? String
    }

    static func form(_ inputs: String, extra: String = "", action: String = "") -> String {
        """
        <html><body>\(extra)<form action="\(action)" onsubmit="event.preventDefault(); window.submissions = (window.submissions || 0) + 1;">
        \(inputs)<button id="submit" type="submit">Continue</button></form></body></html>
        """
    }
}

@Suite(.serialized)
@MainActor
struct LoginFormTests {
    @Test func emailThenPasswordSubmitOnlyOnceDespiteDOMReplacement() async throws {
        let page = LoginPage()
        try await page.load(LoginPage.form("<input id='accountName' name='accountName'>"))
        #expect(try await page.step(submit: false) == "username")
        #expect(try await page.view.evaluateJavaScript("window.submissions || 0") as? Int == 0)
        #expect(try await page.step() == "username")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await page.view.evaluateJavaScript("window.submissions") as? Int == 1)
        #expect(try await page.step(usernameAllowed: false) == "waiting")

        try await page.load(LoginPage.form("<input id='password' name='password' type='password'>"))
        #expect(try await page.step(usernameAllowed: false) == "password")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await page.view.evaluateJavaScript("document.querySelector('#password').value") as? String == "пароль ' \\\"")
        #expect(try await page.view.evaluateJavaScript("window.submissions") as? Int == 1)
        #expect(try await page.step(usernameAllowed: false, passwordAllowed: false) == "waiting")
        // A new login form after a rejected submission must not submit again.
        try await page.load(LoginPage.form("<input id='password' name='password' type='password'>"))
        #expect(try await page.step(usernameAllowed: false, passwordAllowed: false) == "waiting")
        #expect(try await page.view.evaluateJavaScript("window.submissions || 0") as? Int == 0)
    }

    @Test func rejectsWrongOriginAndCrossOriginFormActionsBeforeFilling() async throws {
        for (url, action) in [("https://evil.example/login/en/", ""),
                              ("http://eu.battle.net/login/en/", ""),
                              ("https://eu.battle.net/login/en/", "https://evil.example/login/")] {
            let page = LoginPage()
            try await page.load(LoginPage.form("<input id='password' name='password' type='password'>", action: action), url: url)
            #expect(try await page.step() == "interaction")
            #expect(try await page.view.evaluateJavaScript("document.querySelector('#password').value") as? String == "")
            #expect(try await page.view.evaluateJavaScript("window.submissions || 0") as? Int == 0)
        }
    }

    @Test func errorsCaptchaAndTwoFactorRequireInteractionWithoutSubmitting() async throws {
        for extra in ["<div id='display-errors'>Incorrect password</div>",
                      "<div id='js-errors' role='alert'>Account locked</div>",
                      "<input id='authenticatorCode'>", "<input name='captcha'>"] {
            let page = LoginPage()
            try await page.load(LoginPage.form("<input id='password' name='password' type='password'>", extra: extra))
            #expect(try await page.step() == "interaction")
            #expect(try await page.view.evaluateJavaScript("window.submissions || 0") as? Int == 0)
        }
    }

    @Test func hiddenErrorsDoNotBlockNormalLoginAndInputEventsEnableSubmit() async throws {
        let page = LoginPage()
        try await page.load("""
            <div id="js-errors" style="display:none">Previous error</div>
            <form onsubmit="event.preventDefault(); window.submissions = 1;">
            <input id="accountName" oninput="document.getElementById('submit').disabled = false;">
            <button id="submit" type="submit" disabled>Continue</button></form>
            """)
        #expect(try await page.step(submit: false) == "username")
        #expect(try await page.step() == "username")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await page.view.evaluateJavaScript("window.submissions") as? Int == 1)
    }

    @Test func inlineNetworkErrorUsesTemporaryBackoffInsteadOfRejectingPassword() async throws {
        let page = LoginPage()
        try await page.load("""
            <html><body data-network-error-message="Please check your network connection and try again.">
            <div id="js-errors">Please check your network connection and try again.</div>
            <form><input id="password" type="password"><button id="submit" type="submit">Log In</button></form>
            </body></html>
            """)
        #expect(try await page.step() == "temporary")
        #expect(try await page.view.evaluateJavaScript("document.querySelector('#password').value") as? String == "")
    }
}
