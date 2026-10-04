import AppKit
import SwiftUI
import WaypointCore

/// A game that isn't installed yet: Install…, then progress.
struct InstallableRow: View {
    @Environment(AppModel.self) private var model
    let product: InstallableProduct
    @State private var showingSheet = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName).font(.headline)
                switch model.phase(of: product) {
                case .updating(let progress):
                    ProgressView(value: progress?.fraction ?? 0).frame(maxWidth: 220)
                    Text(progressText(progress)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                case .failed(let message):
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                default:
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .updating = model.phase(of: product) {
                Text("Installing…").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Install…") { showingSheet = true }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingSheet) {
            InstallSheet(product: product)
        }
    }

    private func progressText(_ progress: UpdateProgress?) -> String {
        guard let progress else { return "Preparing…" }
        let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
        return "\(Int(progress.fraction * 100))% · \(done) of \(total)"
    }
}

/// Where, which language, which region; shows the real download size.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let product: InstallableProduct

    @State private var parent = URL(fileURLWithPath: "/Applications", isDirectory: true)
    @State private var language = ""
    @State private var region = Region.default()
    @State private var size: Result<UInt64, Error>?

    private var folder: URL { parent.appendingPathComponent(product.folderName, isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install \(product.displayName)").font(.title2.bold())
            Form {
                LabeledContent("Location") {
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { chooseParent() }
                    }
                }
                Picker("Language", selection: $language) {
                    ForEach(product.languages, id: \.self) { code in
                        Text(Self.languageName(code)).tag(code)
                    }
                }
                Picker("Region", selection: $region) {
                    ForEach(Region.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Download") {
                    switch size {
                    case nil: ProgressView().controlSize(.small)
                    case .success(let bytes): Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    case .failure(let error): Text(String(describing: error)).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    let (product, folder, region, language) = (product, folder, region, language)
                    Task { await model.install(product, folder: folder, region: region, language: language) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(language.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            language = product.defaultLanguage()
            region = model.regionOverride ?? Region.default()
        }
        .task(id: "\(language)|\(region.rawValue)") {
            guard !language.isEmpty else { return }
            size = nil
            do {
                size = .success(try await model.installSize(product, folder: folder, region: region, language: language))
            } catch {
                size = .failure(error)
            }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "\(product.displayName) will be installed in a \"\(product.folderName)\" folder here."
        panel.directoryURL = parent
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    static func languageName(_ code: String) -> String {
        let identifier = "\(code.prefix(2))_\(code.suffix(2))"
        return Locale.current.localizedString(forIdentifier: identifier) ?? code
    }
}
