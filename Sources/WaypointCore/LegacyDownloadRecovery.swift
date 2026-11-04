import Foundation

/// Versions before durable jobs left CASC journals and structured install logs.
/// Import only requests that have both, with no later finish/cancel event.
enum LegacyDownloadRecovery {
    private struct Candidate {
        var request: DownloadRequest
        var dataDirectory = "Data/"
        var total: UInt64 = 0
    }

    static func records(events: [Diagnostics.Event], products: [InstallableProduct]) -> [UnfinishedDownload] {
        var candidates: [String: Candidate] = [:]
        for event in events {
            guard event.process == "Waypoint", let rawUID = event.fields["uid"] else { continue }
            let uid = rawUID.hasSuffix("@windows") ? String(rawUID.dropLast(8)) : rawUID
            let f = event.fields
            if event.category == "install", event.event == "requested",
               let product = products.first(where: { $0.uid == uid }),
               let path = f["path"], path.hasPrefix("/"), let region = f["region"].flatMap(Region.init(rawValue:)),
               let text = f["language"] {
                let platform: InstallPlatform = product.supportedPlatforms == [.windows] ? .windows : .macOS
                let install = product.install(at: URL(fileURLWithPath: path), region: region,
                    languages: GameLanguages(text: text, speech: f["speech_language"]), tagString: "", platform: platform)
                candidates[uid] = Candidate(request: DownloadRequest(kind: .install, install: install, product: product))
            } else if (event.category == "install" && event.event == "finished") ||
                        (event.category == "cdn" && event.event == "cancelled") {
                candidates[uid] = nil
            } else if event.category == "install", event.event == "plan_started", var candidate = candidates[uid],
                      f["path"] == candidate.request.install.installPath, let tags = f["tags"],
                      let platform = InstallPlatform.from(tags: tags), let product = candidate.request.product,
                      let region = candidate.request.install.region.flatMap(Region.init(rawValue:)) {
                candidate.request.install = product.install(at: URL(fileURLWithPath: candidate.request.install.installPath),
                    region: region, languages: candidate.request.install.languages, tagString: tags, platform: platform)
                if let dataDirectory = f["data_dir"], !dataDirectory.hasPrefix("/"),
                   !dataDirectory.split(separator: "/").contains("..") { candidate.dataDirectory = dataDirectory }
                candidates[uid] = candidate
            } else if event.category == "install", event.event == "casc_apply_started", var candidate = candidates[uid] {
                candidate.total = (f["bytes"].flatMap(UInt64.init) ?? 0) + (f["resumed_bytes"].flatMap(UInt64.init) ?? 0)
                candidates[uid] = candidate
            }
        }
        return candidates.values.compactMap { candidate in
            let directory = URL(fileURLWithPath: candidate.request.install.installPath)
                .appendingPathComponent(candidate.dataDirectory).appendingPathComponent("data")
            let stored = CASCStorageWriter.journaledBytes(in: directory)
            guard stored > 0, candidate.total > 0 else { return nil }
            let progress = UpdateProgress(completedBytes: min(stored, candidate.total), totalBytes: candidate.total,
                                          completedFiles: 0, totalFiles: 0)
            return UnfinishedDownload(request: candidate.request, progress: progress)
        }
    }
}
