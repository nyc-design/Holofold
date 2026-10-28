#if os(visionOS)
import SwiftUI

/// What the app around the game engine does at the edges of a session. The engine (game and
/// touch windows) only talks to the shell through this, so it works the same with the minimal
/// public shell, which boots straight into a game, and with an app that has a launcher.
@MainActor
protocol VisionShell {
    /// The game and touch windows are open and the game is booting.
    func gameDidStart(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction)
    /// The game stopped and its windows are closing.
    func gameDidEnd(openWindow: OpenWindowAction)
    /// The system brought back a game window without a usable request.
    func recoverFromOrphanWindow(openWindow: OpenWindowAction)
}

@MainActor
enum VisionShellRegistry {
    /// Set once at launch by the app's entry point.
    static var current: VisionShell = MinimalShell()
}

/// The public build's shell: no launcher. The boot window closes once the game windows are up,
/// and leaving the game simply closes them (opening the app again boots the game again).
struct MinimalShell: VisionShell {
    func gameDidStart(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        dismissWindow(id: VisionWindowID.boot)
    }

    func gameDidEnd(openWindow: OpenWindowAction) {}

    func recoverFromOrphanWindow(openWindow: OpenWindowAction) {
        openWindow(id: VisionWindowID.boot)
    }
}
#endif
