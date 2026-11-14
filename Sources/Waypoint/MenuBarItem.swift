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
    private var quickActions: NSMenu?
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
            quickActions = menu
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = "Show or hide Waypoint (right-click for quick actions)"
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
            quickActions = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let quickActions {
            NSMenu.popUpContextMenu(quickActions, with: event, for: sender)
        } else {
            NSApp.sendAction(#selector(AppDelegate.toggleLibrary(_:)), to: nil, from: sender)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Open Waypoint", action: #selector(AppDelegate.showLibrary(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        for game in model.games where game.isSupported {
            if let item = downloadItem(uid: game.id, name: game.displayName, phase: model.phase(of: game)) {
                menu.addItem(item)
                addCancelDownload(to: menu, uid: game.id, name: game.displayName)
            } else if let update = model.availableUpdate(for: game), GameUpdate.canUpdate(game.install) {
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
        for product in model.installable {
            let uid = model.installKey(for: product)
            if let item = downloadItem(uid: uid, name: product.displayName, phase: model.phase(of: product)) {
                menu.addItem(item)
                addCancelDownload(to: menu, uid: uid, name: product.displayName)
            }
        }
        menu.addItem(.separator())
        menu.addItem(AccountMenu.submenuItem(model: model))
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

    private func addCancelDownload(to menu: NSMenu, uid: String, name: String) {
        guard model.canCancelDownload(uid: uid) else { return }
        menu.addItem(ActionItem("Cancel \(name) Download") { [model] in model.cancelDownload(uid: uid) })
    }

    private func downloadItem(uid: String, name: String, phase: AppModel.Phase) -> NSMenuItem? {
        switch phase {
        case .updating:
            return ActionItem("Pause \(name)", enabled: model.canPauseDownload(uid: uid)) { [model] in
                model.pauseDownload(uid: uid)
            }
        case .pausing:
            return ActionItem("Pausing \(name)…", enabled: false) {}
        case .failed where !model.canResumeDownload(uid: uid):
            return nil
        case .paused, .failed:
            return ActionItem("Resume \(name)", enabled: model.canResumeDownload(uid: uid)) { [model] in
                Task { await model.resumeDownload(uid: uid) }
            }
        default: return nil
        }
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
