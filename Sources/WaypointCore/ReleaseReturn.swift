import CryptoKit
import Foundation
import Security

/// Going back from a tip build to the latest release when tips are turned
/// off. Sparkle refuses an update with a lower build number, and a release
/// is lower than the tips after it (181 < 181.3), so Waypoint does this one
/// itself, with Sparkle's checks: the release's EdDSA signature from the
/// release feed, then a valid Developer ID signature by the same team, for
/// the same app and build. The new copy replaces this one when Waypoint
/// quits, by Waypoint's own (team-signed) executable, as macOS requires for
/// changing a notarized app.
public enum ReleaseReturn {
    public struct Release: Equatable, Sendable {
        public var version: String
        public var build: String
        public var url: URL
        public var signature: String
        public var length: Int?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noRelease, badArchive, badSignature, badCodeSignature, notInstallable

        public var errorDescription: String? {
            switch self {
            case .noRelease: "Couldn’t find the latest release."
            case .badArchive, .badSignature, .badCodeSignature: "The release download couldn’t be verified. Try again later."
            case .notInstallable: "Waypoint can’t replace itself here. Download the latest release from GitHub."
            }
        }
    }

    // MARK: Feed

    /// The newest item in a Sparkle appcast, as `generate_appcast` writes it.
    static func latest(in appcast: Data) -> Release? {
        let reader = AppcastReader()
        let parser = XMLParser(data: appcast)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return reader.items.max { $0.build.compare($1.build, options: .numeric) == .orderedAscending }
    }

    public static func latest(feed: URL, session: URLSession = .shared) async throws -> Release {
        let (data, response) = try await session.data(from: feed)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let release = latest(in: data),
              release.url.scheme == "https", release.url.host == feed.host,
              release.url.standardized.path.hasPrefix(feed.deletingLastPathComponent().standardized.path + "/") else { throw Failure.noRelease }
        return release
    }

