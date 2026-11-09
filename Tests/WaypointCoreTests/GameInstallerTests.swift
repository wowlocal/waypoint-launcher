import Foundation
import Testing
@testable import WaypointCore

private struct GameInstallSandbox {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("waypoint-install-\(UUID().uuidString)", isDirectory: true)
    var store: InstallStateStore { InstallStateStore(file: directory.appendingPathComponent("installs.json")) }

    init() throws {
        // The parent must exist: resolving a wholly missing path can hide the
        // difference between directory URLs with and without a trailing slash.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func loosePlan(for install: ProductInstall) -> UpdatePlan {
        let target = ProductVersion(region: "eu", buildConfig: String(repeating: "a", count: 32),
                                    cdnConfig: String(repeating: "b", count: 32), buildID: 1, name: "1.0")
        // Empty plans exercise local creation and commit without contacting a CDN.
        let cdn = CDNClient(product: install.productCode, path: "tpr/test", servers: [],
                            cacheDirectory: directory.appendingPathComponent("cache"))
        return UpdatePlan(install: install, target: target, cdn: cdn, files: [], deletions: [])
    }

    func plan(for product: InstallableProduct, at folder: URL) throws -> GameInstallPlan {
        let install = product.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU? enUS text?")
        let loose = loosePlan(for: install)
        if product.isContainerless { return .loose(loose) }
        let json = try JSONSerialization.data(withJSONObject: ["all": ["config": [
            "data_dir": product.productCode == "s2" ? "SC2Data/" : "Data/",
            "shared_container_default_subfolder": product.flavorFolder ?? "",
        ]]])
        let config = try ProductConfig(json: json)
        return .casc(CASCInstallPlan(install: install, product: product, config: config, target: loose.target,
                                     cdn: loose.cdn, buildConfig: Data(), cdnConfig: Data(),
                                     archives: [], storage: [], loose: loose))
    }
}

@Test(.enabled(if: (try? BattleNet.ensureNotRunning()) != nil),
      arguments: InstallableProduct.native.map(\.productCode), [true, false])
func freshGameInstallCreatesItsMissingFolder(productCode: String, directoryURL: Bool) async throws {
    let box = try GameInstallSandbox()
    defer { box.cleanUp() }
    let product = try #require(InstallableProduct.forProduct(productCode))
    let path = box.directory.appendingPathComponent(product.folderName).path
    let folder = URL(fileURLWithPath: path, isDirectory: directoryURL)
    let plan = try box.plan(for: product, at: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    try await GameInstaller(product: product, folder: folder, region: .eu,
                            languages: GameLanguages(text: "enUS"), store: box.store).apply(plan)

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try String(contentsOf: folder.appendingPathComponent(".waypoint-platform"), encoding: .utf8) == "mac\n")
    let record = try #require(box.store.load()[product.uid])
    #expect(record.installPath == folder.path)
    #expect(record.buildConfig == String(repeating: "a", count: 32))
    if case .casc(let casc) = plan {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".build.info").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(casc.config.dataDirectory)
            .appendingPathComponent("config/aa/aa/\(casc.target.buildConfig)").path))
        if let flavor = product.flavorFolder {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(flavor)
                .appendingPathComponent(".flavor.info").path))
        }
    }
}

private enum InstallPlanMismatch: CaseIterable, Sendable {
    case folder, uid, productCode, platform
}

@Test(arguments: InstallPlanMismatch.allCases)
private func mismatchedGameInstallPlansDoNotCreateFolders(mismatch: InstallPlanMismatch) async throws {
    let box = try GameInstallSandbox()
    defer { box.cleanUp() }
    let product = InstallableProduct.hearthstone
    let folder = box.directory.appendingPathComponent(product.folderName, isDirectory: true)
    var install = product.install(at: folder, region: .eu, language: "enUS", tagString: "OSX EU? enUS text?")
    switch mismatch {
    case .folder: install.installPath = box.directory.appendingPathComponent("Another Game").path
    case .uid: install.uid = "another-uid"
    case .productCode: install.productCode = "another-product"
    case .platform:
        install = ProductInstall(uid: install.uid, productCode: install.productCode,
                                 installPath: install.installPath, platform: .windows)
    }
    let plan = GameInstallPlan.loose(box.loosePlan(for: install))
    let installer = GameInstaller(product: product, folder: folder, region: .eu,
                                  languages: GameLanguages(text: "enUS"), store: box.store)
    do {
        try await installer.apply(plan)
        Issue.record("An install plan for another installation must be rejected")
    } catch let error as TACTError {
        if case .malformed(let message) = error {
            #expect(message == "Install plan belongs to another installation")
        } else {
            Issue.record("Expected an installation mismatch, got \(error)")
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.directory.path).isEmpty)
}
