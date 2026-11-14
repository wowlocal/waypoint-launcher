import Foundation
import Testing
import CryptoKit
@testable import WaypointCore

private func windowsFixture(_ title: WindowsTitle) throws -> Data {
    let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WindowsProducts")
    return try Data(contentsOf: root.appendingPathComponent(title.rawValue + ".json"))
}

@Test func windowsProfilesMatchBlizzardProductConfiguration() throws {
    for title in [WindowsTitle.overwatch, .diabloII, .diabloIV] {
        let data = try windowsFixture(title)
        let config = try ProductConfig(json: data, platform: .windows)
        let path = [config.subfolder, try #require(config.gameBinary)].filter { !$0.isEmpty }.joined(separator: "/")
        #expect(path == title.executablePath)
        #expect(title.launchArguments.starts(with: config.launchArguments))
        #expect(InstallPlatform.from(tags: config.tagString(region: .eu, language: "enUS")) == .windows)
        #expect(Set(config.supportedLocales) == Set(title.product.languages))
        #expect(!config.isContainerless)
        #expect(title.product.supportedPlatforms == [.windows])
    }
}

@Test func windowsOnlyProfilesCannotBecomeNativeGamesOrCrossTitleInstalls() {
    for title in WindowsTitle.allCases {
        let win = ProductInstall(uid: title.uid, productCode: title.rawValue, installPath: "/not-installed", platform: .windows)
        #expect(WindowsTitle.forInstall(win) == title)
        let wrong = ProductInstall(uid: title.uid + "-other", productCode: title.rawValue, installPath: "/not-installed", platform: .windows)
        #expect(WindowsTitle.forInstall(wrong) == nil)
        let native = ProductInstall(uid: title.uid, productCode: title.rawValue, installPath: "/not-installed")
        #expect(WindowsTitle.forInstall(native) == nil)
        if title != .heroes { #expect(!GameUpdate.canUpdate(native)) }
    }
    #expect(WindowsTitle.forInstall(ProductInstall(uid: "wow", productCode: "wow", installPath: "/not-installed", platform: .windows)) == nil)
}

@Test func publicWindowsPreviewsRemainDistinctFromQualifiedProfiles() {
    #expect(WindowsTitle.heroes.isEnabled)
    #expect(WindowsTitle.heroes.isQualified)
    #expect(WindowsTitle.heroes.minimumOS.majorVersion == 15)
    for title in [WindowsTitle.overwatch, .diabloII, .diabloIV] {
        #expect(title.minimumOS.majorVersion == 26)
        #expect(title.minimumOS.minorVersion == 5)
        #expect(!title.isQualified)
    }
    for title in [WindowsTitle.overwatch, .diabloII, .diabloIV] {
        #expect(title.isEnabled)
        #expect(InstallableProduct.forProduct(title.rawValue) != nil)
        #expect(GameLibrary.defaultSearchRoots.contains { $0.lastPathComponent == title.folderName + " (Windows)" })
    }
}

@Test func overwatchTagsCannotBeClaimedByTheNativeInstaller() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let win = ProductInstall(uid: "pro", productCode: "pro", installPath: root.path, tagString: "TPWin SPWin DX11 EU? enUS text?", platform: .windows)
    try win.platform.claim(install: win)
    let mac = ProductInstall(uid: "pro", productCode: "pro", installPath: root.path, tagString: win.tagString)
    #expect(throws: (any Error).self) { try mac.platform.claim(install: mac) }
    #expect(InstallPlatform.from(tags: "OSX SPWin") == nil)
    #expect(InstallPlatform.from(tags: "SPWin TPWin") == .windows)
    #expect(InstallPlatform.from(tags: "DX11") == nil)
}

@Test func titleHandoffFramesKeepLegacyBytesAndIsolateOtherGames() throws {
    let token = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-1"))
    #expect(String(decoding: try WindowsLaunchOptions.frame(token: token, region: .eu, locale: "enUS", launch: true), as: UTF8.self)
        == "WAYPOINT-HERO-LAUNCH-1\n\(token.value)\nEU\nenUS\n")
    for title in [WindowsTitle.overwatch, .diabloII, .diabloIV] {
        let frame = try WindowsLaunchOptions.frame(token: token, region: .eu, locale: "enUS", launch: true, title: title)
        #expect(String(decoding: frame, as: UTF8.self) == "WAYPOINT-WINDOWS-2\n\(title.rawValue)\nlaunch\n\(token.value)\nEU\nenUS\n")
        #expect(throws: (any Error).self) {
            try WindowsLaunchOptions.frame(token: token, region: .eu, locale: "enUS\nlaunch", title: title)
        }
    }
}