    private final class AppcastReader: NSObject, XMLParserDelegate {
        var items: [Release] = []
        private var inItem = false
        private var text = ""
        private var version = "", build = "", url: URL?, signature = "", length: Int?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item":
                inItem = true
                (version, build, url, signature, length) = ("", "", nil, "", nil)
            case "enclosure" where inItem:
                url = attributes["url"].flatMap(URL.init(string:))
                signature = attributes["sparkle:edSignature"] ?? ""
                length = attributes["length"].flatMap { Int($0) }
                if let v = attributes["sparkle:version"] { build = v }
                if let v = attributes["sparkle:shortVersionString"] { version = v }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard inItem else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version": build = value
            case "sparkle:shortVersionString": version = value
            case "item":
                inItem = false
                if let url, !build.isEmpty, !signature.isEmpty {
                    items.append(Release(version: version.isEmpty ? build : version, build: build, url: url,
                                         signature: signature, length: length))
                }
            default: break
            }
        }
    }

    // MARK: Checks

    /// Sparkle's EdDSA check: `signature` (base64) over the whole file, by
    /// the key whose public half (base64) is `SUPublicEDKey`.
    static func verify(_ file: URL, signature: String, publicKey: String) throws {
        guard let key = Data(base64Encoded: publicKey), let signature = Data(base64Encoded: signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { throw Failure.badSignature }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard publicKey.isValidSignature(signature, for: data) else { throw Failure.badSignature }
    }

    /// The team that signed this running copy, if it's Developer ID signed.
    public static func runningTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return team(of: staticCode)
    }

    private static func team(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A valid, strict Developer ID signature (nested code too) by `team`,
    /// for the app `identifier`.
    static func verifyCodeSignature(_ app: URL, team: String, identifier: String = "dev.waypoint.launcher") throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.badCodeSignature }
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { throw Failure.badCodeSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess, self.team(of: code) == team else {
            throw Failure.badCodeSignature
        }
    }

    // MARK: Preparing

    /// Downloads the release, checks it, and copies its app next to `bundle`
    /// (same volume) ready to swap in. Returns the staged app.
    public static func prepare(_ release: Release, publicKey: String, team: String, replacing bundle: URL,
                               session: URLSession = .shared) async throws -> URL {
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw Failure.notInstallable }
        let (download, response) = try await session.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noRelease }
        if let length = release.length,
           (try? download.resourceValues(forKeys: [.fileSizeKey]).fileSize) != length { throw Failure.badArchive }
        try verify(download, signature: release.signature, publicKey: publicKey)

        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: bundle, create: true)
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        let staged = work.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
        do {
            try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, download.path])
            do {
                try await run("/usr/bin/ditto", [mount.appendingPathComponent("Waypoint.app").path, staged.path])
            } catch {
                // Detached even when cancelled: never leave the image mounted.
                try? await run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path], always: true)
                throw error is CancellationError ? error : Failure.badArchive
            }
            try? await run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path], always: true)
            try Task.checkCancellation()
            try verifyCodeSignature(staged, team: team)
            let build = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            guard build == release.build else { throw Failure.badArchive }
        } catch {
            // However far it got (an attach cut short too): unmount, clean up.
            try? await run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path], always: true)
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        Log.info(.selfUpdate, "release_return_ready", nil, ["version": release.version, "build": release.build])
        return staged
    }

    private static func run(_ tool: String, _ arguments: [String], always: Bool = false) async throws {
        try await ChildCommand.run(executable: URL(fileURLWithPath: tool), arguments: arguments,
                                   directory: URL(fileURLWithPath: "/"), environment: [:], timeout: 120,
                                   completeOnCancellation: always)
    }

    // MARK: Swapping

    static let swapArgument = "--waypoint-swap-release"

    /// Starts this app's own executable to put `staged` in place of
    /// `target` once this process has quit, then open it if `relaunch`.
    /// Call it as Waypoint terminates.
    public static func swapAfterQuit(staged: URL, target: URL, relaunch: Bool) throws {
        guard let executable = Bundle.main.executableURL else { throw Failure.notInstallable }
        _ = try Spawn.detached(executable: executable,
                               arguments: [swapArgument, String(getpid()), staged.path, target.path, relaunch ? "1" : "0"],
                               workingDirectory: URL(fileURLWithPath: "/"))
        Log.notice(.selfUpdate, "release_return_swap_scheduled", nil, ["relaunch": relaunch])
    }

    /// Whether this process was started to do a swap (see `swapAfterQuit`).
    public static func isSwapRequest(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.count == 6 && arguments[1] == swapArgument
    }

    /// The swap itself, before any UI: wait for the old process, move the
    /// old app into the staging folder, the new one into its place (or put
    /// the old one back), delete the old one, forget the tips choice (this
    /// copy is a release now), and open the result if asked.
    public static func performSwap(_ arguments: [String] = CommandLine.arguments) -> Never {
        let pid = pid_t(arguments[2]) ?? 0
        let staged = URL(fileURLWithPath: arguments[3]), target = URL(fileURLWithPath: arguments[4])
        let relaunch = arguments[5] == "1"
        // Up to ten minutes for Waypoint to finish quitting.
        for _ in 0..<3000 where pid > 0 && kill(pid, 0) == 0 { usleep(200_000) }
        // This app's defaults, resolved before the bundle moves.
        let defaults = UserDefaults.standard
        _ = Bundle.main.bundleIdentifier
        // One atomic exchange: there's never a moment without an app.
        let swapped = renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0
        Log.notice(.selfUpdate, swapped ? "release_return_swapped" : "release_return_swap_failed", nil,
                   swapped ? [:] : ["errno": errno])
        if swapped {
            // The old app is in the staging folder now.
            defaults.removeObject(forKey: ReleaseChannel.preferenceKey)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
        Diagnostics.shared.flush()
        if relaunch {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [target.path]
            try? open.run()
            open.waitUntilExit()
        }
        exit(swapped ? 0 : 1)
    }
}
