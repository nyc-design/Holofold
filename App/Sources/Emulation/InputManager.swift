import AzaharCore
import CoreMotion
import GameController
import UIKit

/// Physical controllers (MFi, Xbox, PlayStation, Switch Pro, Backbone/Kishi …), keyboards and
/// the gyroscope. Started while a game is on screen.
@MainActor
final class InputManager: ObservableObject {
    static let shared = InputManager()

    /// True once a physical controller has actually been used. Merely being connected is not
    /// enough: the iOS Simulator (and many paired-but-idle pads) always report a gamepad.
    @Published private(set) var hasGamepad = false
    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []
    /// Spatial accessories whose input handlers are set (visionOS 27); kept so the handlers live.
    private var accessories: [AnyObject] = []

    private init() {}

    func start() {
        GamepadRouter.active = true
        _ = ControllerMapping.shared // loads the saved mapping into ControllerMapping.live
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attach(n.object as? GCController) }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            #if os(visionOS)
            VisionDiag.log("controller disconnected: \((n.object as? GCController)?.vendorName ?? "?")")
            #endif
            Task { @MainActor in self?.refreshGamepadState() }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in self?.attachKeyboard((n.object as? GCKeyboard) ?? GCKeyboard.coalesced) }
        })
        #if os(visionOS)
        VisionDiag.log("game start: \(GCController.controllers().count) controller(s): \(GCController.controllers().map { $0.vendorName ?? "?" }.joined(separator: ", "))")
        if #available(visionOS 27.0, *) {
            VisionDiag.log("game start: \(GCSpatialAccessory.spatialAccessories.count) spatial accessory(ies): \(GCSpatialAccessory.spatialAccessories.map { $0.vendorName ?? "?" }.joined(separator: ", "))")
            GCSpatialAccessory.spatialAccessories.forEach(attachAccessory)
            observers.append(nc.addObserver(forName: .GCSpatialAccessoryDidConnect, object: nil, queue: .main) { [weak self] n in
                guard let accessory = n.object as? GCSpatialAccessory else { return }
                Task { @MainActor in self?.attachAccessory(accessory) }
            })
            observers.append(nc.addObserver(forName: .GCSpatialAccessoryDidDisconnect, object: nil, queue: .main) { n in
                VisionDiag.log("spatial accessory disconnected: \((n.object as? GCSpatialAccessory)?.vendorName ?? "?")")
            })
        }
        #endif
        GCController.controllers().forEach(attach)
        if let kb = GCKeyboard.coalesced { attachKeyboard(kb) }
        GCController.startWirelessControllerDiscovery {}
        refreshGamepadState()
        #if !os(visionOS)
        // The headset exposes no device motion or interface orientation to apps; motion
        // controls there come from the controller's own gyro (not wired up yet).
        startMotion()
        updateOrientation()
        observers.append(nc.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOrientation() }
        })
        #endif
    }

    func stop() {
        GamepadRouter.active = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        motion.stopDeviceMotionUpdates()
        #if os(visionOS)
        detachMotion()
        if #available(visionOS 27.0, *) {
            for case let accessory as GCSpatialAccessory in accessories { accessory.input?.elementValueDidChangeHandler = nil }
        }
        accessories.removeAll()
        #endif
        az_release_all_input()
    }

    private func refreshGamepadState() {
        if !GCController.controllers().contains(where: { $0.extendedGamepad != nil || Self.isSpatial($0) }) {
            hasGamepad = false
        }
    }

    private static func isSpatial(_ controller: GCController) -> Bool {
        #if os(visionOS)
        return controller.productCategory == GCProductCategorySpatialController
        #else
        return false
        #endif
    }

    fileprivate func gamepadUsed() {
        if !hasGamepad { hasGamepad = true }
    }

    // MARK: Gamepads

    private func attach(_ controller: GCController?) {
        #if os(visionOS)
        if let controller {
            VisionDiag.log("controller: \(controller.vendorName ?? "?") category=\(controller.productCategory) extended=\(controller.extendedGamepad != nil) motion=\(controller.motion != nil)")
        }
        if let controller, controller.productCategory == GCProductCategorySpatialController {
            attachSpatial(controller)
            return
        }
        #endif
        guard let controller, let pad = controller.extendedGamepad else { return }
        controller.playerIndex = .index1
        attachButtons(controller)
        #if os(visionOS)
        if (controller.vendorName ?? "").contains("VR2 Sense") { remapSensePair(pad) }
        attachMotion(controller)
        #endif
        refreshGamepadState()
    }

    /// Every button, stick and d-pad of an extended gamepad goes through a GamepadRouter, which
    /// looks the input up in ControllerMapping on each press.
    private func attachButtons(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        let router = GamepadRouter()
        // A d-pad's directions are buttons too; the d-pad handler covers them.
        let padButtons = profile.dpads.values.flatMap { [$0.up, $0.down, $0.left, $0.right] }
        var names: [String] = []
        for (name, input) in profile.buttons where !padButtons.contains(where: { $0 === input }) {
            input.pressedChangedHandler = { _, _, pressed in router.button(name, pressed) }
            names.append("\(name)=\(input.localizedName ?? "?")")
        }
        for (name, dpad) in profile.dpads {
            dpad.valueChangedHandler = { _, x, y in router.pad(name, x, y) }
        }
        #if os(visionOS)
        VisionDiag.log("controller inputs (\(controller.vendorName ?? "?")): \(names.sorted().joined(separator: ", ")) dpads=\(profile.dpads.keys.sorted().joined(separator: ","))")
        #endif
    }

    // MARK: Remapping and hotkeys

    /// Settings › Controls: the next button pressed on any controller goes to `handler` instead of
    /// the game. Works without a game running.
    func beginCapture(_ handler: @escaping (String) -> Void) {
        GamepadRouter.capture = handler
        if !GamepadRouter.active {
            GCController.controllers().filter { $0.extendedGamepad != nil && !Self.isSpatial($0) }.forEach(attachButtons)
        }
    }

    func endCapture() {
        GamepadRouter.capture = nil
    }

    fileprivate func perform(_ hotkey: ControllerMapping.Hotkey) {
        let core = EmulatorCore.shared
        guard core.state == .running || core.state == .paused else { return }
        let slot = ControllerMapping.quickSlot
        let saves = core.currentGame?.supportsSaveStates == true
        #if os(visionOS)
        VisionDiag.log("hotkey: \(hotkey.rawValue)")
        #endif
        switch hotkey {
        case .saveState:
            guard saves else { return toast("This game has no save states") }
            core.saveState(slot: slot)
            toast("Saved to slot \(slot)")
        case .loadState:
            guard saves, core.saveStates().contains(where: { $0.slot == slot }) else { return toast("No quick save yet") }
            core.loadState(slot: slot)
            toast("Loaded slot \(slot)")
        case .turbo:
            core.isFastForward.toggle()
            toast(core.isFastForward ? "Turbo on" : "Turbo off")
        case .pause:
            core.setPaused(core.state != .paused)
            toast(core.state == .paused ? "Paused" : "Resumed")
        case .exitGame:
            NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
        }
    }

    private func toast(_ message: String) {
        NotificationCenter.default.post(name: .holofoldToast, object: message)
    }

    #if os(visionOS)
    /// The headset gives apps no device motion, so motion controls come from the controller's own
    /// gyro and accelerometer (DualSense, DualShock 4, Switch Pro …).
    ///
    /// GameController reports them in the controller's frame: x to the right, y toward the bumpers,
    /// z out of the face (Apple's device-frame convention, assumed here and logged on attach so a
    /// device test can confirm it). Holding the pad flat should feel like holding a 3DS upright, so
    /// the vector is turned 90° about x into the frame of a handheld standing upright and facing the
    /// player, which the core takes as CoreMotion portrait (orientation 0).
    private func attachMotion(_ controller: GCController) {
        guard AppSettings.shared.motionControls, let motion = controller.motion else { return }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        az_set_motion_orientation(0)
        let name = controller.vendorName ?? "controller"
        var logged = false
        motion.valueChangedHandler = { m in
            let a: GCAcceleration
            if m.hasGravityAndUserAcceleration {
                a = GCAcceleration(x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y,
                                   z: m.gravity.z + m.userAcceleration.z)
            } else {
                a = m.acceleration
            }
            let r = m.hasRotationRate ? m.rotationRate : GCRotationRate(x: 0, y: 0, z: 0)
            az_motion(Float(a.x), Float(a.z), Float(-a.y), Float(r.x), Float(r.z), Float(-r.y))
            if !logged {
                logged = true
                VisionDiag.log(String(format: "motion: %@ gyro=%d gravity=(%.2f, %.2f, %.2f)", name, m.hasRotationRate ? 1 : 0, a.x, a.y, a.z))
            }
        }
    }

    private func detachMotion() {
        for controller in GCController.controllers() {
            controller.motion?.valueChangedHandler = nil
            if controller.motion?.sensorsRequireManualActivation == true { controller.motion?.sensorsActive = false }
        }
    }
    #endif

    #if os(visionOS)
    /// The PS VR2 Sense pair shows up as one extended gamepad ("PlayStation VR2 Sense Controllers
    /// (L/R)", seen on the device). It has no d-pad, and with the left thumb on the stick the left
    /// face buttons are hard to reach, so on top of the standard layout:
    ///   R2 → Y (same as □: run / fireball), R1 → R, right stick → d-pad (ZR is not mapped).
    private func remapSensePair(_ pad: GCExtendedGamepad) {
        func bind(_ input: GCControllerButtonInput?, _ button: AZButton) {
            input?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        bind(pad.rightTrigger, AZ_BUTTON_Y)
        bind(pad.rightShoulder, AZ_BUTTON_R)
        pad.rightThumbstick.valueChangedHandler = Self.stickAsDpad()
        VisionDiag.log("PS VR2 Sense pair: R2→Y, R1→R, right stick→d-pad")
    }

    /// START on press; held for 1.2 s it asks the game window to exit.
    private static func startWithExitHold() -> GCControllerButtonValueChangedHandler {
        var hold: Task<Void, Never>?
        return { _, _, pressed in
            az_button(AZ_BUTTON_START, pressed)
            hold?.cancel()
            hold = nil
            guard pressed else { return }
            Task { @MainActor in InputManager.shared.gamepadUsed() }
            hold = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                VisionDiag.log("exit: Options held")
                NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
            }
        }
    }

    /// A stick as a digital d-pad with a dead zone, so menus step one item at a time.
    private static func stickAsDpad() -> GCControllerDirectionPadValueChangedHandler {
        var held = Set<UInt32>()
        return { _, x, y in
            let threshold: Float = 0.5
            var now = Set<UInt32>()
            if y > threshold { now.insert(AZ_BUTTON_UP.rawValue) }
            if y < -threshold { now.insert(AZ_BUTTON_DOWN.rawValue) }
            if x < -threshold { now.insert(AZ_BUTTON_LEFT.rawValue) }
            if x > threshold { now.insert(AZ_BUTTON_RIGHT.rawValue) }
            for raw in now.symmetricDifference(held) {
                az_button(AZButton(rawValue: raw), now.contains(raw))
            }
            if !now.isEmpty, held.isEmpty { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            held = now
        }
    }

    /// A PS VR2 Sense controller that reaches the app only as a spatial accessory (visionOS 27):
    /// the left one never showed up as a GCController in one device run while the right one did.
    /// Same layout as attachSpatial, read through the accessory's physical input. Which hand comes
    /// from the "(L)"/"(R)" in its name, else from its face buttons.
    @available(visionOS 27.0, *)
    private func attachAccessory(_ accessory: GCSpatialAccessory) {
        guard let input = accessory.input else {
            VisionDiag.log("spatial accessory without input: \(accessory.vendorName ?? "?")")
            return
        }
        accessories.append(accessory)
        let name = accessory.vendorName ?? ""
        var right = name.contains("(R)")
        var startHold: Task<Void, Never>?
        var dpadHeld = Set<UInt32>()
        var logged = false
        input.elementValueDidChangeHandler = { _, element in
            let aliases = element.aliases
            func has(_ alias: String) -> Bool { aliases.contains(alias) }
            if !name.contains("(L)"), !name.contains("(R)"), has("Button A") || has("Button B") { right = true }
            if !logged {
                logged = true
                VisionDiag.log("spatial accessory input from \(name): \(aliases.sorted().joined(separator: ","))")
            }
            if let pad = element as? GCDirectionPadElement {
                let v = pad.xyAxes.value
                if right {
                    let t: Float = 0.5
                    var now = Set<UInt32>()
                    if v.y > t { now.insert(AZ_BUTTON_UP.rawValue) }
                    if v.y < -t { now.insert(AZ_BUTTON_DOWN.rawValue) }
                    if v.x < -t { now.insert(AZ_BUTTON_LEFT.rawValue) }
                    if v.x > t { now.insert(AZ_BUTTON_RIGHT.rawValue) }
                    for raw in now.symmetricDifference(dpadHeld) { az_button(AZButton(rawValue: raw), now.contains(raw)) }
                    dpadHeld = now
                } else {
                    az_stick(AZ_STICK_CIRCLE_PAD, v.x, v.y)
                }
                return
            }
            guard let button = element as? GCButtonElement else { return }
            let pressed = button.pressedInput.isPressed
            let target: AZButton?
            if has("Button Menu") || has("Button Options") || has("Button Share") {
                if right {
                    az_button(AZ_BUTTON_START, pressed)
                    startHold?.cancel()
                    startHold = pressed ? Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        guard !Task.isCancelled else { return }
                        VisionDiag.log("exit: Options held (accessory)")
                        NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
                    } : nil
                    return
                }
                target = AZ_BUTTON_SELECT
            } else if has("Button A") {
                target = AZ_BUTTON_B
            } else if has("Button B") {
                target = AZ_BUTTON_A
            } else if has("Button X") {
                target = AZ_BUTTON_Y
            } else if has("Button Y") {
                target = AZ_BUTTON_X
            } else if has("Trigger") {
                target = right ? AZ_BUTTON_Y : AZ_BUTTON_L
            } else if has("Grip") {
                target = right ? AZ_BUTTON_R : AZ_BUTTON_ZL
            } else {
                target = nil
            }
            if let target {
                az_button(target, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        VisionDiag.log("spatial accessory attached: \(name) as \(right ? "right" : "left")")
    }

    /// PlayStation VR2 Sense controllers connected one by one (each a "Spatial Controller"; seen
    /// on the device when only the right one was on). No d-pad.
    ///   left:  stick → circle pad, △ X, □ Y, trigger (L2) L, L1 ZL, create SELECT
    ///   right: stick → d-pad, ○ A, ✕ B, trigger (R2) Y (= □, so skills need no left button),
    ///          R1 R, options START (hold: exit game)
    /// Which hand: the right one reports A/B (✕/○), the left one X/Y (□/△).
    private func attachSpatial(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        let isRight = profile.buttons[GCInputButtonA] != nil || profile.buttons[GCInputButtonB] != nil
        func bind(_ name: String, _ button: AZButton) {
            profile.buttons[name]?.pressedChangedHandler = { _, _, pressed in
                az_button(button, pressed)
                if pressed { Task { @MainActor in InputManager.shared.gamepadUsed() } }
            }
        }
        if isRight {
            bind(GCInputButtonB, AZ_BUTTON_A)
            bind(GCInputButtonA, AZ_BUTTON_B)
            bind(__GCInputButtonName.trigger.rawValue, AZ_BUTTON_Y)
            bind(__GCInputButtonName.gripButton.rawValue, AZ_BUTTON_R)
            profile.buttons[GCInputButtonMenu]?.pressedChangedHandler = Self.startWithExitHold()
            profile.buttons[GCInputButtonOptions]?.pressedChangedHandler = Self.startWithExitHold()
            profile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.valueChangedHandler = Self.stickAsDpad()
        } else {
            bind(GCInputButtonY, AZ_BUTTON_X)
            bind(GCInputButtonX, AZ_BUTTON_Y)
            bind(__GCInputButtonName.trigger.rawValue, AZ_BUTTON_L)
            bind(__GCInputButtonName.gripButton.rawValue, AZ_BUTTON_ZL)
            bind(GCInputButtonShare, AZ_BUTTON_SELECT)
            bind(GCInputButtonOptions, AZ_BUTTON_SELECT)
            profile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.valueChangedHandler = { _, x, y in
                az_stick(AZ_STICK_CIRCLE_PAD, x, y)
            }
        }
        VisionDiag.log("PS VR2 Sense (\(isRight ? "right" : "left")) buttons=\(profile.buttons.keys.sorted().joined(separator: ",")) dpads=\(profile.dpads.keys.sorted().joined(separator: ","))")
    }
    #endif

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let kb = keyboard?.keyboardInput else { return }
        let map: [GCKeyCode: AZButton] = [
            .keyX: AZ_BUTTON_A, .keyZ: AZ_BUTTON_B, .keyS: AZ_BUTTON_X, .keyA: AZ_BUTTON_Y,
            .keyQ: AZ_BUTTON_L, .keyW: AZ_BUTTON_R, .one: AZ_BUTTON_ZL, .two: AZ_BUTTON_ZR,
            .returnOrEnter: AZ_BUTTON_START, .rightShift: AZ_BUTTON_SELECT, .keyH: AZ_BUTTON_HOME,
            .upArrow: AZ_BUTTON_UP, .downArrow: AZ_BUTTON_DOWN, .leftArrow: AZ_BUTTON_LEFT, .rightArrow: AZ_BUTTON_RIGHT,
        ]
        var stickKeys = Set<GCKeyCode>()
        kb.keyChangedHandler = { _, _, code, pressed in
            if let b = map[code] {
                az_button(b, pressed)
                return
            }
            let stickCodes: [GCKeyCode] = [.keyI, .keyJ, .keyK, .keyL]
            guard stickCodes.contains(code) else { return }
            if pressed { stickKeys.insert(code) } else { stickKeys.remove(code) }
            let x: Float = (stickKeys.contains(.keyL) ? 1 : 0) - (stickKeys.contains(.keyJ) ? 1 : 0)
            let y: Float = (stickKeys.contains(.keyI) ? 1 : 0) - (stickKeys.contains(.keyK) ? 1 : 0)
            az_stick(AZ_STICK_CIRCLE_PAD, x, y)
        }
    }

    // MARK: Motion

    #if !os(visionOS)
    private func startMotion() {
        guard AppSettings.shared.motionControls, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: OperationQueue()) { data, _ in
            guard let d = data else { return }
            let g = d.gravity, a = d.userAcceleration, r = d.rotationRate
            az_motion(Float(g.x + a.x), Float(g.y + a.y), Float(g.z + a.z),
                      Float(r.x), Float(r.y), Float(r.z))
        }
    }

    private func updateOrientation() {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }.first ?? .portrait
        switch orientation {
        case .landscapeRight: az_set_motion_orientation(1) // home indicator on the right
        case .portraitUpsideDown: az_set_motion_orientation(2)
        case .landscapeLeft: az_set_motion_orientation(3)
        default: az_set_motion_orientation(0)
        }
    }
    #endif
}

