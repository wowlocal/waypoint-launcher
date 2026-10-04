import AppKit
import SwiftUI
import WaypointCore

@main
struct WaypointApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Waypoint", id: "main") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 420, idealWidth: 460, minHeight: 260)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sign Out of Battle.net") { Task { await model.signOut() } }
            }
        }

        MenuBarExtra("Waypoint", systemImage: "gamecontroller") {
            ForEach(model.games.filter(\.isSupported)) { game in
                Button(model.running.contains(game.id) ? "\(game.displayName) (running)" : "Play \(game.displayName)") {
                    Task { await model.play(game) }
                }
                .disabled(!model.canPlay(game))
            }
            Divider()
            Button("Rescan Games") { model.reload() }
            Button("Quit Waypoint") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.games.isEmpty {
                ContentUnavailableView("No games found", systemImage: "gamecontroller",
                                       description: Text("Install a game, then rescan."))
            } else {
                List(model.games) { game in
                    GameRow(game: game)
                }
                .listStyle(.inset)
            }
            Divider()
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
                Button("Rescan") { model.reload() }
            }
            .padding(10)
        }
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
            case .idle, .failed:
                Button("Play") { Task { await model.play(game) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPlay(game))
            }
        }
    }
}
