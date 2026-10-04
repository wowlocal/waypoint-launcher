import AppKit
import SwiftUI
import WaypointCore

@main
struct WaypointApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()
    @State private var appUpdater = AppUpdater()
    /// The menu bar item is opt-in: most menu bars are crowded already.
    @AppStorage("showsMenuBarItem") private var showsMenuBarItem = false

    var body: some Scene {
        let _ = appDelegate.openWindow = openWindow
        Window("Waypoint", id: "main") {
            LibraryView()
                .environment(model)
                .environment(appUpdater)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 260)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if let version = appUpdater.readyVersion {
                    Button("Restart to Update Waypoint \(version)") { appUpdater.restartToUpdate() }
                } else if appUpdater.isEnabled {
                    Button("Check for Updates…") { checkForUpdates() }
                        .disabled(!appUpdater.canCheck)
                }
                Divider()
                Toggle("Show in Menu Bar", isOn: $showsMenuBarItem)
                Button("Sign Out of Battle.net") { Task { await model.signOut() } }
            }
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") { exportDiagnostics() }
                Button("Show Logs in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.directory])
                }
            }
        }

        MenuBarExtra("Waypoint", systemImage: "gamecontroller", isInserted: $showsMenuBarItem) {
            ForEach(model.games.filter(\.isSupported)) { game in
                if let update = model.availableUpdate(for: game), GameUpdater.canUpdate(game.family) {
                    Button("Update \(game.displayName) to \(update.latest.name)") {
                        Task { await model.update(game) }
                    }
                    .disabled(!model.canUpdate(game))
                } else {
                    Button(model.running.contains(game.id) ? "\(game.displayName) (running)" : "Play \(game.displayName)") {
                        Task { await model.play(game) }
                    }
                    .disabled(!model.canPlay(game))
                }
            }
            Divider()
            if let version = appUpdater.readyVersion {
                Button("Restart to Update Waypoint \(version)") { appUpdater.restartToUpdate() }
            }
            Button("Check for Updates") { checkForUpdates() }
            Button("Rescan Games") { model.reload() }
            Button("Quit Waypoint") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }

    /// Saves a diagnostics snapshot plus the last week of logs as one JSONL
    /// file, for bug reports.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        let stamp = Diagnostics.timestampString(Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Waypoint-Diagnostics-\(stamp).jsonl"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsReport.export(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Log.error(.app, "diagnostics_export_failed", nil, ["error": error])
            NSAlert(error: error).runModal()
        }
    }

    /// One button for everything: games (Blizzard's version service) and
    /// Waypoint itself (Sparkle, in the background).
    private func checkForUpdates() {
        appUpdater.checkNow()
        Task { await model.checkForUpdates(force: true) }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.games.isEmpty && model.installable.isEmpty {
                ContentUnavailableView("No games found", systemImage: "gamecontroller",
                                       description: Text("Install a game, then rescan."))
            } else {
                List {
                    ForEach(model.games) { game in GameRow(game: game) }
                    if !model.installable.isEmpty {
                        Section("Available to install") {
                            ForEach(model.installable) { product in InstallableRow(product: product) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            if appUpdater.status != nil || appUpdater.readyVersion != nil {
                AppUpdateBar()
                Divider()
            }
            HStack {
                Picker("Region", selection: $model.regionOverride) {
                    Text("Region: as installed").tag(Region?.none)
                    ForEach(Region.allCases, id: \.self) { region in
                        Text(region.displayName).tag(Region?.some(region))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Check for Updates") {
                    appUpdater.checkNow()
                    Task { await model.checkForUpdates(force: true) }
                }
                Button("Rescan") { model.reload() }
            }
            .padding(10)
        }
    }
}

/// Inline status for Waypoint's own updates, instead of Sparkle's windows.
struct AppUpdateBar: View {
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        HStack(spacing: 8) {
            if appUpdater.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: appUpdater.readyVersion != nil ? "arrow.down.circle.fill" : "info.circle")
                    .foregroundStyle(appUpdater.readyVersion != nil ? Color.accentColor : .secondary)
            }
            Text(appUpdater.status ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if appUpdater.readyVersion != nil {
                Button("Restart to Update") { appUpdater.restartToUpdate() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        HStack(spacing: 12) {
            icon
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.displayName).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = model.phase(of: game) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                if case .updating(let progress) = model.phase(of: game) {
                    ProgressView(value: progress?.fraction ?? 0)
                        .frame(maxWidth: 220)
                    Text(progressText(progress)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else if let update = model.availableUpdate(for: game) {
                    Text(GameUpdater.canUpdate(game.family)
                         ? "Update available: \(update.latest.name)"
                         : "Update \(update.latest.name) available in Battle.net")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            action
        }
        .padding(.vertical, 4)
    }

    private var icon: Image {
        guard let app = game.appURL else { return Image(systemName: "questionmark.app") }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = game.install.version { parts.append(version) }
        if let region = game.install.region { parts.append(region.uppercased()) }
        if game.appURL != nil { parts.append(game.runsNatively ? "Apple silicon" : "Intel only") }
        return parts.joined(separator: " · ")
    }

    private func progressText(_ progress: UpdateProgress?) -> String {
        guard let progress else { return "Checking files…" }
        let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
        return "\(Int(progress.fraction * 100))% · \(done) of \(total)"
    }

    @ViewBuilder private var action: some View {
        if model.running.contains(game.id) {
            Text("Running").font(.callout).foregroundStyle(.secondary)
        } else if !game.isSupported {
            Text(game.appURL == nil ? "Not installed" : (game.runsNatively ? "Unsupported" : "Needs Rosetta"))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            switch model.phase(of: game) {
            case .signingIn:
                ProgressView().controlSize(.small).help("Signing in…")
            case .launching:
                ProgressView().controlSize(.small).help("Starting…")
            case .updating:
                Text("Updating…").font(.callout).foregroundStyle(.secondary)
            case .idle, .failed:
                Group {
                    if model.availableUpdate(for: game) != nil, GameUpdater.canUpdate(game.family) {
                        Button("Update") { Task { await model.update(game) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canUpdate(game))
                    } else {
                        Button("Play") { Task { await model.play(game) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canPlay(game))
                    }
                }
                .contextMenu {
                    if model.availableUpdate(for: game) != nil {
                        Button("Play Without Updating") { Task { await model.play(game) } }
                    }
                    Button("Sign In Again and Play") { Task { await model.play(game, forceSignIn: true) } }
                    if GameUpdater.canUpdate(game.family) {
                        Divider()
                        Button("Verify Files") { Task { await model.update(game, verify: true) } }
                    }
                }
            }
        }
    }
}
