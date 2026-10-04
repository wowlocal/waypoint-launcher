import Foundation

/// The web login currently uses an email step followed by a password step.
/// Allow each submission once per attempt, including across DOM replacements
/// and navigations. Use the site's own handlers (SRP, CSRF, CAPTCHA, etc.).
public enum LoginForm {
    public static func isTrusted(_ url: URL?, expectedHost: String) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == expectedHost
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && (url.path == "/login" || url.path.hasPrefix("/login/"))
    }

    // Credentials are named callAsyncJavaScript arguments, never embedded
    // in source. Recheck the origin inside JS in case navigation raced us.
    public static let script = """
        if (location.protocol !== 'https:' || location.hostname !== expectedHost ||
            (location.port && location.port !== '443') ||
            !(location.pathname === '/login' || location.pathname.startsWith('/login/')))
            return 'interaction';
        const visible = e => e && !e.hidden && getComputedStyle(e).display !== 'none' &&
            getComputedStyle(e).visibility !== 'hidden' && e.getClientRects().length > 0;
        const errors = document.querySelectorAll('#display-errors, #js-errors, .error-helper, [role="alert"]');
        const messages = [...errors].filter(visible).map(e => e.textContent.trim()).filter(Boolean);
        const networkError = (document.body.getAttribute('data-network-error-message') || '').trim();
        if (networkError && messages.some(text => text.includes(networkError))) return 'temporary';
        if (messages.length) return 'interaction';
        if ([...document.querySelectorAll('input')].some(e => visible(e) &&
            /captcha|authenticator|security.?code|otp|verification/i.test(e.id + ' ' + e.name)))
            return 'interaction';
        if (document.querySelector('form.captcha-required')) return 'interaction';
        const passwordField = document.querySelector('#password, input[name="password"]');
        const usernameField = document.querySelector('#accountName, input[name="accountName"]');
        const field = visible(passwordField) ? passwordField : visible(usernameField) ? usernameField : null;
        const form = field && field.form;
        if (!form) return 'waiting';
        const action = new URL(form.action || location.href, location.href);
        if (action.origin !== location.origin ||
            !(action.pathname === '/login' || action.pathname.startsWith('/login/'))) return 'interaction';
        if ((field === passwordField && !allowPassword) || (field === usernameField && !allowUsername))
            return 'waiting';
        const button = form.querySelector('#submit, button[type="submit"], input[type="submit"]');
        if (!button) return 'waiting';
        if (!submit) return field === passwordField ? 'password' : 'username';
        const fill = (e, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, value);
            e.dispatchEvent(new Event('input', { bubbles: true }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
            e.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
        };
        if (usernameField && !usernameField.disabled) fill(usernameField, username);
        if (field === passwordField) fill(passwordField, password);
        if (button.disabled || button.classList.contains('disabled')) return 'interaction';
        // Defer the click so the native caller records the submission before
        // a redirect can destroy this JavaScript context.
        setTimeout(() => button.click(), 0);
        return field === passwordField ? 'password' : 'username';
        """
}