extension Notification.Name {
    /// A controller's PS / Home button: the game window closes the game (visionOS).
    static let bifoldExitGame = Notification.Name("BifoldExitGame")
}

/// One extended gamepad's buttons, sticks and d-pad, routed through ControllerMapping.live on
/// every event. GameController calls the handlers on the main queue, which is the only place
/// this state is touched.
final class GamepadRouter {
    /// Set by Settings › Controls while it waits for a button (InputManager.beginCapture).
    nonisolated(unsafe) static var capture: ((String) -> Void)?
    /// A game is on screen (InputManager.start / stop).
    nonisolated(unsafe) static var active = false

    /// What each held input pressed, so its release lets go of the same 3DS button even if the
    /// mapping changed in between.
    private var held: [String: AZButton] = [:]
    /// Inputs whose press was used by a hotkey or a capture: their release is dropped too.
    private var swallowed = Set<String>()
    private var padHeld: [String: Set<UInt32>] = [:]
    private var hotkeyDown = false
    private var comboUsed = false
    /// The hotkey button's own 3DS button (Select by default), held back until it is clear the
    /// press is not the start of a hotkey: sent once held 0.35 s alone, or as a tap on release.
    private var deferred: AZButton?
    private var deferredSent = false
    private var deferTimer: DispatchWorkItem?
    private var exitHold: DispatchWorkItem?

