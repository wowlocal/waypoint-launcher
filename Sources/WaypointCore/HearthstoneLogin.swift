import CryptoKit
import Darwin
import Foundation

/// The client writes a per-launch Login.log. Process creation alone says
/// nothing about whether the game accepted the handoff.
public enum HearthstoneLogin {
    public enum Outcome: String, Sendable {
        case signedIn = "signed_in"
        case challengeExhausted = "challenge_exhausted"
    }

    public struct Observation: Sendable {
        public let outcome: Outcome?
        public let handoffMatches: Bool?
        public let otherLauncher: Bool?

        var isAttributable: Bool {
            handoffMatches == true && otherLauncher == false
        }

        public var permitsRecovery: Bool {
            outcome == .challengeExhausted && isAttributable
        }
    }

    public static func check(pid: pid_t, in root: URL, launchedAt: Date, options: LaunchOptions,
                             token: LoginToken, region: Region, timeout: Duration = .seconds(15),
                             otherLauncherAtHandoff: Bool,
                             hasOtherLauncher: @Sendable () -> Bool) async -> Observation {
        let (outcome, otherLauncher) = await observe(pid: pid, in: root, launchedAt: launchedAt, timeout: timeout,
                                                   otherLauncherAtHandoff: otherLauncherAtHandoff,
                                                   hasOtherLauncher: hasOtherLauncher)
        guard let outcome else {
            return Observation(outcome: nil, handoffMatches: nil, otherLauncher: nil)
        }
        return Observation(outcome: outcome, handoffMatches: options.matchesHandoff(token: token, region: region),
                           otherLauncher: otherLauncher || hasOtherLauncher())
    }

    /// Bounded and off the main actor. A missing or unfamiliar log is inconclusive.
    static func observe(pid: pid_t, in root: URL, launchedAt: Date, timeout: Duration = .seconds(15),
                        otherLauncherAtHandoff: Bool = false,
                        hasOtherLauncher: @Sendable () -> Bool = { false }) async -> (Outcome?, Bool) {
        let logs = root.appendingPathComponent("Logs").resolvingSymlinksInPath()
        let deadline = ContinuousClock.now + timeout
        var nextLauncherCheck = ContinuousClock.now
        var otherLauncher = otherLauncherAtHandoff
        var log: FileHandle?
        defer { try? log?.close() }
        while true {
            if !otherLauncher, ContinuousClock.now >= nextLauncherCheck {
                otherLauncher = hasOtherLauncher()
                nextLauncherCheck = ContinuousClock.now + .seconds(1)
            }
            let running = kill(pid, 0) == 0
            if log == nil, running { log = openLog(pid: pid, in: logs, launchedAt: launchedAt) }
            var observed: Outcome?
            if let log {
                do {
                    try log.seek(toOffset: 0)
                    let limit = 16 * 1024
                    if let data = try log.read(upToCount: limit) {
                        observed = outcome(in: data)
                        if observed == .signedIn { return (.signedIn, otherLauncher) }
                        if data.count == limit { return (nil, otherLauncher) }
                    }
                } catch { return (nil, otherLauncher) }
            }
            // A later successful login supersedes an earlier exhausted
            // challenge, including when it arrives in a separate write.
            if !running || ContinuousClock.now >= deadline { return (observed, otherLauncher) }
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return (nil, otherLauncher) }
        }
    }

    static func outcome(in data: Data) -> Outcome? {
        guard let newline = data.lastIndex(of: 0x0a) else { return nil }
        let text = String(decoding: data[...newline], as: UTF8.self)
        var repeated = false
        var exhausted = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3 else { continue }
            switch fields[2] {
            case "We are now logged in, stopping processing challenges":
                return .signedIn
            case "A repeated token was retrieved when disallowed. Setting to null token for failure":
                repeated = true
            case "Failed to get token to respond to login challenge" where repeated:
                exhausted = true
            default: break
            }
        }
        return exhausted ? .challengeExhausted : nil
    }

    /// The timestamp in the directory name is only precise to a second.
    /// Use the game's own open descriptor and verify the inode we open.
    private static func openLog(pid: pid_t, in logs: URL, launchedAt: Date) -> FileHandle? {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 512)
        let size = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard size > 0 else { return nil }
        for descriptor in descriptors.prefix(Int(size) / MemoryLayout<proc_fdinfo>.stride)
            where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let length = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, length) == length,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let node = info.pvip.vip_vi.vi_stat
            let created = TimeInterval(node.vst_birthtime) + TimeInterval(node.vst_birthtimensec) / 1_000_000_000
            // Some volumes store creation dates to whole seconds. The client
            // must still have this file open for writing.
            let sameSecondOnCoarseVolume = node.vst_birthtimensec == 0
                && node.vst_birthtime == Int64(launchedAt.timeIntervalSince1970)
            guard created >= launchedAt.timeIntervalSince1970 || sameSecondOnCoarseVolume else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard path.hasSuffix("/Login.log") else { continue }
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent()
            guard folder.lastPathComponent.hasPrefix("Hearthstone_"),
                  folder.deletingLastPathComponent().resolvingSymlinksInPath().path == logs.path else { continue }
            let file = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { continue }
            var metadata = stat()
            if fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
               metadata.st_ino == node.vst_ino, UInt32(bitPattern: metadata.st_dev) == node.vst_dev {
                return FileHandle(fileDescriptor: file, closeOnDealloc: true)
            }
            close(file)
        }
        return nil
    }
}

