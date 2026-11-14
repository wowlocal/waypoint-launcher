import Foundation

/// A user-pasted game login return. Parsing is not authentication: callers must
/// verify the ticket with Blizzard before saving or launching with it.
public enum BrowserLoginReturn {
    public static func parse(_ text: String, expectedOwner: String? = nil) -> LoginToken? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 8192, let url = URL(string: text),
              url.scheme == "http", url.host == "localhost", url.port == 0,
              url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "ST" }).count == 1,
              let token = LoginToken(callbackURL: url),
              token.value.range(of: "^[A-Z]{2}-[0-9a-fA-F]{32}-[0-9]+$", options: .regularExpression) != nil,
              let owner = UInt64(token.accountID), owner > 0,
              expectedOwner == nil || token.accountID == expectedOwner else { return nil }
        return token
    }
}
