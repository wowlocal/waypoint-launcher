import Foundation

/// Which builds of Waypoint a copy updates to: releases, or tip builds
/// (what's next, built from a branch on top of main; see
/// scripts/release.sh). Both are the same app: switching keeps settings and
/// sign-in, and turning tips off goes back to the latest release.
public enum ReleaseChannel: String, Sendable {
    case stable, tip

    public static let stableFeed = "https://storage.yandexcloud.net/macos-releases/waypoint/appcast.xml"
    public static let tipFeed = "https://storage.yandexcloud.net/macos-releases/waypoint/tip/appcast.xml"
    static let preferenceKey = "receivesTipBuilds"

    /// What this copy is, from `WaypointChannel` in its Info.plist.
    public static func running(_ bundle: Bundle = .main) -> ReleaseChannel {
        (bundle.object(forInfoDictionaryKey: "WaypointChannel") as? String).flatMap(ReleaseChannel.init(rawValue:)) ?? .stable
    }

    /// Whether to update to tip builds: what the person chose, else on for
    /// a tip build (someone who installed one wants tips) and off otherwise.
    public static func receivesTips(defaults: UserDefaults = .standard, running: ReleaseChannel = running()) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? (running == .tip)
    }

    /// Off on a release forgets the choice instead of storing it, so a tip
    /// installed later by hand still starts on.
    public static func setReceivesTips(_ on: Bool, defaults: UserDefaults = .standard, running: ReleaseChannel = running()) {
        if !on && running == .stable { defaults.removeObject(forKey: preferenceKey) }
        else { defaults.set(on, forKey: preferenceKey) }
    }

    /// Stores the choice whatever this copy is: for when the next copy to
    /// run is the other kind (a release from the tip feed must stay on tips;
    /// a tip already downloaded after tips were turned off must go back).
    public static func remember(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: preferenceKey)
    }

    public static func feed(receivesTips: Bool) -> String { receivesTips ? tipFeed : stableFeed }

    /// Tip builds are numbered `<release>.<n>` (181.3); releases are whole.
    public static func isTipBuild(_ build: String) -> Bool { build.contains(".") }
}
