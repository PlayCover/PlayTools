import Foundation
import UIKit
import GameController

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    @objc func drainMainDispatchQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }

    func initialize() {
        // drain the dispatch queue every frame for responding to GCController events
        let displaylink = CADisplayLink(target: self, selector: #selector(drainMainDispatchQueue))
        displaylink.add(to: .main, forMode: .common)

        if PlaySettings.shared.disableBuiltinMouse {
            simulateGCMouseDisconnect()
        }

        if PlaySettings.shared.experimentalHIDBridge {
            HIDControllerBridge.shared.initializeIfNeeded()
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if mode.cursorHidden() {
                AKInterface.shared!.warpCursor()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
            if mode.cursorHidden() || !ActionDispatcher.cursorHideNecessary {
                return
            }
            Toast.initialize()
        }
        mode.initialize()
    }

    private func simulateGCMouseDisconnect() {
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { nofitication in
            guard let mouse = nofitication.object as? GCMouse else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: mouse)
                mouse.mouseInput?.leftButton.pressedChangedHandler = nil
                mouse.mouseInput?.leftButton.valueChangedHandler = nil
                mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                mouse.mouseInput?.rightButton?.valueChangedHandler = nil
                mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                mouse.mouseInput?.middleButton?.valueChangedHandler = nil
                mouse.mouseInput?.auxiliaryButtons?.forEach { button in
                    button.pressedChangedHandler = nil
                    button.valueChangedHandler = nil
                }
                mouse.mouseInput?.scroll.valueChangedHandler = nil
                mouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }
}

private final class HIDControllerBridge {
    static let shared = HIDControllerBridge()
    private static let dpadUpAlias = "Direction Pad Up"
    private static let dpadDownAlias = "Direction Pad Down"
    private static let dpadLeftAlias = "Direction Pad Left"
    private static let dpadRightAlias = "Direction Pad Right"

    private enum HIDAxisProfile {
        case undecided
        case standard
        case zAndRzRightStick
    }

    private enum HIDAxisRole {
        case leftStickX
        case leftStickY
        case rightStickX
        case rightStickY
        case leftTrigger
        case rightTrigger
    }

    private typealias AxisUsageMap = [Int: HIDAxisRole]
    private static let axisUsageByProfile: [HIDAxisProfile: AxisUsageMap] = [
        .standard: [
            0x30: .leftStickX,
            0x31: .leftStickY,
            0x33: .rightStickX,
            0x34: .rightStickY,
            0x32: .leftTrigger,
            0x35: .rightTrigger
        ],
        .zAndRzRightStick: [
            0x30: .leftStickX,
            0x31: .leftStickY,
            0x32: .rightStickX,
            0x35: .rightStickY,
            0x33: .leftTrigger,
            0x34: .rightTrigger
        ]
    ]
    private static let supportedAxisUsages = Set(axisUsageByProfile.values.flatMap { $0.keys })

    private var initialized = false
    private var virtualController: GCVirtualController?
    private var virtualConnected = false
    private var virtualConnecting = false
    private var gcObserversInstalled = false
    private var leftStick = CGPoint.zero
    private var rightStick = CGPoint.zero
    private var dpad = CGPoint.zero
    private var leftTrigger: CGFloat = 0
    private var rightTrigger: CGFloat = 0
    private var axisProfile: HIDAxisProfile = .undecided
    private var observedGenericAxes = Set<Int>()
    private var dpadButtonState: [String: Bool] = [
        HIDControllerBridge.dpadUpAlias: false,
        HIDControllerBridge.dpadDownAlias: false,
        HIDControllerBridge.dpadLeftAlias: false,
        HIDControllerBridge.dpadRightAlias: false
    ]
    private var triggerPressedState: [String: Bool] = [
        GCInputLeftTrigger: false,
        GCInputRightTrigger: false
    ]

    func initializeIfNeeded() {
        if initialized {
            return
        }
        initialized = true
        installGCControllerObserversIfNeeded()
        startVirtualController()

        if let interface = AKInterface.shared {
            interface.setupHIDControllerInput(onConnected: { [self] in
                onDeviceConnected()
            }, onDisconnected: { [self] in
                onDeviceDisconnected()
            }, onButton: { [self] usage, pressed in
                onButton(usage: usage, pressed: pressed)
            }, onAxis: { [self] usage, value in
                onAxis(usage: usage, value: value)
            }, onHat: { [self] hat in
                onHat(value: hat)
            })
        }
    }

    private func startVirtualController() {
        guard #available(iOS 17.0, *) else {
            return
        }

        if virtualConnected {
            return
        }
        if virtualConnecting {
            return
        }

        let controller: GCVirtualController
        if let existing = virtualController {
            controller = existing
        } else {
            let configuration = GCVirtualController.Configuration()
            configuration.elements = [
                GCInputButtonA,
                GCInputButtonB,
                GCInputButtonX,
                GCInputButtonY,
                GCInputLeftShoulder,
                GCInputRightShoulder,
                GCInputLeftTrigger,
                GCInputRightTrigger,
                GCInputDirectionPad,
                GCInputLeftThumbstick,
                GCInputRightThumbstick,
                GCInputLeftThumbstickButton,
                GCInputRightThumbstickButton,
                GCInputButtonMenu,
                GCInputButtonOptions
            ]
            configuration.isHidden = true
            controller = GCVirtualController(configuration: configuration)
            virtualController = controller
        }

        virtualConnecting = true
        controller.connect { [weak self] error in
            guard let self else {
                return
            }
            self.virtualConnecting = false
            if error == nil {
                self.virtualConnected = true
            } else {
                self.virtualConnected = false
            }
        }
    }

    private func onDeviceConnected() {
        if !virtualConnected && !virtualConnecting {
            startVirtualController()
        }
    }

    private func onDeviceDisconnected() {
        leftStick = .zero
        rightStick = .zero
        dpad = .zero
        leftTrigger = 0
        rightTrigger = 0
        axisProfile = .undecided
        observedGenericAxes.removeAll()
        dpadButtonState.keys.forEach { dpadButtonState[$0] = false }
        triggerPressedState.keys.forEach { triggerPressedState[$0] = false }
    }

    private func installGCControllerObserversIfNeeded() {
        if gcObserversInstalled {
            return
        }
        gcObserversInstalled = true

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else {
                return
            }
            let vendor = (notification.object as? GCController)?.vendorName ?? "unknown"
            if vendor == "Apple" {
                self.virtualConnected = true
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else {
                return
            }
            let vendor = (notification.object as? GCController)?.vendorName ?? "unknown"
            if vendor == "Apple" {
                self.virtualConnected = false
                self.virtualController = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                    self?.startVirtualController()
                }
            }
        }
    }

    private func shouldProcessHID() -> Bool {
        if virtualConnected {
            return true
        }
        return GCController.controllers().isEmpty
    }

    private func onButton(usage: Int, pressed: Bool) {
        if !shouldProcessHID() {
            return
        }

        if virtualConnected, #available(iOS 17.0, *), let virtualController,
           let elementName = virtualButtonElement(for: usage) {
            virtualController.setValue(pressed ? 1.0 : 0.0, forButtonElement: elementName)
            return
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        if let alias = fallbackButtonAlias(for: usage) {
            _ = ActionDispatcher.dispatch(key: alias, pressed: pressed)
        }
    }

    private func onAxis(usage: Int, value: CGFloat) {
        if !shouldProcessHID() {
            return
        }

        guard let axisRole = resolveAxisRole(usage: usage, value: value) else {
            return
        }

        switch axisRole {
        case .leftStickX:
            leftStick.x = value
        case .leftStickY:
            leftStick.y = -value
        case .rightStickX:
            rightStick.x = value
        case .rightStickY:
            rightStick.y = -value
        case .leftTrigger:
            leftTrigger = clamp01((value + 1) / 2)
        case .rightTrigger:
            rightTrigger = clamp01((value + 1) / 2)
        }

        if virtualConnected, #available(iOS 17.0, *), let virtualController {
            switch axisRole {
            case .leftStickX, .leftStickY:
                virtualController.setPosition(leftStick, forDirectionPadElement: GCInputLeftThumbstick)
            case .rightStickX, .rightStickY:
                virtualController.setPosition(rightStick, forDirectionPadElement: GCInputRightThumbstick)
            case .leftTrigger:
                virtualController.setValue(leftTrigger, forButtonElement: GCInputLeftTrigger)
            case .rightTrigger:
                virtualController.setValue(rightTrigger, forButtonElement: GCInputRightTrigger)
            }
            return
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        switch axisRole {
        case .leftStickX, .leftStickY:
            _ = ActionDispatcher.dispatch(key: GCInputLeftThumbstick, valueX: leftStick.x, valueY: leftStick.y)
        case .rightStickX, .rightStickY:
            _ = ActionDispatcher.dispatch(key: GCInputRightThumbstick, valueX: rightStick.x, valueY: rightStick.y)
        case .leftTrigger:
            applyFallbackTrigger(alias: GCInputLeftTrigger, value: leftTrigger)
        case .rightTrigger:
            applyFallbackTrigger(alias: GCInputRightTrigger, value: rightTrigger)
        }
    }

    private func resolveAxisRole(usage: Int, value: CGFloat) -> HIDAxisRole? {
        guard Self.supportedAxisUsages.contains(usage) else {
            return nil
        }

        observedGenericAxes.insert(usage)

        if axisProfile == .undecided {
            if observedGenericAxes.contains(0x33) || observedGenericAxes.contains(0x34) {
                axisProfile = .standard
            } else if (usage == 0x32 || usage == 0x35), abs(value) < 0.25 {
                axisProfile = .zAndRzRightStick
            }
        }

        let profile = axisProfile == .undecided ? HIDAxisProfile.standard : axisProfile
        return Self.axisUsageByProfile[profile]?[usage]
    }

    private func onHat(value: Int) {
        if !shouldProcessHID() {
            return
        }

        switch value {
        case 0:
            dpad = CGPoint(x: 0, y: 1)
        case 1:
            dpad = CGPoint(x: 1, y: 1)
        case 2:
            dpad = CGPoint(x: 1, y: 0)
        case 3:
            dpad = CGPoint(x: 1, y: -1)
        case 4:
            dpad = CGPoint(x: 0, y: -1)
        case 5:
            dpad = CGPoint(x: -1, y: -1)
        case 6:
            dpad = CGPoint(x: -1, y: 0)
        case 7:
            dpad = CGPoint(x: -1, y: 1)
        default:
            dpad = .zero
        }

        if virtualConnected, #available(iOS 17.0, *), let virtualController {
            virtualController.setPosition(dpad, forDirectionPadElement: GCInputDirectionPad)
            return
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        applyFallbackDPadState(
            up: dpad.y > 0,
            down: dpad.y < 0,
            left: dpad.x < 0,
            right: dpad.x > 0
        )
    }

    private func applyFallbackDPadState(up: Bool, down: Bool, left: Bool, right: Bool) {
        let nextState: [String: Bool] = [
            HIDControllerBridge.dpadUpAlias: up,
            HIDControllerBridge.dpadDownAlias: down,
            HIDControllerBridge.dpadLeftAlias: left,
            HIDControllerBridge.dpadRightAlias: right
        ]

        for (alias, pressed) in nextState where dpadButtonState[alias] != pressed {
            _ = ActionDispatcher.dispatch(key: alias, pressed: pressed)
        }
        dpadButtonState = nextState
    }

    private func applyFallbackTrigger(alias: String, value: CGFloat) {
        let pressed = value > 0.45
        if triggerPressedState[alias] != pressed {
            _ = ActionDispatcher.dispatch(key: alias, pressed: pressed)
            triggerPressedState[alias] = pressed
        }
    }

    private func virtualButtonElement(for usage: Int) -> String? {
        switch usage {
        case 1: return GCInputButtonA
        case 2: return GCInputButtonB
        case 3: return GCInputButtonX
        case 4: return GCInputButtonY
        case 5: return GCInputLeftShoulder
        case 6: return GCInputRightShoulder
        case 7: return GCInputLeftTrigger
        case 8: return GCInputRightTrigger
        case 9: return GCInputLeftThumbstickButton
        case 10: return GCInputRightThumbstickButton
        case 11: return GCInputButtonMenu
        case 12: return GCInputButtonOptions
        default: return nil
        }
    }

    private func fallbackButtonAlias(for usage: Int) -> String? {
        switch usage {
        case 1: return GCInputButtonA
        case 2: return GCInputButtonB
        case 3: return GCInputButtonX
        case 4: return GCInputButtonY
        case 5: return GCInputLeftShoulder
        case 6: return GCInputRightShoulder
        case 7: return GCInputLeftTrigger
        case 8: return GCInputRightTrigger
        case 9: return GCInputLeftThumbstickButton
        case 10: return GCInputRightThumbstickButton
        case 11: return GCInputButtonMenu
        case 12: return GCInputButtonOptions
        default: return nil
        }
    }

    private func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