    func button(_ name: String, _ pressed: Bool) {
        if !pressed, swallowed.remove(name) != nil { return }
        if pressed, let capture = Self.capture {
            swallowed.insert(name)
            capture(name)
            return
        }
        if !pressed, let target = held.removeValue(forKey: name) {
            release(target)
            return
        }
        guard Self.active else { return }
        let config = ControllerMapping.live
        #if os(visionOS)
        // The system keeps the PS / Home button for itself (it never reached the app on the
        // device); if a pad does pass it on, it leaves the game.
        if name == GCInputButtonHome {
            if pressed { NotificationCenter.default.post(name: .bifoldExitGame, object: nil) }
            return
        }
        #endif
        if config.hotkeysEnabled, name == config.hotkeyButton {
            hotkeyChanged(pressed, own: config.target(for: name))
            return
        }
        guard pressed else { return }
        if hotkeyDown, let hotkey = config.hotkey(for: name) {
            comboUsed = true
            swallowed.insert(name)
            Task { @MainActor in InputManager.shared.perform(hotkey) }
            return
        }
        guard let target = config.target(for: name) else { return }
        held[name] = target
        press(target)
    }

    func pad(_ name: String, _ x: Float, _ y: Float) {
        guard Self.active, Self.capture == nil else { return }
        switch ControllerMapping.live.stickTarget(forPad: name) {
        case .circlePad: az_stick(AZ_STICK_CIRCLE_PAD, x, y)
        case .cStick: az_stick(AZ_STICK_C_STICK, x, y)
        case .dpad: digital(name, x, y)
        case .none: break
        }
    }

