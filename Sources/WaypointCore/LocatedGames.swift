import Foundation

/// Read-only discovery at a user-chosen location. Never follows metadata paths
/// from another Mac: the folder holding the record is the installation root.
public enum LocatedGames {
    public static func roots(at selection: URL, fileManager fm: FileManager = .default) -> [URL] {
        let selected = selection.standardizedFileURL
        var candidates = [selected]
        // Accept a WoW edition folder (or app) as well as its shared root.
        candidates.append(selected.deletingLastPathComponent())
        if selected.pathExtension == "app" { candidates.append(selected.deletingLastPathComponent().deletingLastPathComponent()) }
        // A games collection folder is convenient; do not crawl entire drives.
        if selected.pathExtension != "app", let children = try? fm.contentsOfDirectory(at: selected,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            candidates += children.filter { $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted && !installs(at: $0, fileManager: fm).isEmpty }
    }

    public static func installs(at root: URL, fileManager fm: FileManager = .default) -> [ProductInstall] {
        var found: [ProductInstall] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent(".product.db")),
           let records = try? ProductDB.parseFolderInstalls(data) {
            found = records.map { record in
                var local = record; local.installPath = root.standardizedFileURL.path; return local
            }
        }
        // Shared WoW roots sometimes have only one .product.db entry. Its
        // active build rows identify the other installed editions accurately.
        if let text = try? String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8) {
            let rows = BPSV(text).rows.filter { $0["Active"] == "1" }
            for row in rows {
                guard let code = row["Product"], let product = InstallableProduct.forProduct(code),
                      let tags = row["Tags"], let platform = InstallPlatform.from(tags: tags),
                      product.supportedPlatforms.contains(platform) else { continue }
                let matchingRows = rows.filter { $0["Product"] == code && InstallPlatform.from(tags: $0["Tags"]) == platform }
                let knownRegion = found.first { $0.productCode == code && $0.platform == platform }?.region
                if matchingRows.count > 1 {
                    guard let knownRegion, row["Branch"] == knownRegion,
                          matchingRows.filter({ $0["Branch"] == knownRegion }).count == 1 else { continue }
                }
                let branch = row["Branch"].flatMap(Region.init(rawValue:))?.rawValue
                if let knownRegion, let branch, knownRegion != branch { continue }
                let install = ProductInstall(uid: product.uid, productCode: code, installPath: root.standardizedFileURL.path,
                    region: branch, version: row["Version"], buildConfig: row["Build Key"], tagString: tags, platform: platform)
                if let index = found.firstIndex(where: { $0.key == install.key }) {
                    found[index].region = branch ?? found[index].region
                    found[index].version = install.version
                    found[index].buildConfig = install.buildConfig
                    found[index].tagString = install.tagString
                } else { found.append(install) }
            }
        }
        return found.filter { install in
            guard let product = InstallableProduct.forProduct(install.productCode),
                  product.supportedPlatforms.contains(install.platform),
                  (try? install.platform.validate(install: install, fileManager: fm)) != nil else { return false }
            return GameCatalog.game(for: install, fileManager: fm).isInstalled
        }
    }
}
