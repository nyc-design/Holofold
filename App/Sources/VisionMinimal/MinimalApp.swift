#if os(visionOS) && !HOLOFOLD_FULL_SHELL
import AzaharCore
import SwiftUI

/// Holofold's entry point: a game list. The launcher window installs any .cia dropped into the
/// app's folder and lists the games; picking one opens the game windows and closes the list.
/// Leaving the game (hold Options, Exit Game, Digital Crown) auto-saves, closes the game windows
/// and brings the list back. A configured game (see BootChoice) still boots straight away once.
@main
struct HolofoldApp: App {
    init() {
        VisionShellRegistry.current = LauncherShell()
        VisionAppSetup.run()
    }

    var body: some Scene {
        WindowGroup(id: VisionWindowID.boot) {
            BootView()
                .onOpenURL { url in
                    if url.isFileURL { GameLibrary.shared.importFiles([url]) }
                }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 720)
        .restorationBehavior(.disabled)

        VisionGameScenes()

        WindowGroup(id: VisionWindowID.settings) {
            VisionSettingsView()
        }
        .defaultSize(width: 600, height: 760)
        .restorationBehavior(.disabled)
    }
}

/// The game list closes while a game runs and comes back when it ends.
struct LauncherShell: VisionShell {
    func gameDidStart(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        dismissWindow(id: VisionWindowID.boot)
    }

    func gameDidEnd(openWindow: OpenWindowAction) {
        openWindow(id: VisionWindowID.boot)
    }

    func recoverFromOrphanWindow(openWindow: OpenWindowAction) {
        openWindow(id: VisionWindowID.boot)
    }
}

/// Which game to boot without showing the list. Configured with HOLOFOLD_AUTOBOOT_TITLE_ID /
/// HOLOFOLD_AUTO_RESUME (App/Config/Holofold.xcconfig, overridden in Local.xcconfig), or the
/// -autoboot launch argument.
enum BootChoice {
    /// Set once the configured game was booted, so ending it shows the list instead of looping.
    static var autobootUsed = false

    static var configured: String? {
        let fromArgument = UserDefaults.standard.string(forKey: "autoboot")
        let fromBuild = Bundle.main.object(forInfoDictionaryKey: "HolofoldAutoBootTitleID") as? String
        for value in [fromArgument, fromBuild] {
            if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty, !v.hasPrefix("$(") { return v }
        }
        return nil
    }

    static var autoResume: Bool {
        let value = (Bundle.main.object(forInfoDictionaryKey: "HolofoldAutoResume") as? String) ?? "YES"
        return value.uppercased() != "NO"
    }

    static var autobootPending: Bool { !autobootUsed && configured != nil }

    static func configuredGame(in games: [Game]) -> Game? {
        guard let wanted = configured else { return nil }
        if let g = games.first(where: { $0.titleIDString == wanted.uppercased() || $0.url.lastPathComponent == wanted }) {
            return g
        }
        VisionDiag.log("boot: configured game \(wanted) not found")
        return nil
    }

    static func shouldResume(_ game: Game) -> Bool {
        autoResume && VisionAutoSave.date(for: game) != nil
    }
}

/// The launcher window: waits for the library scan (and .cia installs), then lists the games.
private struct BootView: View {
    @ObservedObject private var library = GameLibrary.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var ready = false
    @State private var prepared = false

    var body: some View {
        Group {
            if ready { gameList } else { loading }
        }
        .glassBackgroundEffect()
        .task { await prepare() }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(library.installingName.map { "Installing \($0)…" } ?? "Loading games…")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 520)
    }

    private var gameList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Holofold").font(.largeTitle.bold())
                Spacer()
                if library.isScanning { ProgressView().controlSize(.small) }
                Button {
                    openWindow(id: VisionWindowID.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help("Settings")
            }
            .padding([.horizontal, .top], 28)
            .padding(.bottom, 8)

            if let name = library.installingName {
                Text("Installing \(name)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }

            if library.games.isEmpty {
                Spacer()
                Text("No games yet. Copy .cia, .3ds or .cci files you dumped from your own 3DS into Files › Holofold; they show up here automatically.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(library.games) { game in
                            GameRow(game: game, enabled: library.installingName == nil) { resume in
                                play(game, resume: resume)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Text("Add games by copying them into Files › Holofold. Encrypted games also need aes_keys.txt and seeddb.bin dumped from your own 3DS, copied to the same place.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 640, height: 720)
    }

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        if az_is_running() {
            // A game is already up (this window came back through the shell): nothing to do.
            dismissWindow()
            return
        }
        // Coming back from a game: show the known list right away, the rescan updates it.
        if !library.games.isEmpty && !BootChoice.autobootPending { ready = true }
        library.refresh()
        // Wait for the scan, including .cia installs (several hundred MB take a while).
        for _ in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(250))
            if !library.isScanning && library.installingName == nil { break }
        }
        if BootChoice.autobootPending {
            BootChoice.autobootUsed = true
            if let game = BootChoice.configuredGame(in: library.games), !game.encrypted {
                play(game, resume: BootChoice.shouldResume(game))
                return
            }
        }
        ready = true
    }

    private func play(_ game: Game, resume: Bool) {
        VisionDiag.log("boot: \(game.titleIDString) \(game.url.lastPathComponent) resume=\(resume)")
        openWindow(id: VisionWindowID.game, value: VisionGameRequest(gameID: game.id, resume: resume))
    }
}

/// One game: icon, title, and the auto-save it resumes from. Tap plays (resuming when there is an
/// auto-save); the context menu offers starting over.
private struct GameRow: View {
    let game: Game
    let enabled: Bool
    let play: (_ resume: Bool) -> Void

    var body: some View {
        let saved = VisionAutoSave.date(for: game)
        Button {
            play(BootChoice.shouldResume(game))
        } label: {
            HStack(spacing: 16) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title).font(.headline).lineLimit(1)
                    Text(subtitle(saved: saved))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if game.encrypted {
                    Label("Needs keys", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled || game.encrypted)
        .contextMenu {
            if saved != nil && enabled && !game.encrypted {
                Button("Resume", systemImage: "play.fill") { play(true) }
                Button("Start Over", systemImage: "arrow.counterclockwise") { play(false) }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = game.icon {
            Image(uiImage: image)
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary))
        }
    }

    private func subtitle(saved: Date?) -> String {
        var parts: [String] = []
        if game.encrypted {
            parts.append("Encrypted")
        } else if let saved {
            parts.append("Saved \(saved.formatted(.relative(presentation: .named)))")
        }
        if !game.publisher.isEmpty { parts.append(game.publisher) }
        if let v = game.updateVersion { parts.append("Update \(Game.versionString(v))") }
        if game.hasDLC { parts.append("DLC") }
        return parts.isEmpty ? game.fileType : parts.joined(separator: " · ")
    }
}
#endif
