import AppKit
import WaypointCore

/// The menu bar item: Play and Update without opening the window. Opt-in
/// (Settings ▸ Show Waypoint in the menu bar): until someone turns it on, no
/// status item exists at all, not even a hidden one.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let defaultsKey = "showsMenuBarItem"

    private let model: AppModel
    private let appUpdater: AppUpdater
    private var statusItem: NSStatusItem?
    private var visibility: NSKeyValueObservation?
    private var observer: NSObjectProtocol?

    init(model: AppModel, appUpdater: AppUpdater) {
        self.model = model
        self.appUpdater = appUpdater
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    /// Creates or removes the status item to match the setting.
    private func sync() {
        let wanted = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            item.button?.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Waypoint")
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            // ⌘-dragging the item out of the menu bar turns the setting off.
            // AppKit remembers such a removal, so opting back in has to make
            // the item visible again explicitly.
            item.behavior = .removalAllowed
            item.isVisible = true
            visibility = item.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    if self?.statusItem?.isVisible == false {
                        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
                    }
                }
            }
        } else if !wanted, let item = statusItem {
            visibility = nil
            statusItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for game in model.games where game.isSupported {
            if let update = model.availableUpdate(for: game), GameUpdater.canUpdate(game.family) {
                menu.addItem(ActionItem("Update \(game.displayName) to \(update.latest.name)",
                                        enabled: model.canUpdate(game)) { [model] in
                    Task { await model.update(game) }
                })
            } else {
                let title = model.running.contains(game.id) ? "\(game.displayName) (running)" : "Play \(game.displayName)"
                menu.addItem(ActionItem(title, enabled: model.canPlay(game)) { [model] in
                    Task { await model.play(game) }
                })
            }
        }
        menu.addItem(.separator())
        if let version = appUpdater.readyVersion {
            menu.addItem(ActionItem("Restart to Update Waypoint \(version)") { [appUpdater] in
                appUpdater.restartToUpdate()
            })
        }
        menu.addItem(ActionItem("Check for Updates") { [model, appUpdater] in
            appUpdater.checkNow()
            Task { await model.checkForUpdates(force: true) }
        })
        menu.addItem(ActionItem("Rescan Games") { [model] in model.reload() })
        menu.addItem(NSMenuItem(title: "Quit Waypoint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
