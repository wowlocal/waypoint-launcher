import Foundation
import Testing
@testable import WaypointCore

private let sampleToken = "US-0123456789abcdef0123456789abcdef-123456789"

@Test func cipherMatchesReferenceImplementation() throws {
    // Expected bytes computed independently with hashlib.pbkdf2_hmac + `openssl enc -aes-128-cbc`.
    let expected = "eaf1d64a585191b2d1544912b0041d0d34b9f4506cc2337d83bf0acb22397d6a4164b9bce5b47562d2de8c1b5c638d92"
    let cipher = TokenCipher(userName: "testuser")
    let encrypted = try cipher.encrypt(sampleToken)
    #expect(encrypted.map { String(format: "%02x", $0) }.joined() == expected)
    #expect(try cipher.decrypt(encrypted) == sampleToken)
}

@Test func cipherIsBoundToUserName() throws {
    let encrypted = try TokenCipher(userName: "alice").encrypt(sampleToken)
    let other = try? TokenCipher(userName: "bob").decrypt(encrypted)
    #expect(other != sampleToken)
}

@Test func parsesLoginTokens() {
    #expect(LoginToken(sampleToken)?.accountID == "123456789")
    #expect(LoginToken("EU-0123456789ABCDEF0123456789ABCDEF-1") != nil)
    #expect(LoginToken("US-0123-123") == nil)
    #expect(LoginToken("USA-0123456789abcdef0123456789abcdef-1") == nil)
    #expect(LoginToken("US-0123456789abcdef0123456789abcdef-") == nil)
    #expect(LoginToken("US-0123456789abcdef0123456789abcdeg-1") == nil)
}

@Test func extractsTokenFromLoginRedirect() throws {
    let url = try #require(URL(string: "http://localhost:0/?ST=\(sampleToken)&accountId=123456789&flowTrackingId=&flow_type=hard_account_login"))
    #expect(BattleNetLogin.token(fromCallback: url)?.value == sampleToken)
    let elsewhere = try #require(URL(string: "https://eu.battle.net/login/en/?ST=\(sampleToken)"))
    #expect(BattleNetLogin.token(fromCallback: elsewhere) == nil)
}

@Test func loginURLs() {
    #expect(BattleNetLogin.url(codename: "WTCG", region: .eu).absoluteString
            == "https://eu.battle.net/login/en/?externalChallenge=login&app=WTCG")
    #expect(BattleNetLogin.url(codename: "WoW", region: .cn).host == "account.battlenet.com.cn")
}

/// Builds a fake game install with an app bundle that Bundle can resolve.
private func makeFakeApp(at url: URL, executable: String, arch: String = "arm64") throws {
    let fm = FileManager.default
    let macOS = url.appendingPathComponent("Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": "test.\(executable.filter(\.isLetter))"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    // A real Mach-O so Bundle can report its architectures.
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent(executable))
}

@Test func hearthstoneLaunchPlanMatchesBattleNet() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-hs-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try makeFakeApp(at: root.appendingPathComponent("Hearthstone.app"), executable: "Hearthstone")

    let install = ProductInstall(uid: "hs_beta", productCode: "hsb", installPath: root.path, region: "eu", textLanguage: "enUS")
    let game = GameCatalog.game(for: install)
    #expect(game.isSupported)

    let plan = try GameLauncher.plan(for: game)
    #expect(plan.arguments == ["-launch", "-uid", "hs_beta"])
    #expect(plan.workingDirectory.standardizedFileURL == root.standardizedFileURL)
    #expect(plan.executable.lastPathComponent == "Hearthstone")
    #expect(plan.codename == "WTCG")
    #expect(plan.region == .eu)
    #expect(plan.locale == "enUS")

    #expect(try GameLauncher.plan(for: game, region: .us).region == .us)
}

@Test func wowLaunchPlanUsesFlavorFolder() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-wow-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try makeFakeApp(at: root.appendingPathComponent("_classic_era_/World of Warcraft Classic.app"), executable: "World of Warcraft Classic")

    let install = ProductInstall(uid: "wow_classic_era", productCode: "wow_classic_era", installPath: root.path, region: "eu", textLanguage: "ruRU")
    let plan = try GameLauncher.plan(for: GameCatalog.game(for: install))
    #expect(plan.arguments == ["-launcherlogin", "-uid", "wow_classic_era"])
    #expect(plan.workingDirectory.lastPathComponent == "_classic_era_")
    #expect(plan.codename == "WoW")
    #expect(plan.locale == "ruRU")
}

@Test func refusesGamesWeCannotRun() {
    let missing = GameCatalog.game(for: ProductInstall(uid: "wow", productCode: "wow", installPath: "/nonexistent"))
    #expect(throws: LaunchError.self) { try GameLauncher.plan(for: missing) }
}

@Test func warcraftAndStarCraftLaunchLikeTheirProductConfigs() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-casc-games-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    try makeFakeApp(at: root.appendingPathComponent("_retail_/x86_64/Warcraft III.app"), executable: "Warcraft III")
    try makeFakeApp(at: root.appendingPathComponent("Support/SC2Switcher.app"), executable: "SC2Switcher")

    let w3 = GameCatalog.game(for: ProductInstall(uid: "w3", productCode: "w3", installPath: root.path, region: "eu", textLanguage: "enUS"))
    #expect(w3.displayName == "Warcraft III")
    let w3Plan = try GameLauncher.plan(for: w3)
    #expect(w3Plan.arguments == ["-launch", "-uid", "w3"])
    #expect(w3Plan.workingDirectory.lastPathComponent == "_retail_")
    #expect(w3Plan.codename == "W3")

    let s2 = GameCatalog.game(for: ProductInstall(uid: "s2", productCode: "s2", installPath: root.path, region: "us"))
    #expect(s2.appURL?.lastPathComponent == "SC2Switcher.app")
    let s2Plan = try GameLauncher.plan(for: s2)
    #expect(s2Plan.codename == "S2")
    #expect(s2Plan.workingDirectory.standardizedFileURL == root.standardizedFileURL)
}
