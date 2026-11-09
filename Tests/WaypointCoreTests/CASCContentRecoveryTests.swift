import Foundation
import Testing
@testable import WaypointCore

@Test func missingAgentTagsRecoverTheInstalledSelectionFromTheMatchingBuildInfoRow() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("waypoint-content-tags-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let product = try #require(InstallableProduct.fallbackNative.first { $0.productCode == "wow" })
    let build = String(repeating: "a", count: 32)
    let selected = "OSX arm64 acct-test EU? HighRes enUS speech?:OSX arm64 acct-test EU? HighRes enUS text?"
    let config = try ProductConfig(json: Data("{}".utf8))
    let install = ProductInstall(uid: "wow", productCode: "wow", installPath: root.path, region: "eu",
                                 version: "1.0", buildConfig: build)
    let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Tags!STRING:0|Product!STRING:0"
    let unrelated = ["eu|1|\(build)|1.0|OSX Alternate|wow_classic", "us|1|\(build)|1.0|OSX HighRes|wow"]
    func write(_ rows: [String]) throws {
        try ([header] + rows).joined(separator: "\n").write(to: root.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    }
    let installer = CASCInstaller(product: product, install: install, config: config)
    try write(unrelated + ["eu|1|\(build)|1.0|\(selected)|wow"])
    #expect(installer.installedTags() == selected)
    #expect(InstallContent.plannedTags(for: install, from: installer.installedTags()) == selected)
    let changedLanguage = install.with(GameLanguages(text: "deDE"), tags: installer.installedTags())
    #expect(changedLanguage.tagString?.contains("HighRes") == true)
    #expect(changedLanguage.tagString?.contains("acct-test") == true)

    // Explicit install records remain authoritative, including a selection
    // without HighRes. An empty Agent string is a missing record too.
    var explicit = install
    explicit.tagString = "OSX enUS"
    #expect(CASCInstaller(product: product, install: explicit, config: config).installedTags() == explicit.tagString)
    explicit.tagString = ""
    #expect(CASCInstaller(product: product, install: explicit, config: config).installedTags() == selected)
    var versionOnly = install
    versionOnly.buildConfig = nil
    #expect(CASCInstaller(product: product, install: versionOnly, config: config).installedTags() == selected)

    let fallback = config.tagString(region: .eu, languages: install.languages)
    versionOnly.version = "another-version"
    #expect(CASCInstaller(product: product, install: versionOnly, config: config).installedTags() == fallback)
    let baseOnly = "OSX arm64 EU? enUS speech?:OSX arm64 EU? enUS text?"
    try write(["eu|1|\(build)|1.0|\(baseOnly)|wow"])
    #expect(installer.installedTags() == baseOnly)
    #expect(InstallContent.plannedTags(for: install, from: installer.installedTags()) == baseOnly)
    var completed = install
    completed.tagString = installer.installedTags()
    #expect(!InstallContent.selectsHighRes(completed))
    let record = BattleNetInstallMetadata.encode(install, subfolder: "_retail_")
    #expect(try BattleNetInstallMetadata.updatingContentSelection(record, for: completed) == record)
    try write(["EU|1|\(build)|1.0|\(selected)|wow"])
    #expect(installer.installedTags() == selected)
    var unknownRegion = install
    unknownRegion.region = nil
    #expect(CASCInstaller(product: product, install: unknownRegion, config: config).installedTags()
        == config.tagString(region: .us, languages: unknownRegion.languages))
    var alias = install
    alias.uid = "wow_launcher_uid"
    try write(["eu|1|\(build)|1.0|\(selected)|\(alias.uid)"])
    #expect(CASCInstaller(product: product, install: alias, config: config).installedTags() == selected)
    for row in ["eu|0|\(build)|1.0|\(selected)|wow", "eu|1|wrong-build|1.0|\(selected)|wow",
                "eu|1|\(build)|1.0|Windows HighRes|wow", "eu|1|\(build)|1.0||wow"] {
        try write(unrelated + [row])
        #expect(installer.installedTags() == fallback)
    }
    // Conflicting records cannot establish a safe selection.
    try write(["eu|1|\(build)|1.0|\(selected)|wow", "eu|1|\(build)|1.0|OSX enUS|wow"])
    #expect(installer.installedTags() == fallback)
    // Starting a fresh install never inherits an old record's selection.
    try write(["eu|1|\(build)|1.0|\(selected)|wow"])
    var fresh = install
    fresh.buildConfig = nil
    fresh.version = nil
    #expect(CASCInstaller(product: product, install: fresh, config: config).installedTags() == fallback)
    try fm.removeItem(at: root.appendingPathComponent(".build.info"))
    #expect(installer.installedTags() == fallback)
}