/// Remembers a rejected Hearthstone handoff per account and play region.
/// Only a hash of the exact token is stored outside the vault.
public struct HearthstoneLoginRecovery: Codable, Equatable {
    enum Action: Equatable {
        case refresh, signInAgain
    }

    public enum Play: Equatable {
        case useCached(LoginToken)
        case signIn(replacing: LoginToken?)
        case signInAgain
    }

    private struct Rejection: Codable, Equatable {
        var fingerprint: Data
        var needsManualSignIn: Bool
    }

    private var rejections: [String: [Region: Rejection]] = [:]

    public func nextPlay(cached: LoginToken?, region: Region) -> Play {
        guard let cached else { return .signIn(replacing: nil) }
        switch action(for: cached, region: region) {
        case .refresh: return .signIn(replacing: cached)
        case .signInAgain: return .signInAgain
        case nil: return .useCached(cached)
        }
    }

    func action(for token: LoginToken, region: Region) -> Action? {
        guard let rejection = rejections[token.accountID]?[region],
              rejection.fingerprint == Self.fingerprint(token) else { return nil }
        return rejection.needsManualSignIn ? .signInAgain : .refresh
    }

    public mutating func record(_ observation: HearthstoneLogin.Observation, for token: LoginToken,
                                region: Region, usedCache: Bool, saved: Bool, replacing rejected: LoginToken?) {
        guard observation.isAttributable else { return }
        if observation.outcome == .signedIn {
            clear(for: token, region: region)
        } else if observation.permitsRecovery {
            recordRejection(of: token, region: region, usedCache: usedCache, saved: saved, replacing: rejected)
        }
    }

    public mutating func reject(_ token: LoginToken, region: Region, needsManualSignIn: Bool) {
        rejections[token.accountID, default: [:]][region] = Rejection(
            fingerprint: Self.fingerprint(token), needsManualSignIn: needsManualSignIn)
    }

    mutating func recordRejection(of token: LoginToken, region: Region, usedCache: Bool, saved: Bool,
                                  replacing rejected: LoginToken?) {
        if saved {
            reject(token, region: region, needsManualSignIn: !usedCache)
        } else if let rejected, action(for: rejected, region: region) == .refresh {
            // The next Play may still find the old token if Keychain couldn't
            // save its replacement. One failed refresh is enough.
            reject(rejected, region: region, needsManualSignIn: true)
        }
    }

    mutating func clear(for token: LoginToken, region: Region) {
        guard action(for: token, region: region) != nil else { return }
        rejections[token.accountID]?[region] = nil
        if rejections[token.accountID]?.isEmpty == true { remove(owner: token.accountID) }
    }

    public mutating func remove(owner: String) {
        rejections.removeValue(forKey: owner)
    }

    private static func fingerprint(_ token: LoginToken) -> Data {
        Data(SHA256.hash(data: Data(token.value.utf8)))
    }

    // The earlier test build wrote markers without checking the handoff.
    private static let defaultsKey = "verifiedHearthstoneLoginRecovery"

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let store = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return store
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
