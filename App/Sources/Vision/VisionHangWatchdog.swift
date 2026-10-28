#if os(visionOS)
import AzaharCore
import Foundation

/// Hang diagnostics for the stereo game, on its own queue so it still runs when the main thread
/// or the emulation thread is stuck (a device run froze with nothing in the Azahar log, and the
/// process was gone before a debugger could attach).
///
/// Every second while a game runs:
/// - emulation stalled (game fps ≈ 0 for 3 s, not paused): samples the emulation thread's call
///   stack for 3 s with az_debug_profile into Documents/hang-emu-<time>.txt (image-relative
///   return addresses plus the guest PC; symbolise them with atos against this build);
/// - display stalled (the main thread's frame pump has not run for 3 s): logged;
/// - every 30 s: fps, speed, the newest displayed frame and the hitches since the last line.
/// Everything goes to vision-diag.log.
final class VisionHangWatchdog: @unchecked Sendable {
    static let shared = VisionHangWatchdog()

    private let queue = DispatchQueue(label: "Holofold.HangWatchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var lastPump = Date()
    private var lastFrame: UInt64 = 0
    // Only touched on `queue`.
    private var emuStalledSeconds = 0
    private var profiledThisStall = false
    private var gameStalledSeconds = 0
    private var profiledThisGameStall = false
    private var mainStallLogged = false
    private var seconds = 0
    private var hitchCursor: UInt64 = 0

    /// Called by the frame pump on the main thread.
    func pumped(frame: UInt64) {
        lock.lock()
        lastPump = Date()
        if frame != 0 { lastFrame = frame }
        lock.unlock()
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            emuStalledSeconds = 0
            profiledThisStall = false
            gameStalledSeconds = 0
            profiledThisGameStall = false
            mainStallLogged = false
            seconds = 0
            hitchCursor = 0
            lock.lock(); lastPump = Date(); lock.unlock()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard az_is_running() else { return }
        seconds += 1
        var perf = AZPerfStats()
        let havePerf = az_get_perf_stats(&perf)
        lock.lock()
        let pumpAge = Date().timeIntervalSince(lastPump)
        let frame = lastFrame
        lock.unlock()
        let paused = az_is_paused()

        if seconds % 30 == 0 {
            VisionDiag.log(String(format: "perf: game %.1f fps, system %.1f fps, speed %.0f%%, frame %llu, %@",
                                  perf.game_fps, perf.system_fps, perf.emulation_speed * 100, frame, hitchSummary()))
        }

        // Emulation: no emulated frames while not paused.
        if havePerf, !paused, perf.system_fps < 0.5 {
            emuStalledSeconds += 1
        } else {
            if emuStalledSeconds >= 3 { VisionDiag.log("hang: emulation resumed after \(emuStalledSeconds) s") }
            emuStalledSeconds = 0
            profiledThisStall = false
        }
        if emuStalledSeconds == 3, !profiledThisStall {
            profiledThisStall = true
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hang-emu-\(stamp).txt")
            VisionDiag.log(String(format: "hang: emulation stalled 3 s (system %.1f fps, frame %llu, pump %.1f s ago), sampling to %@",
                                  perf.system_fps, frame, pumpAge, url.lastPathComponent))
            let samples = az_debug_profile(url.path, 3, 40)
            VisionDiag.log("hang: \(samples) emulation-thread samples written")
        }

        // The game itself stopped drawing while the emulator keeps running (seen on the device:
        // game 0 fps, system 61 fps, speed 100 %, displayed frames still advancing). The native
        // stack only shows the interpreter then; the guest PCs in the sample show where the 3DS
        // program is (one PC or a short range repeating = a guest loop).
        if havePerf, !paused, perf.game_fps < 0.5, perf.system_fps > 30 {
            gameStalledSeconds += 1
        } else {
            if gameStalledSeconds >= 5 { VisionDiag.log("hang: game drawing again after \(gameStalledSeconds) s") }
            gameStalledSeconds = 0
            profiledThisGameStall = false
        }
        if gameStalledSeconds == 5, !profiledThisGameStall {
            profiledThisGameStall = true
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hang-game-\(stamp).txt")
            VisionDiag.log(String(format: "hang: game drew nothing for 5 s (system %.1f fps, speed %.0f%%, jit %d, interpreter compat %d), sampling to %@",
                                  perf.system_fps, perf.emulation_speed * 100, JITHelper.isEnabled ? 1 : 0,
                                  UserDefaults.standard.bool(forKey: "interpreterCompat") ? 1 : 0, url.lastPathComponent))
            let samples = az_debug_profile(url.path, 3, 40)
            VisionDiag.log("hang: \(samples) samples written")
        }

        // Display: the main thread stopped pumping frames into RealityKit.
        if pumpAge > 3, !mainStallLogged {
            mainStallLogged = true
            VisionDiag.log(String(format: "hang: main thread has not pumped a frame for %.1f s (emulation %.1f fps)",
                                  pumpAge, perf.system_fps))
        } else if pumpAge <= 3, mainStallLogged {
            mainStallLogged = false
            VisionDiag.log("hang: main thread pumping again")
        }
    }

    private func hitchSummary() -> String {
        var buf = [AZHitch](repeating: AZHitch(), count: 32)
        let n = Int(az_get_hitches(&hitchCursor, &buf, Int32(buf.count)))
        guard n > 0 else { return "no stalls" }
        let worst = buf[0..<n].map(\.gap_ms).max() ?? 0
        return String(format: "%d stalls (worst %.0f ms)", n, worst)
    }
}
#endif
