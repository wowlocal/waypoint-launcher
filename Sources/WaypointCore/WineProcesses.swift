import Foundation
import Darwin

/// Wine's macOS executable is its loader, and its game has no .app bundle.
/// Match the actual HotS core by loader, game directory and Windows argv.
public enum WineProcesses {
    private static let loaders: Set<String> = ["wine", "wine64", "wine-preloader", "wine64-preloader"]

    /// Asked of every process on the Mac, so it compares the name without
    /// building a URL for each.
    static func isLoader(_ path: String) -> Bool {
        let bytes = path.utf8
        let name = bytes.lastIndex(of: UInt8(ascii: "/")).map { bytes[bytes.index(after: $0)...] } ?? bytes[...]
        return loaders.contains(String(Substring(name)))
    }

    public static func heroes(in directory: URL, runtime: URL? = nil) -> [Int32] {
        matching(in: directory, runtime: runtime, names: ["heroesofthestorm_x64.exe"])
    }

    public static func heroesAndSwitcher(in directory: URL, runtime: URL? = nil) -> [Int32] {
        matching(in: directory, runtime: runtime, names: ["heroesofthestorm_x64.exe", "heroesswitcher_x64.exe"])
    }

    public static func gameCore(in directory: URL, title: WindowsTitle, runtime: URL? = nil) -> [Int32] {
        matching(in: directory, runtime: runtime, names: title.coreNames)
    }

    /// `processes`: a list from `RunningProcesses.executables()` to look in,
    /// so asking about several games reads the process list once.
    public static func gameAndLaunchers(in directory: URL, title: WindowsTitle, runtime: URL? = nil,
                                        processes: [(pid: pid_t, path: String)]? = nil) -> [Int32] {
        matching(in: directory, runtime: runtime, names: title.processNames, processes: processes)
    }

    static func ownedGames(runtimeCache: URL) -> [Int32] {
        matching(in: nil, runtime: runtimeCache, names: Set(WindowsTitle.allCases.flatMap(\.processNames)))
    }

    static func ownedHeroesAndSwitcher(runtimeCache: URL) -> [Int32] {
        matching(in: nil, runtime: runtimeCache, names: ["heroesofthestorm_x64.exe", "heroesswitcher_x64.exe"])
    }

    private static func matching(in directory: URL?, runtime: URL?, names: Set<String>,
                                 processes: [(pid: pid_t, path: String)]? = nil) -> [Int32] {
        let root = directory?.resolvingSymlinksInPath().standardizedFileURL.path
        let runtimePath = runtime.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
        return (processes ?? RunningProcesses.executables()).compactMap { process in
            guard isLoader(process.path),
                  runtimePath == nil || URL(fileURLWithPath: process.path).resolvingSymlinksInPath().path.hasPrefix(runtimePath!),
                  root == nil || currentDirectory(of: process.pid).map({ directory in
                      let cwd = directory.resolvingSymlinksInPath().standardizedFileURL.path
                      return cwd == root! || cwd.hasPrefix(root! + "/")
                  }) == true,
                  let arguments = arguments(of: process.pid),
                  arguments.prefix(2).contains(where: {
                      names.contains(String($0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? "").lowercased())
                  }) else { return nil }
            return process.pid
        }
    }

    static func currentDirectory(of pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                           Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size
        else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return parseArguments(Data(data.prefix(size)))
    }

    /// KERN_PROCARGS2 includes the environment after argc strings. An empty
    /// argv[0] is ambiguous with padding; reject environment-shaped first
    /// strings and require the absolute argv[0] our Wine launches use.
    /// Never log or expose the returned arguments outside process matching.
    static func parseArguments(_ data: Data) -> [String]? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...64).contains(argc) else { return nil }
        var offset = MemoryLayout<Int32>.size
        func string() -> String? {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(data: data[offset..<end], encoding: .utf8)
        }
        guard string() != nil else { return nil } // executable path
        while offset < data.count, data[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = string() else { return nil }
            arguments.append(argument)
        }
        guard let first = arguments.first, !first.contains("=") else { return nil }
        let bytes = Array(first.utf8.prefix(3))
        let windowsPath = bytes.count == 3 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0]))
            && bytes[1] == 58 && (bytes[2] == 92 || bytes[2] == 47)
        guard first.hasPrefix("/") || windowsPath else { return nil }
        return arguments
    }
}
