#if os(visionOS)
import AzaharCore
import GameController
import SwiftUI

/// Settings › Controls: which controller button is which 3DS button, what the sticks and d-pad
/// do, and the hotkeys, like Citra / Azahar's controls page. Tap a row, then press the button.
struct VisionControllerSettingsView: View {
    @ObservedObject private var mapping = ControllerMapping.shared
    @State private var binding: BindingTarget?
    @State private var controllers: [String] = []

    enum BindingTarget: Identifiable {
        case button(AZButton, String)
        case hotkeyButton
        case hotkey(ControllerMapping.Hotkey)

        var id: String {
            switch self {
            case .button(let b, _): return "button-\(b.rawValue)"
            case .hotkeyButton: return "hotkey-button"
            case .hotkey(let h): return "hotkey-\(h.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .button(_, let name): return name
            case .hotkeyButton: return "Hotkey Button"
            case .hotkey(let h): return h.title
            }
        }
    }

    var body: some View {
        Form {
            Section {
                if controllers.isEmpty {
                    Text("No controller connected").foregroundStyle(.secondary)
                } else {
                    ForEach(controllers, id: \.self) { Label($0, systemImage: "gamecontroller") }
                }
            } header: {
                Text("Controller")
            } footer: {
                Text("One layout for every controller. Inputs are named by position: the right face button is A, like on a 3DS.")
            }

            Section("Buttons") {
                ForEach(ControllerMapping.remappable.indices, id: \.self) { i in
                    let item = ControllerMapping.remappable[i]
                    row(item.title, mapping.config.physical(for: item.button)) {
                        binding = .button(item.button, item.title)
                    }
                }
            }

            Section("Sticks & D-Pad") {
                Picker("Left Stick", selection: $mapping.config.leftStick) { stickOptions }
                Picker("Right Stick", selection: $mapping.config.rightStick) { stickOptions }
                Picker("D-Pad", selection: $mapping.config.dpad) { stickOptions }
            }

            Section {
                Toggle("Hotkeys", isOn: $mapping.config.hotkeysEnabled)
                if mapping.config.hotkeysEnabled {
                    row("Hotkey Button", mapping.config.hotkeyButton) { binding = .hotkeyButton }
                    ForEach(ControllerMapping.Hotkey.allCases) { hotkey in
                        row(hotkey.title, mapping.config.hotkeys[hotkey.rawValue]) { binding = .hotkey(hotkey) }
                    }
                }
            } header: {
                Text("Hotkeys")
            } footer: {
                Text("Hold the hotkey button and press another. Pressed on its own, the hotkey button still works as its 3DS button. Quick Save and Quick Load use slot \(ControllerMapping.quickSlot); the auto-save when leaving a game is separate. Holding Start also leaves the game.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { mapping.resetToDefaults() }
            }
        }
        .navigationTitle("Controls")
        .onAppear(perform: refreshControllers)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshControllers() }
        .sheet(item: $binding) { target in
            CaptureSheet(target: target) { physical in
                assign(physical, to: target)
                binding = nil
            } cancel: {
                binding = nil
            }
        }
    }

    @ViewBuilder private var stickOptions: some View {
        ForEach(ControllerMapping.StickTarget.allCases) { Text($0.title).tag($0) }
    }

    private func row(_ title: String, _ physical: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let symbol = ControllerMapping.symbol(physical) { Image(systemName: symbol) }
                Text(ControllerMapping.displayName(physical)).foregroundStyle(.secondary)
            }
        }
    }

    private func assign(_ physical: String?, to target: BindingTarget) {
        switch target {
        case .button(let button, _): mapping.assign(physical, to: button)
        case .hotkeyButton: mapping.config.hotkeyButton = physical
        case .hotkey(let hotkey): mapping.assignHotkey(physical, to: hotkey)
        }
    }

    private func refreshControllers() {
        controllers = GCController.controllers()
            .filter { $0.extendedGamepad != nil && $0.productCategory != GCProductCategorySpatialController }
            .map { $0.vendorName ?? "Controller" }
    }
}

/// Waits for the next controller button. The capture view keeps visionOS from turning the press
/// into a tap on whatever the player is looking at.
private struct CaptureSheet: View {
    let target: VisionControllerSettingsView.BindingTarget
    let done: (String?) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 44))
            Text("Press a button for \(target.title)").font(.title2)
            Text("Sticks and the d-pad are set under Sticks & D-Pad.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Clear") { done(nil) }
                Button("Cancel", role: .cancel) { cancel() }
            }
        }
        .padding(40)
        .frame(minWidth: 420)
        .background(GameControllerCapture())
        .onAppear {
            InputManager.shared.beginCapture { physical in
                InputManager.shared.endCapture()
                done(physical)
            }
        }
        .onDisappear { InputManager.shared.endCapture() }
    }
}
#endif
