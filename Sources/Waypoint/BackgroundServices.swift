import AppKit
import Observation
import ServiceManagement
import UserNotifications
import WaypointCore

/// Native lifecycle preferences. No helper daemon or credentials are involved.
@MainActor
@Observable
final class BackgroundServices: NSObject, UNUserNotificationCenterDelegate {
    let supportsSystemIntegration = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var loginError: String?
    private(set) var notificationsError: String?
    @ObservationIgnored var openLibrary: (() -> Void)?
    @ObservationIgnored var openAppUpdate: (() -> Void)?
    @ObservationIgnored private var announceAppUpdate: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let ledger = UpdateAlertLedger()
    @ObservationIgnored private var pendingAlerts = Set<String>()

    func start(model: AppModel, updater: AppUpdater) {
        self.model = model
        // Only people who turned notifications on pay for the connection to
        // Notification Center. Set before launch finishes, so a click on an
        // alert that launched Waypoint is handled.
        if supportsSystemIntegration, UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey) {
            UNUserNotificationCenter.current().delegate = self
        }
        model.updateChecked = { [weak self] game, check in
            guard let self, self.supportsSystemIntegration else { return }
            guard check.isUpdateAvailable else {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["game:" + game.id])
                return
            }
            self.notify(id: "game:" + game.id, build: check.latest.buildConfig,
                         title: "\(game.displayName) update available", body: "Version \(check.latest.name) is ready to download.")
        }
        updater.updateAvailable = { [weak self] version, build in
            self?.notify(id: "waypoint", build: build, title: "Waypoint update available",
                         body: "Waypoint \(version) is available. Click to view the update.")
        }
        updater.noUpdateAvailable = { [weak self] in
            guard self?.supportsSystemIntegration == true else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["waypoint"])
        }
        announceAppUpdate = { [weak updater] in updater?.announceAvailableUpdate() }
        let check: @MainActor () -> Void = { [weak model] in
            guard let model, !model.isPreparingToQuit else { return }
            Task { await model.checkForUpdatesInBackground() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in check() }
        }
        timer?.tolerance = 120
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in check() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncDockPolicy()
            }
        }
        syncDockPolicy()
        check()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Reads login-item and notification approval. Settings calls this when
    /// it shows; nothing else needs it.
    func refreshStatus() {
        guard supportsSystemIntegration else { loginStatus = .notFound; return }
        loginStatus = SMAppService.mainApp.status
        Task {
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func setLoginEnabled(_ enabled: Bool) async {
        guard supportsSystemIntegration else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { loginError = "Couldn’t change this: \(error.localizedDescription)" }
        refreshStatus()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard supportsSystemIntegration else { return }
        notificationsError = nil
        if enabled {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                UserDefaults.standard.set(granted, forKey: UpdatePreferences.notificationsKey)
                if granted {
                    announceAppUpdate?()
                    // Updates already found are announced now, not in 30 minutes.
                    await model?.checkForUpdates(force: true)
                } else {
                    notificationsError = "Notifications for Waypoint are turned off in System Settings."
                }
            } catch {
                UserDefaults.standard.set(false, forKey: UpdatePreferences.notificationsKey)
                notificationsError = "Couldn’t turn on notifications: \(error.localizedDescription)"
            }
        } else {
            UserDefaults.standard.set(false, forKey: UpdatePreferences.notificationsKey)
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        refreshStatus()
    }

    func setHideDock(_ hidden: Bool) {
        // Settings offers this only with the menu bar item on, and
        // `syncDockPolicy` brings the Dock icon back if the item goes, so
        // Waypoint is never left with neither.
        UserDefaults.standard.set(hidden, forKey: UpdatePreferences.hideDockKey)
        syncDockPolicy()
    }

    private func syncDockPolicy() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: MenuBarItem.defaultsKey), defaults.bool(forKey: UpdatePreferences.hideDockKey) {
            defaults.set(false, forKey: UpdatePreferences.hideDockKey)
        }
        let policy: NSApplication.ActivationPolicy = defaults.bool(forKey: UpdatePreferences.hideDockKey) ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func notify(id: String, build: String, title: String, body: String) {
        guard supportsSystemIntegration, UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey),
              ledger.needsAlert(id: id, build: build), pendingAlerts.insert(id).inserted else { return }
        Task {
            defer { pendingAlerts.remove(id) }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey) else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                ledger.record(id: id, build: build)
            } catch {
                Log.warning(.app, "update_notification_failed", nil, ["error": error.localizedDescription])
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let isApp = response.notification.request.identifier == "waypoint"
        await MainActor.run {
            if isApp { openAppUpdate?() } else { openLibrary?() }
        }
    }
}
