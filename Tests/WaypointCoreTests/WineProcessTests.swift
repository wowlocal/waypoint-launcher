import Foundation
import Testing
@testable import WaypointCore

@Test func wineProcessArgumentsStopBeforeEnvironment() {
    var argc: Int32 = 2
    var data = withUnsafeBytes(of: &argc) { Data($0) }
    data.append(Data("/runtime/bin/wine\0\0C:\\Games\\HeroesOfTheStorm_x64.exe\0-launch\0PRIVATE=DUMMY\0".utf8))
    #expect(WineProcesses.parseArguments(data) == ["C:\\Games\\HeroesOfTheStorm_x64.exe", "-launch"])
    var truncated = data.prefix(12)
    #expect(WineProcesses.parseArguments(Data(truncated)) == nil)
    truncated.removeAll()
    var one: Int32 = 1
    var ambiguous = withUnsafeBytes(of: &one) { Data($0) }
    ambiguous.append(Data("/runtime/bin/wine\0\0\0\0SECRET=DUMMY\0".utf8))
    #expect(WineProcesses.parseArguments(ambiguous) == nil)
}

@Test func processDirectoryCanIdentifyAChildWithoutItsBundle() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    child.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
    try child.run()
    defer { child.terminate(); child.waitUntilExit() }
    let directory = WineProcesses.currentDirectory(of: child.processIdentifier)?.resolvingSymlinksInPath().path
    #expect(directory == child.currentDirectoryURL?.resolvingSymlinksInPath().path)
}

@Test func recognizesWineLoadersByExecutableName() {
    #expect(WineProcesses.isLoader("/Users/me/Library/Caches/Waypoint/wine/bin/wine64-preloader"))
    #expect(WineProcesses.isLoader("/opt/wine/bin/wine"))
    #expect(WineProcesses.isLoader("wine64"))
    #expect(!WineProcesses.isLoader("/Applications/wine64.app/Contents/MacOS/Launcher"))
    #expect(!WineProcesses.isLoader("/usr/local/bin/wine64/helper"))
    #expect(!WineProcesses.isLoader("/usr/local/bin/winery"))
    #expect(!WineProcesses.isLoader("/usr/local/bin/\u{301}wine"))
    #expect(!WineProcesses.isLoader(""))
}
