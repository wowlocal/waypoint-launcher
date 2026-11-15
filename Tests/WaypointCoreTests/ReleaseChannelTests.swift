import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

@Test func aTipBuildGetsTipsUntilSomeoneSaysOtherwise() throws {
    let defaults = try #require(UserDefaults(suiteName: "waypoint-tests-\(UUID().uuidString)"))
    #expect(!ReleaseChannel.receivesTips(defaults: defaults, running: .stable))
    #expect(ReleaseChannel.receivesTips(defaults: defaults, running: .tip))
    ReleaseChannel.setReceivesTips(false, defaults: defaults, running: .tip)
    #expect(!ReleaseChannel.receivesTips(defaults: defaults, running: .tip))
    ReleaseChannel.setReceivesTips(true, defaults: defaults, running: .stable)
    #expect(ReleaseChannel.receivesTips(defaults: defaults, running: .stable))
    // Off on a release forgets: a tip installed later by hand starts on.
    ReleaseChannel.setReceivesTips(false, defaults: defaults, running: .stable)
    #expect(ReleaseChannel.receivesTips(defaults: defaults, running: .tip))
    #expect(ReleaseChannel.isTipBuild("181.3") && !ReleaseChannel.isTipBuild("181"))
    #expect(ReleaseChannel.feed(receivesTips: true).hasSuffix("/waypoint/tip/appcast.xml"))
    #expect(ReleaseChannel.feed(receivesTips: false).hasSuffix("/waypoint/appcast.xml"))
}

/// Tips sit between releases: Sparkle's own order takes a release to a tip,
/// a tip to the next tip and to the next release; only the way back to the
/// same release is Waypoint's.
@Test func tipBuildNumbersSitBetweenReleases() {
    func newer(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }
    #expect(newer("181.1", "181"))
    #expect(newer("181.2", "181.1"))
    #expect(newer("181.10", "181.9"))
    #expect(newer("182", "181.10"))
    #expect(!newer("181", "181.3"))
}

private let appcast = Data("""
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Waypoint</title>
        <item>
            <title>1.1.3</title>
            <sparkle:version>181</sparkle:version>
            <sparkle:shortVersionString>1.1.3</sparkle:shortVersionString>
            <enclosure url="https://storage.yandexcloud.net/macos-releases/waypoint/Waypoint-1.1.3.dmg" length="5037657" type="application/octet-stream" sparkle:edSignature="c2ln"/>
        </item>
        <item>
            <sparkle:version>170</sparkle:version>
            <enclosure url="https://storage.yandexcloud.net/macos-releases/waypoint/Waypoint-1.1.0.dmg" sparkle:edSignature="b2xk"/>
        </item>
    </channel>
</rss>
""".utf8)

@Test func theReleaseFeedsNewestItemIsRead() throws {
    let release = try #require(ReleaseReturn.latest(in: appcast))
    #expect(release.version == "1.1.3")
    #expect(release.build == "181")
    #expect(release.url.lastPathComponent == "Waypoint-1.1.3.dmg")
    #expect(release.signature == "c2ln")
    #expect(release.length == 5_037_657)
    #expect(ReleaseReturn.latest(in: Data("not xml".utf8)) == nil)
}

@Test func onlyADownloadSignedWithWaypointsKeyIsAccepted() throws {
    let key = Curve25519.Signing.PrivateKey()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-release-\(UUID().uuidString).dmg")
    try Data("release".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let signature = try key.signature(for: Data("release".utf8)).base64EncodedString()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    try ReleaseReturn.verify(file, signature: signature, publicKey: publicKey)

    let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(throws: ReleaseReturn.Failure.badSignature) { try ReleaseReturn.verify(file, signature: signature, publicKey: other) }
    try Data("tampered".utf8).write(to: file)
    #expect(throws: ReleaseReturn.Failure.badSignature) { try ReleaseReturn.verify(file, signature: signature, publicKey: publicKey) }
    #expect(throws: ReleaseReturn.Failure.badSignature) { try ReleaseReturn.verify(file, signature: "!!", publicKey: publicKey) }
}

@Test func anUnsignedAppIsNeverSwappedIn() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-unsigned-\(UUID().uuidString).app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(throws: ReleaseReturn.Failure.badCodeSignature) { try ReleaseReturn.verifyCodeSignature(app, team: "H8QG3CBM96") }
}

@Test func onlyTheSwapArgumentsMakeASwapRequest() {
    #expect(ReleaseReturn.isSwapRequest(["Waypoint", "--waypoint-swap-release", "1", "/a", "/b", "1"]))
    #expect(!ReleaseReturn.isSwapRequest(["Waypoint"]))
    #expect(!ReleaseReturn.isSwapRequest(["Waypoint", "--waypoint-swap-release", "1"]))
}
