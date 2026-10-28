#if os(visionOS)
import AVFoundation
import SwiftUI

/// The game's two windows, shared by every entry point: the top screen in stereo, filling a plain
/// 5:3 window, and the bottom screen in its own window right below it.
struct VisionGameScenes: Scene {
    var body: some Scene {
        // Never restored: a game window brought back on the next launch would boot the game a
        // second time (seen on the device as three windows).
        WindowGroup(id: VisionWindowID.game, for: VisionGameRequest.self) { $request in
            if let request {
                VisionGameWindow(request: request)
            } else {
                // Restored by the system with no (or an outdated) request: an empty window.
                VisionOrphanWindow()
            }
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 768)
        .restorationBehavior(.disabled)

        WindowGroup(id: VisionWindowID.touch, for: String.self) { _ in
            VisionTouchWindow()
        } defaultValue: {
            VisionWindowID.touchValue
        }
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 450)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            if let game = context.windows.first(where: { $0.id == VisionWindowID.game }) {
                return WindowPlacement(.below(game))
            }
            return WindowPlacement()
        }
    }
}

/// Process setup every entry point does once.
@MainActor
enum VisionAppSetup {
    static func run() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        EmulatorCore.shared.initialize()
    }
}
#endif