@Test func titleEnvironmentsDoNotShareHotSRenderingOverrides() {
    let prefix = URL(fileURLWithPath: "/private/test/prefix"), wine = URL(fileURLWithPath: "/private/test/wine")
    let display = WindowsDisplay(width: 3456, height: 2234, framesPerSecond: 120)
    let hero = WindowsTitle.heroes.environment(prefix: prefix, wineRoot: wine, display: display)
    #expect(hero["DXMT_CONFIG"] == "dxgi.customVendorId=1002;dxgi.customDeviceId=6810;d3d11.preferredMaxFrameRate=120;")
    #expect(hero["WINEMSYNC"] == "1")
    let ow = WindowsTitle.overwatch.environment(prefix: prefix, wineRoot: wine, display: display)
    #expect(ow["DXMT_CONFIG"] == nil)
    #expect(ow["WINEDLLOVERRIDES"]?.contains("d3d12,d3d12core,nvapi64,nvngx=d") == true)
    let metal = URL(fileURLWithPath: "/private/test/apple-graphics")
    let owMetal = WindowsTitle.overwatch.environment(prefix: prefix, wineRoot: wine, display: display, graphics: metal)
    #expect(WindowsTitle.heroes.backend == .dxmt)
    #expect(WindowsTitle.overwatch.backend == .d3dMetal)
    #expect(owMetal["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == wine.appendingPathComponent("lib/external/libd3dshared.dylib").path)
    #expect(owMetal["WINEDLLOVERRIDES"]?.contains("dxgi,d3d11,atidxx64=n,b") == true)
    #expect(owMetal["WINEDLLOVERRIDES"]?.contains("d3d12,d3d12core,nvapi64,nvngx=d") == true)
    let d4 = WindowsTitle.diabloIV.environment(prefix: prefix, wineRoot: wine, display: display, graphics: metal)
    #expect(d4["DXMT_CONFIG"] == nil)
    #expect(d4["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == wine.appendingPathComponent("lib/external/libd3dshared.dylib").path)
    #expect(d4["WINEDLLPATH"] == nil)
    #expect(d4["WINEDLLOVERRIDES"]?.contains("dxgi,d3d11,d3d12,atidxx64=n,b") == true)
    #expect(d4["ROSETTA_ADVERTISE_AVX"] == "1")
    for title in WindowsTitle.allCases {
        let environment = title.environment(prefix: prefix, wineRoot: wine, display: display, graphics: metal)
        #expect(environment["WINEDLLPATH"] == nil)
        #expect(environment["WINELOADER"] == nil)
    }
}

@Test func windowsSessionLeaseSurvivesAcrossTitlesAndReleasesAfterFailedPreparation() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func target(_ title: WindowsTitle) -> WindowsLaunchTarget {
        WindowsLaunchTarget(install: ProductInstall(uid: title.uid, productCode: title.rawValue,
            installPath: root.appendingPathComponent(title.rawValue).path, platform: .windows), resources: root, display: nil)
    }
    let hero = try WindowsGameSession(target: target(.heroes), supportRoot: root)
    #expect(throws: (any Error).self) { try WindowsGameSession(target: target(.overwatch), supportRoot: root) }
    await hero.preparationFailed()
    let ow = try WindowsGameSession(target: target(.overwatch), supportRoot: root)
    #expect(fm.fileExists(atPath: root.appendingPathComponent("Windows/Heroes/launch.lock").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("Windows/pro/launch.lock").path))
    await ow.preparationFailed()
}

@Test func helperCacheAuthenticatesRepairsAndDoesNotFollowReplacedFiles() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let resources = root.appendingPathComponent("bundle"), cache = root.appendingPathComponent("cache")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let bytes = Data("MZ synthetic bridge fixture".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try JSONSerialization.data(withJSONObject: ["schema": 2, "sha256": hash]).write(to: resources.appendingPathComponent("manifest.json"))
    let source = resources.appendingPathComponent("waypoint-launch-options.exe")
    try Data("corrupted".utf8).write(to: source)
    #expect(throws: (any Error).self) { try WindowsBridge.install(from: resources, cache: cache) }
    #expect(!fm.fileExists(atPath: cache.path))
    try bytes.write(to: source)
    let installed = try WindowsBridge.install(from: resources, cache: cache)
    let outside = root.appendingPathComponent("user-file")
    try Data("preserve this".utf8).write(to: outside)
    try fm.removeItem(at: installed)
    try fm.createSymbolicLink(at: installed, withDestinationURL: outside)
    #expect(try WindowsBridge.install(from: resources, cache: cache) == installed)
    #expect(try Data(contentsOf: outside) == Data("preserve this".utf8))
    #expect(try Data(contentsOf: installed) == bytes)
    try fm.removeItem(at: resources)
    #expect(try Data(contentsOf: installed) == bytes)
}

@Test func namesSayWindowsAndKeepTheBackendForTooltips() {
    #expect(WindowsTitle.overwatch.product.displayName(on: .windows) == "Overwatch (Windows · Preview)")
    #expect(WindowsTitle.diabloIV.product.displayName(on: .windows) == "Diablo IV (Windows · Preview)")
    #expect(WindowsTitle.diabloII.product.displayName(on: .windows) == "Diablo II: Resurrected (Windows · Preview)")
    #expect(WindowsTitle.heroes.product.displayName(on: .windows) == "Heroes of the Storm (Windows)")
    #expect(WindowsTitle.heroes.backendDescription == "Runs with Wine and DXMT.")
    for title in WindowsTitle.allCases where title != .heroes {
        #expect(title.backendDescription == "Runs with Wine and D3DMetal.")
        #expect(title.product.onlyPlatform == .windows)
    }
    for title in WindowsTitle.allCases {
        let product = title.product
        #expect(product.windowsTitle == title)
        #expect(product.uid == title.uid)
        #expect(!product.displayName(on: .windows).contains("Wine"))
    }
}

@Test func heroesIsNamedPlainlyUntilItsEditionIsChosen() {
    let heroes = WindowsTitle.heroes.product
    // The install sheet offers both editions: the row doesn't pick one.
    #expect(heroes.onlyPlatform == nil)
    #expect(heroes.displayName(on: heroes.onlyPlatform) == "Heroes of the Storm")
    #expect(heroes.displayName(on: .macOS) == "Heroes of the Storm")
}

@Test func nativeGamesKeepTheirNames() {
    let wow = InstallableProduct.native.first { $0.productCode == "wow" }!
    #expect(wow.onlyPlatform == .macOS)
    #expect(wow.windowsTitle == nil)
    for platform: InstallPlatform? in [nil, .macOS, .windows] {
        #expect(wow.displayName(on: platform) == wow.displayName)
    }
}
