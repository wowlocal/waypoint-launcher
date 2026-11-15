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
    private(set) var errorMessage: String?
    private(set) var notificationTestStatus: String?
    private(set) var isTestingNotification = false
    @ObservationIgnored var openLibrary: (() -> Void)?
    @ObservationIgnored var openAppUpdate: (() -> Void)?
    @ObservationIgnored private var announceAppUpdate: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private let ledger = UpdateAlertLedger()
    @ObservationIgnored private var pendingAlerts = Set<String>()

    func start(model: AppModel, updater: AppUpdater) {
        if supportsSystemIntegration { UNUserNotificationCenter.current().delegate = self }
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
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        syncDockPolicy()
        refreshStatus()
        check()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshStatus() {
        guard supportsSystemIntegration else { loginStatus = .notFound; return }
        loginStatus = SMAppService.mainApp.status
        Task {
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func setLoginEnabled(_ enabled: Bool) async {
        guard supportsSystemIntegration else { return }
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { errorMessage = "Could not change Start at login: \(error.localizedDescription)" }
        refreshStatus()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard supportsSystemIntegration else { return }
        errorMessage = nil
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                UserDefaults.standard.set(granted, forKey: UpdatePreferences.notificationsKey)
                if granted { announceAppUpdate?() }
                if !granted { errorMessage = "Allow Waypoint notifications in System Settings to receive update alerts." }
            } catch {
                UserDefaults.standard.set(false, forKey: UpdatePreferences.notificationsKey)
                errorMessage = "Could not enable notifications: \(error.localizedDescription)"
            }
        } else {
            UserDefaults.standard.set(false, forKey: UpdatePreferences.notificationsKey)
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        refreshStatus()
    }

    func sendTestNotification() async {
        guard supportsSystemIntegration, !isTestingNotification,
              UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey) else { return }
        isTestingNotification = true
        defer { isTestingNotification = false }
        errorMessage = nil
        notificationTestStatus = "Sending test notification…"
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            notificationTestStatus = "macOS has blocked notifications. Enable Waypoint in System Settings → Notifications."
            refreshStatus()
            return
        }
        guard UserDefaults.standard.bool(forKey: UpdatePreferences.notificationsKey) else {
            notificationTestStatus = "Test canceled: update notifications were turned off."
            return
        }
        let identifier = "waypoint-notification-test"
        let runID = UUID().uuidString
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.userInfo = ["waypointTestRun": runID]
        content.title = "Waypoint notifications are ready"
        content.body = "You’ll be notified when an installed game update is available."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            // The scheduling acknowledgement precedes delivery. Give the system
            // a moment, then inspect only our own test notification.
            try await Task.sleep(for: .seconds(1))
            let delivered = await center.deliveredNotifications()
            let confirmed = delivered.contains {
                $0.request.identifier == identifier && $0.request.content.userInfo["waypointTestRun"] as? String == runID
            }
            if confirmed {
                notificationTestStatus = "Delivered to Notification Center. Focus and screen sharing can hide the banner."
            } else {
                notificationTestStatus = "Accepted by macOS; no delivery confirmed yet. Check Focus and notification settings, including notifications while sharing the display."
            }
            Log.info(.app, "notification_test", nil, ["delivered": confirmed,
                "alerts_enabled": settings.alertSetting == .enabled])
        } catch {
            notificationTestStatus = "Could not send test notification: \(error.localizedDescription)"
            Log.warning(.app, "notification_test_failed", nil, ["error": error.localizedDescription])
        }
    }

    func setHideDock(_ hidden: Bool) {
        // An explicit menu-only choice also opts into the menu bar. Never leave
        // someone without either the Dock or a status item to reopen Waypoint.
        if hidden { UserDefaults.standard.set(true, forKey: MenuBarItem.defaultsKey) }
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
