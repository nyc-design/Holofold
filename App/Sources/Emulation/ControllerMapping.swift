import AzaharCore
import Foundation
import GameController

/// Which controller input drives which 3DS button, what the sticks and d-pad do, and the hotkeys
/// (hold the hotkey button, press another), like Citra / Azahar's controls settings. Inputs are
/// GameController's physical names ("Button A", "Left Shoulder" …), which name the position, so
/// "Button B" is the east face button on every pad. Saved in UserDefaults and read on every
/// press, so a change applies to a running game.
@MainActor
final class ControllerMapping: ObservableObject {
    static let shared = ControllerMapping()

    enum StickTarget: String, CaseIterable, Identifiable, Codable {
        case circlePad, cStick, dpad, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .circlePad: return "Circle Pad"
            case .cStick: return "C-Stick"
            case .dpad: return "D-Pad"
            case .none: return "Nothing"
            }
        }
    }

    enum Hotkey: String, CaseIterable, Identifiable, Codable {
        case saveState, loadState, turbo, pause, exitGame
        var id: String { rawValue }
        var title: String {
            switch self {
            case .saveState: return "Quick Save"
            case .loadState: return "Quick Load"
            case .turbo: return "Toggle Turbo"
            case .pause: return "Pause / Resume"
            case .exitGame: return "Exit Game"
            }
        }
    }

    struct Config: Codable, Equatable {
        /// Physical button name → AZButton raw value.
        var buttons: [String: UInt32]
        var leftStick: StickTarget
        var rightStick: StickTarget
        var dpad: StickTarget
        var hotkeysEnabled: Bool
        var hotkeyButton: String?
        /// Hotkey raw value → physical button name pressed together with the hotkey button.
        var hotkeys: [String: String]

        static let standard = Config(
            buttons: [
                // Nintendo layout by position: the east face button is A, like on a real 3DS.
                GCInputButtonB: AZ_BUTTON_A.rawValue,
                GCInputButtonA: AZ_BUTTON_B.rawValue,
                GCInputButtonY: AZ_BUTTON_X.rawValue,
                GCInputButtonX: AZ_BUTTON_Y.rawValue,
                GCInputLeftShoulder: AZ_BUTTON_L.rawValue,
                GCInputRightShoulder: AZ_BUTTON_R.rawValue,
                GCInputLeftTrigger: AZ_BUTTON_ZL.rawValue,
                GCInputRightTrigger: AZ_BUTTON_ZR.rawValue,
                GCInputButtonMenu: AZ_BUTTON_START.rawValue,
                GCInputButtonOptions: AZ_BUTTON_SELECT.rawValue,
                GCInputButtonHome: AZ_BUTTON_HOME.rawValue,
            ],
            leftStick: .circlePad, rightStick: .cStick, dpad: .dpad,
            hotkeysEnabled: true,
            hotkeyButton: GCInputButtonOptions,
            hotkeys: [
                Hotkey.saveState.rawValue: GCInputRightShoulder,
                Hotkey.loadState.rawValue: GCInputLeftShoulder,
                Hotkey.turbo.rawValue: GCInputRightTrigger,
                Hotkey.pause.rawValue: GCInputLeftTrigger,
                Hotkey.exitGame.rawValue: GCInputButtonMenu,
            ])

        func target(for physical: String) -> AZButton? { buttons[physical].map { AZButton(rawValue: $0) } }

        func physical(for button: AZButton) -> String? {
            buttons.filter { $0.value == button.rawValue }.keys.sorted().first
        }

        func hotkey(for physical: String) -> Hotkey? {
            hotkeys.first { $0.value == physical }.flatMap { Hotkey(rawValue: $0.key) }
        }

        func stickTarget(forPad name: String) -> StickTarget {
            switch name {
            case GCInputLeftThumbstick: return leftStick
            case GCInputRightThumbstick: return rightStick
            case GCInputDirectionPad: return dpad
            default: return .none
            }
        }
    }

    /// 3DS buttons in the order Settings lists them. The d-pad directions are listed too, so a
    /// face or shoulder button can stand in for one.
    static let remappable: [(button: AZButton, title: String)] = [
        (AZ_BUTTON_A, "A"), (AZ_BUTTON_B, "B"), (AZ_BUTTON_X, "X"), (AZ_BUTTON_Y, "Y"),
        (AZ_BUTTON_L, "L"), (AZ_BUTTON_R, "R"), (AZ_BUTTON_ZL, "ZL"), (AZ_BUTTON_ZR, "ZR"),
        (AZ_BUTTON_START, "Start"), (AZ_BUTTON_SELECT, "Select"), (AZ_BUTTON_HOME, "Home"),
        (AZ_BUTTON_UP, "D-Pad Up"), (AZ_BUTTON_DOWN, "D-Pad Down"),
        (AZ_BUTTON_LEFT, "D-Pad Left"), (AZ_BUTTON_RIGHT, "D-Pad Right"),
    ]

    /// Quick Save / Quick Load use slot 1 (slot 0 is the auto-save written when leaving a game).
    static let quickSlot = 1

    private static let key = "controllerMapping.v1"

    @Published var config: Config {
        didSet {
            Self.live = config
            guard config != oldValue, let data = try? JSONEncoder().encode(config) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// `config` for the controller handlers, which GameController calls on the main queue.
    nonisolated(unsafe) static private(set) var live = Config.standard

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        } else {
            config = .standard
        }
        Self.live = config
    }

    /// Binds `physical` to `button`, replacing whatever was bound to either before (one input per
    /// 3DS button, one 3DS button per input). nil unbinds the 3DS button.
    func assign(_ physical: String?, to button: AZButton) {
        var buttons = config.buttons.filter { $0.value != button.rawValue }
        if let physical { buttons[physical] = button.rawValue }
        config.buttons = buttons
    }

    func assignHotkey(_ physical: String?, to hotkey: Hotkey) {
        var hotkeys = config.hotkeys.filter { $0.key != hotkey.rawValue && $0.value != physical }
        if let physical { hotkeys[hotkey.rawValue] = physical }
        config.hotkeys = hotkeys
    }

    func resetToDefaults() { config = .standard }

    /// The name a connected controller gives the input ("B Button", "Circle" …), else the
    /// physical name itself.
    static func displayName(_ physical: String?) -> String {
        guard let physical else { return "None" }
        for controller in GCController.controllers() {
            if let name = controller.physicalInputProfile.buttons[physical]?.localizedName { return name }
        }
        return physical
    }

    static func symbol(_ physical: String?) -> String? {
        guard let physical else { return nil }
        for controller in GCController.controllers() {
            if let symbol = controller.physicalInputProfile.buttons[physical]?.sfSymbolsName { return symbol }
        }
        return nil
    }
}

extension Notification.Name {
    /// A short message for the game window (hotkey feedback: "Saved", "Turbo on" …); object: String.
    static let holofoldToast = Notification.Name("HolofoldToast")
}
