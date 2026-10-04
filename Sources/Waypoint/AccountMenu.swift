import AppKit
import WaypointCore

/// The account switcher, in the library toolbar and the menu bar item: the
/// saved accounts (a check marks the one games launch as), then Add Account
/// and Sign Out. Switching is instant: each account keeps its own session.
@MainActor
enum AccountMenu {
    static func items(model: AppModel) -> [NSMenuItem] {
        let enabled = !model.isSigningIn
        var items: [NSMenuItem] = model.accounts.map { account in
            let item = ActionItem(account.displayName, enabled: enabled) { model.switchAccount(to: account.id) }
            item.image = .account(account)
            item.state = account.id == model.activeAccount?.id ? .on : .off
            if #available(macOS 14.4, *), account.battleTag != nil { item.subtitle = account.email }
            return item
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ActionItem(model.accounts.isEmpty ? "Sign In…" : "Add Account…", enabled: enabled) {
            Task { await model.addAccount() }
        })
        if let active = model.activeAccount {
            items.append(ActionItem("Sign Out of \(active.displayName)", enabled: enabled) {
                Task { await model.signOut() }
            })
        }
        return items
    }

    /// One item that opens the switcher, titled with the active account.
    static func submenuItem(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: model.activeAccount?.displayName ?? "Not Signed In", action: nil, keyEquivalent: "")
        item.image = .account(model.activeAccount)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = items(model: model)
        item.submenu = menu
        return item
    }
}

extension AccountTint {
    var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .orange: .systemOrange
        case .green: .systemGreen
        case .pink: .systemPink
        case .purple: .systemPurple
        case .teal: .systemTeal
        case .yellow: .systemYellow
        case .red: .systemRed
        case .indigo: .systemIndigo
        case .brown: .systemBrown
        }
    }
}

extension NSImage {
    /// The account's avatar: a person on a circle in its tint, so accounts
    /// tell apart at a glance. Signed out, the plain outline.
    static func account(_ account: Account?) -> NSImage? {
        guard let account else { return .symbol("person.crop.circle") }
        let colors = NSImage.SymbolConfiguration(paletteColors: [.white, account.tint.color])
        return .symbol("person.crop.circle.fill")?.withSymbolConfiguration(colors)
    }
}
