#if os(visionOS)
import AzaharCore
import SwiftUI

/// Emulator settings for Apple Vision Pro, opened from the game list or the in-game control bar.
/// Changes are written to the core's config and applied right away where Azahar can (graphics,
/// speed, audio); console settings take effect when the next game starts.
struct VisionSettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var core = EmulatorCore.shared
    @State private var username = ""
    @State private var language = 1
    @State private var applyTask: Task<Void, Never>?

    private var gameRunning: Bool {
        switch core.state {
        case .idle, .failed: return false
        default: return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                controls
                graphics
                speed
                audio
                console
            }
            .navigationTitle("Settings")
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear(perform: loadConsole)
        .onDisappear { if !gameRunning { az_set_console_username(username) } }
        // Debounced so dragging a slider doesn't reload the core on every step.
        .onReceive(s.objectWillChange) { _ in
            applyTask?.cancel()
            applyTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                apply()
            }
        }
    }

    // MARK: Sections

    private var controls: some View {
        Section("Controls") {
            NavigationLink {
                VisionControllerSettingsView()
            } label: {
                Label("Controller Mapping & Hotkeys", systemImage: "gamecontroller")
            }
        }
    }

    private var graphics: some View {
        Section {
            Picker("Internal Resolution", selection: $s.resolutionFactor) {
                ForEach(1...6, id: \.self) { f in
                    Text("\(f)× (\(400 * f)×\(240 * f))").tag(f)
                }
            }
            Picker("Texture Filter", selection: $s.textureFilter) {
                ForEach(Array(Self.textureFilters.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(i)
                }
            }
            Toggle("Linear Filtering", isOn: $s.linearFiltering)
            Toggle("Asynchronous Shader Compilation", isOn: $s.asyncShaders)
            Toggle("Accurate Shader Multiplication", isOn: $s.accurateMul)
            Toggle("Disk Shader Cache", isOn: $s.diskShaderCache)
        } header: {
            Text("Graphics")
        } footer: {
            Text("Higher resolutions look sharper but use more memory; above 4× the system may close the app. Shader compilation stutter goes away with asynchronous compilation and the disk cache.")
        }
    }

    private var speed: some View {
        Section {
            Picker("Speed Limit", selection: $s.frameLimit) {
                ForEach([50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { Text("\($0)%").tag($0) }
                Text("Unlimited").tag(0)
            }
            Stepper("Turbo Speed: \(s.fastForwardSpeed)%", value: $s.fastForwardSpeed, in: 150...1000, step: 50)
            Toggle("Automatic CPU Clock", isOn: $s.cpuClockAuto)
            if !s.cpuClockAuto {
                Stepper("CPU Clock: \(s.cpuClock)%", value: $s.cpuClock, in: 25...400, step: 25)
            }
        } header: {
            Text("Speed")
        } footer: {
            Text("Turbo is toggled from the control bar above the game or with a controller hotkey. The automatic CPU clock is \(s.effectiveCPUClock)% here; lowering it can speed up demanding games, raising it can smooth out games that drop frames on real hardware.")
        }
    }

    private var audio: some View {
        Section("Audio") {
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $s.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            Toggle("Audio Stretching", isOn: $s.audioStretching)
        }
    }

    private var console: some View {
        Section {
            Toggle("New Nintendo 3DS", isOn: $s.isNew3DS)
            Picker("Region", selection: $s.region) {
                ForEach(Self.regions, id: \.value) { Text($0.name).tag($0.value) }
            }
            Picker("Language", selection: $language) {
                ForEach(Array(Self.languages.enumerated()), id: \.offset) { i, name in
                    Text(name).tag(i)
                }
            }
            .onChange(of: language) { _, value in az_set_console_language(Int32(value)) }
            TextField("Username", text: Binding(get: { username }, set: { username = String($0.prefix(10)) }))
                .onSubmit { az_set_console_username(username) }
            Picker("Clock", selection: $s.consoleClockFixed) {
                Text("Real Time").tag(false)
                Text("Fixed Date & Time").tag(true)
            }
            if s.consoleClockFixed {
                DatePicker("Starts At", selection: Binding(
                    get: { Date(timeIntervalSince1970: s.consoleFixedTime) },
                    set: { s.consoleFixedTime = $0.timeIntervalSince1970 }),
                    in: Self.consoleDateRange)
            }
        } header: {
            Text("Console")
        } footer: {
            Text(gameRunning
                 ? "Console settings can't be changed while a game runs. Exit the game first."
                 : "Applied when the next game starts. A fixed clock starts at the chosen time each time a game boots, then runs normally.")
        }
        .disabled(gameRunning)
    }

    // MARK: Apply

    private func apply() {
        core.reloadSettings()
        // Re-applies the turbo override with a changed turbo speed.
        if core.isFastForward { core.isFastForward = true }
    }

    private func loadConsole() {
        if let p = az_get_console_username() {
            username = String(cString: p)
            az_free(p)
        }
        language = Int(az_get_console_language())
    }

    // MARK: Options

    /// Settings::TextureFilter order.
    static let textureFilters = ["None", "Anime4K", "Bicubic", "ScaleForce", "xBRZ", "MMPX"]
    /// CFG::SystemLanguage order.
    static let languages = ["Japanese", "English", "French", "German", "Italian", "Spanish",
                            "Chinese (Simplified)", "Korean", "Dutch", "Portuguese", "Russian",
                            "Chinese (Traditional)"]
    static let regions: [(name: String, value: Int)] = [
        ("Automatic", -1), ("Japan", 0), ("USA", 1), ("Europe", 2), ("Australia", 3),
        ("China", 4), ("Korea", 5), ("Taiwan", 6),
    ]
    /// The 3DS clock can't be set before 2000 or after 2099.
    static let consoleDateRange: ClosedRange<Date> = {
        let c = Calendar.current
        return c.date(from: DateComponents(year: 2000, month: 1, day: 1))!
            ... c.date(from: DateComponents(year: 2099, month: 12, day: 31, hour: 23, minute: 59))!
    }()
}
#endif