    /// A stick or d-pad as d-pad buttons, with a dead zone so menus step one item at a time.
    private func digital(_ name: String, _ x: Float, _ y: Float) {
        let threshold: Float = 0.5
        var now = Set<UInt32>()
        if y > threshold { now.insert(AZ_BUTTON_UP.rawValue) }
        if y < -threshold { now.insert(AZ_BUTTON_DOWN.rawValue) }
        if x < -threshold { now.insert(AZ_BUTTON_LEFT.rawValue) }
        if x > threshold { now.insert(AZ_BUTTON_RIGHT.rawValue) }
        let before = padHeld[name] ?? []
        for raw in now.symmetricDifference(before) {
            az_button(AZButton(rawValue: raw), now.contains(raw))
        }
        if !now.isEmpty, before.isEmpty { Task { @MainActor in InputManager.shared.gamepadUsed() } }
        padHeld[name] = now
    }

    private func hotkeyChanged(_ pressed: Bool, own: AZButton?) {
        deferTimer?.cancel()
        deferTimer = nil
        if pressed {
            hotkeyDown = true
            comboUsed = false
            deferred = own
            deferredSent = false
            guard let own else { return }
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.hotkeyDown, !self.comboUsed else { return }
                self.deferredSent = true
                self.press(own)
            }
            deferTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: timer)
            return
        }
        hotkeyDown = false
        defer { deferred = nil; deferredSent = false }
        guard let own = deferred else { return }
        if deferredSent {
            release(own)
        } else if !comboUsed {
            // A short press on its own: a tap of its 3DS button, long enough for a game to see.
            press(own)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.release(own) }
        }
    }

    private func press(_ button: AZButton) {
        az_button(button, true)
        Task { @MainActor in InputManager.shared.gamepadUsed() }
        #if os(visionOS)
        // Holding START leaves the game (the PS / Home button is the system's).
        if button == AZ_BUTTON_START {
            exitHold?.cancel()
            let hold = DispatchWorkItem {
                VisionDiag.log("exit: START held")
                NotificationCenter.default.post(name: .bifoldExitGame, object: nil)
            }
            exitHold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hold)
        }
        #endif
    }

    private func release(_ button: AZButton) {
        az_button(button, false)
        if button == AZ_BUTTON_START {
            exitHold?.cancel()
            exitHold = nil
        }
    }
}
