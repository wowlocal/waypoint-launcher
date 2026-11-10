import CryptoKit
import Foundation
import Testing
@testable import WaypointCore

private struct StagingSpaceFixture {
    let root: URL
    let install: ProductInstall
    let store: InstallStateStore
    let target = ProductVersion(region: "eu", buildConfig: String(repeating: "a", count: 32),
                                cdnConfig: String(repeating: "b", count: 32), buildID: 1, name: "1.0")

    init(root: URL? = nil, product: InstallableProduct = .hearthstone) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-space-\(UUID())")
        install = product.install(at: self.root, region: .eu, language: "enUS", tagString: "OSX EU enUS")
        store = InstallStateStore(file: self.root.appendingPathComponent("state.json"))
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent(".waypoint-staging"),
                                                withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func file(_ path: String, data: Data) -> UpdatePlan.File {
        let blob = Data("BLTE".utf8) + Data(count: 4) + Data("N".utf8) + data
        return UpdatePlan.File(path: path, contentKey: Data(Insecure.MD5.hash(data: data)),
                               encodedKey: Data(Insecure.MD5.hash(data: blob)), size: UInt64(data.count))
    }

    func stage(_ file: UpdatePlan.File, data: Data) throws {
        try data.write(to: root.appendingPathComponent(".waypoint-staging/\(file.contentKey.hex)"))
    }

    func plan(_ files: [UpdatePlan.File], cdn: CDNClient? = nil) -> UpdatePlan {
        UpdatePlan(install: install, target: target,
                   cdn: cdn ?? CDNClient(product: install.productCode, path: "test", servers: []),
                   files: files, deletions: [])
    }
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
func resumedLooseUpdateReservesOnlyTheRemainingDownload() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let fixture = try StagingSpaceFixture(root: server.directory.appendingPathComponent("game"))
    let completed = Data(repeating: 11, count: 2048)
    let pending = Data(repeating: 22, count: 1024)
    let files = [fixture.file("completed", data: completed), fixture.file("pending", data: pending)]
    try fixture.stage(files[0], data: completed)
    let fixtures = server.directory.appendingPathComponent("fixtures")
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    let blob = Data("BLTE".utf8) + Data(count: 4) + Data("N".utf8) + pending
    try blob.write(to: fixtures.appendingPathComponent(files[1].encodedKey.hex))
    let client = server.client(["fixtures"])
    defer { client.session.invalidateAndCancel() }
    var updater = GameUpdater(install: fixture.install, store: fixture.store)
    updater.availableCapacity = { _ in 512 * 1024 * 1024 + UInt64(pending.count) + 1 }

    try await updater.apply(fixture.plan(files, cdn: client))

    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("completed")) == completed)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("pending")) == pending)
    #expect(try server.requests().map { $0["file"] } == [files[1].encodedKey.hex])
    #expect(fixture.store.load()[fixture.install.uid]?.buildConfig == fixture.target.buildConfig)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
func completedStagingCommitsWithoutRequiringItsSpaceAgain() async throws {
    let fixture = try StagingSpaceFixture()
    defer { fixture.cleanUp() }
    let data = Data(repeating: 33, count: 1024)
    let files = [fixture.file("first", data: data), fixture.file("second", data: data)]
    try fixture.stage(files[0], data: data)
    var updater = GameUpdater(install: fixture.install, store: fixture.store)
    updater.availableCapacity = { _ in 512 * 1024 * 1024 + 1 }
    #expect(try updater.remainingStagingBytes(for: files) == 0)

    // An empty mirror list makes any accidental re-download fail.
    try await updater.apply(fixture.plan(files))

    for file in files { #expect(try Data(contentsOf: fixture.root.appendingPathComponent(file.path)) == data) }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".waypoint-staging").path))
}

private enum UnusableStaging: CaseIterable, Sendable { case missing, truncated, corrupted }

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil), arguments: UnusableStaging.allCases)
private func unusableStagingStillRequiresSpace(state: UnusableStaging) async throws {
    let fixture = try StagingSpaceFixture()
    defer { fixture.cleanUp() }
    let data = Data(repeating: 44, count: 1024)
    let file = fixture.file("file", data: data)
    switch state {
    case .missing: break
    case .truncated: try fixture.stage(file, data: data.dropLast())
    case .corrupted: try fixture.stage(file, data: Data(repeating: 55, count: data.count))
    }
    var updater = GameUpdater(install: fixture.install, store: fixture.store)
    updater.availableCapacity = { _ in 512 * 1024 * 1024 + 1 }
    #expect(try updater.remainingStagingBytes(for: [file, file]) == UInt64(data.count))
    do {
        try await updater.apply(fixture.plan([file]))
        Issue.record("Invalid staging must not bypass the disk-space check")
    } catch UpdateError.notEnoughSpace(let needed, _) {
        #expect(needed == UInt64(data.count))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(file.path).path))
    #expect(fixture.store.load().isEmpty)
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil))
func resumedCASCLooseFilesUseRemainingSpaceAtBothChecks() async throws {
    let product = try #require(InstallableProduct.forProduct("w3"))
    let fixture = try StagingSpaceFixture(product: product)
    defer { fixture.cleanUp() }
    let data = Data(repeating: 66, count: 1024)
    let file = fixture.file("game-file", data: data)
    try fixture.stage(file, data: data)
    let loose = fixture.plan([file])
    let config = try ProductConfig(json: Data("{}".utf8))
    let plan = CASCInstallPlan(install: fixture.install, product: product, config: config,
                               target: fixture.target, cdn: loose.cdn, buildConfig: Data(), cdnConfig: Data(),
                               archives: [], storage: [], loose: loose)
    var installer = CASCInstaller(product: product, install: fixture.install, config: config, store: fixture.store)
    installer.availableCapacity = { _ in (1 << 30) + 1 }

    try await installer.apply(plan)

    #expect(try Data(contentsOf: fixture.root.appendingPathComponent(file.path)) == data)
    #expect(fixture.store.load()[fixture.install.uid]?.buildConfig == fixture.target.buildConfig)
}
