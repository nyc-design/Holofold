#if os(visionOS) && !HOLOFOLD_FULL_SHELL
import AzaharCore
import SwiftUI

/// Holofold's public entry point: no launcher. A small boot window installs any .cia dropped into
/// the app's folder, picks the game and opens the game windows, then closes. Leaving the game
/// (hold Options, Exit Game, Digital Crown) auto-saves and closes the windows; opening the app
/// again resumes from that save.
@main
struct HolofoldApp: App {
    init() {
        VisionShellRegistry.current = MinimalShell()
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
        .defaultSize(width: 560, height: 180)
        .restorationBehavior(.disabled)

        VisionGameScenes()
    }
}

/// Which game to boot. Configured with HOLOFOLD_AUTOBOOT_TITLE_ID / HOLOFOLD_AUTO_RESUME
/// (App/Config/Holofold.xcconfig, overridden in Local.xcconfig), or the -autoboot launch argument.
enum BootChoice {
    /// The bundled open-source homebrew used when no game of your own is installed. It uses the
    /// stereoscopic top screen, so a fresh build shows something meaningful.
    static let fallbackFile = "StarCruiser7.3dsx"

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

    static func pick(from games: [Game]) -> Game? {
        if let wanted = configured {
            if let g = games.first(where: { $0.titleIDString == wanted.uppercased() || $0.url.lastPathComponent == wanted }) {
                return g
            }
            VisionDiag.log("boot: configured game \(wanted) not found")
        }
        let own = games.filter { !$0.isBundled }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if let first = own.first { return first }
        return games.first { $0.url.lastPathComponent == fallbackFile } ?? games.first
    }
}

/// The boot window: a single status line while the library is scanned and .cia files install,
/// then it opens the game and closes itself.
private struct BootView: View {
    @ObservedObject private var library = GameLibrary.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var status: LocalizedStringKey = "Starting…"
    @State private var noGame = false
    @State private var booted = false

    var body: some View {
        VStack(spacing: 12) {
            if !noGame { ProgressView() }
            Text(status)
                .font(noGame ? .body : .headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .glassBackgroundEffect()
        .task { await boot() }
    }

    private func boot() async {
        guard !booted else { return }
        booted = true
        if az_is_running() {
            // A game is already up (this window came back through the shell): nothing to do.
            dismissWindow()
            return
        }
        library.refresh()
        // Wait for the scan, including .cia installs (several hundred MB take a while).
        for _ in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(250))
            if let name = library.installingName {
                status = "Installing \(name)…"
            } else if !library.isScanning {
                break
            }
        }
        guard let game = BootChoice.pick(from: library.games) else {
            noGame = true
            status = "No game found. Copy a decrypted .cia you dumped yourself into Files › Holofold, then reopen the app."
            VisionDiag.log("boot: no game")
            return
        }
        let resume = BootChoice.autoResume && VisionAutoSave.date(for: game) != nil
        VisionDiag.log("boot: \(game.titleIDString) \(game.url.lastPathComponent) resume=\(resume)")
        openWindow(id: VisionWindowID.game, value: VisionGameRequest(gameID: game.id, resume: resume))
    }
}
#endif
