import Foundation

/// Reviewed Battle.net titles, not a generic executable launcher. The helper
/// independently allowlists these identifiers and their fixed commands.
public enum WindowsTitle: String, CaseIterable, Sendable {
    case heroes = "hero"
    case overwatch = "pro"
    case diabloII = "osi"
    case diabloIV = "fenris"

    public enum Backend: String, Sendable { case dxmt, d3dMetal }

    public var uid: String {
        switch self { case .heroes: "heroes"; case .overwatch: "prometheus"; default: rawValue }
    }
    public var codename: String {
        switch self {
        case .heroes: "Hero"
        case .overwatch: "Pro"
        case .diabloII: "OSI"
        case .diabloIV: "Fen"
        }
    }
    public var displayName: String {
        switch self {
        case .heroes: "Heroes of the Storm"
        case .overwatch: "Overwatch"
        case .diabloII: "Diablo II: Resurrected"
        case .diabloIV: "Diablo IV"
        }
    }
    public var folderName: String { self == .diabloII ? "Diablo II Resurrected" : displayName }
    public var backend: Backend { self == .heroes ? .dxmt : .d3dMetal }
    /// What the library says after the name: "Windows", or "Windows · Preview"
    /// until gameplay checks have passed.
    public var platformLabel: String { isQualified ? "Windows" : "Windows · Preview" }
    /// How it runs, for a tooltip: the backend is detail, not part of the name.
    public var backendDescription: String {
        backend == .dxmt ? "Runs with Wine and DXMT." : "Runs with Wine and D3DMetal."
    }
    public var executablePath: String {
        switch self {
        case .heroes: "Support64/HeroesSwitcher_x64.exe"
        case .overwatch: "_retail_/Overwatch.exe"
        case .diabloII: "D2R.exe"
        case .diabloIV: "Diablo IV.exe"
        }
    }
    var coreNames: Set<String> {
        switch self {
        case .heroes: ["heroesofthestorm_x64.exe"]
        case .overwatch: ["overwatch.exe"]
        case .diabloII: ["d2r.exe"]
        case .diabloIV: ["diablo iv.exe"]
        }
    }
    var processNames: Set<String> { self == .heroes ? coreNames.union(["heroesswitcher_x64.exe"]) : coreNames }
    var prefixFolder: String {
        // Preserve the released HotS prefix, including recovery after update.
        self == .heroes ? "Heroes" : rawValue
    }
    var dependencyFolder: String {
        switch self { case .heroes: "Support64"; case .overwatch: "_retail_"; default: "" }
    }
    public var launchArguments: [String] {
        switch self {
        case .heroes: ["-sso=1", "-launch", "-uid", "heroes"]
        case .overwatch: ["-uid", "prometheus"]
        case .diabloII: ["-uid", "osi"]
        case .diabloIV: ["-nostreamline", "-sso", "-launch", "-uid", "fenris"]
        }
    }

    /// Preview availability is separate from full gameplay qualification.
    /// Keep the Preview label until broader gameplay checks have passed.
    public var isQualified: Bool { self == .heroes }
    public var isEnabled: Bool { true }
    public static var enabled: [Self] { allCases.filter(\.isEnabled) }

    public static func forInstall(_ install: ProductInstall) -> Self? {
        guard install.platform == .windows, let title = Self(rawValue: install.productCode),
              install.uid == title.uid else { return nil }
        return title
    }

    public var product: InstallableProduct {
        if self == .heroes { return InstallableProduct.native.first { $0.productCode == "hero" }! }
        var locales = InstallableProduct.commonLanguages
        if self != .diabloIV { locales.removeAll { $0 == "zhCN" } }
        locales += ["jaJP"]
        if self != .diabloII { locales += ["trTR"] }
        if self == .overwatch { locales += ["thTH", "zhCN"] }
        return InstallableProduct(uid: uid, productCode: rawValue, displayName: displayName,
            folderName: folderName, codename: codename, appPath: "", launchArguments: launchArguments,
            flavorFolder: self == .overwatch ? "_retail_" : nil, isContainerless: false, languages: locales,
            artwork: ProductCatalog.shared.windowsArtwork(productCode: rawValue))
    }

    var minimumOS: OperatingSystemVersion {
        // Preserve HotS's qualified host range. Recall documents 26.5 as the
        // Overwatch minimum: https://github.com/AsherJN/recall#Get-started
        self != .heroes
            ? OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
            : OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    }
    public var isHostSupported: Bool {
        #if arch(arm64)
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS) && Rosetta.isInstalled
        #else
        false
        #endif
    }
    public var isAvailable: Bool {
        isEnabled && isHostSupported && WindowsRuntime.resources != nil &&
            (self == .heroes || WindowsRuntime.bridgeResources != nil) &&
            (backend != .d3dMetal || WindowsGraphics.resources != nil)
    }

    func environment(prefix: URL, wineRoot: URL, display: WindowsDisplay?, graphics: URL? = nil) -> [String: String] {
        let excluded = self == .heroes ? ["WINE", "CX_", "DYLD_", "DXMT", "MTL_HUD"]
            : ["WINE", "CX_", "DYLD_", "DXMT", "MTL_", "D3DM_", "ROSETTA_"]
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !excluded.contains(where: key.hasPrefix)
        }
        env.merge([
            "WINEPREFIX": prefix.path, "WINEARCH": "win64", "WINEDEBUG": "-all",
            "WINEMSYNC": "1", "WINE_SIMULATE_WRITECOPY": "1", "MTL_HUD_ENABLED": "0",
            "DXMT_LOG_LEVEL": "error", "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree,mshtml=d;d3d11,dxgi,winemetal=b",
            "DYLD_LIBRARY_PATH": "\(wineRoot.path)/lib:\(wineRoot.path)/lib/wine/x86_64-unix",
            "DXMT_CONFIG": "dxgi.customVendorId=1002;dxgi.customDeviceId=6810;d3d11.preferredMaxFrameRate=\(display?.framesPerSecond ?? 120);",
        ]) { _, value in value }
        if self != .heroes {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
            env["WINEESYNC"] = "0"
            // Adapter spoofing and the HotS frame cap are not game defaults.
            env["DXMT_CONFIG"] = nil
        }
        if self == .overwatch {
            env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml=d;d3d11,dxgi,d3d10core,winemetal=b;d3d12,d3d12core,nvapi64,nvngx=d"
        }
        if backend == .d3dMetal, graphics != nil {
            // The complete overlay resolves its own DLLs. WINEDLLPATH also
            // enables Wine's temporary renamed-loader link on macOS, which
            // would move the process outside our immutable engine directory.
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib").path
            if self == .overwatch {
                // The same-prefix launch control reaches SMS Protect with
                // Metal DX11; DXMT stalls before creating its first window.
                env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml=d;dxgi,d3d11,atidxx64=n,b;d3d12,d3d12core,nvapi64,nvngx=d"
            } else {
                env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree,mshtml=d;dxgi,d3d11,d3d12,atidxx64=n,b;nvapi64,nvngx=d"
            }
            env["D3DM_ENABLE_METALFX"] = "0"
        }
        return env
    }
}
