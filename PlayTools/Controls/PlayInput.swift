import Foundation
import GameController
import UIKit

class PlayInput {
    static let shared = PlayInput()
    var actions = [Action]()
    static var shouldLockCursor = true

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher", qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)
    static public var buttonHandlers: [String: [(Bool) -> Void]] = [:],
                    draggableHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
                    cameraMoveHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
                    cameraScaleHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
                    joystickHandler: [String: (CGFloat, CGFloat) -> Void] = [:]

    func invalidate() {
        // this is called whenever keymapping disabled, to release all mapping resource
        for action in self.actions {
            action.invalidate()
        }
    }

    static public func registerButton(key: String, handler: @escaping (Bool) -> Void) {
        // this function is called when setting up `button` type of mapping
        if "LMB" == key {
            PlayInput.shouldLockCursor = true
        }
        if PlayInput.buttonHandlers[key] == nil {
            PlayInput.buttonHandlers[key] = []
        }
        PlayInput.buttonHandlers[key]!.append(handler)
    }

    func parseKeymap() {
        actions = [PlayMice.shared]
        PlayInput.buttonHandlers.removeAll(keepingCapacity: true)
        // `shouldLockCursor` is used to disable `option` toggle when there is no mouse mapping
        // but in the case this new feature disabled, `option` should always function.
        // this variable is initilized here to be checked for mouse mapping later.
        // intialize it to the reverse of the new feature's enable state makes
        // it always true if the new feature is disabled, as it won't be set false in
        // any case anywhere else in this case.
        PlayInput.shouldLockCursor = !PlaySettings.shared.noKMOnInput
        for button in keymap.keymapData.buttonModels {
            actions.append(ButtonAction(data: button))
        }

        for draggableButton in keymap.keymapData.draggableButtonModels {
            actions.append(DraggableButtonAction(data: draggableButton))
        }

        for mouse in keymap.keymapData.mouseAreaModel {
            actions.append(CameraAction(data: mouse))
        }

        for joystick in keymap.keymapData.joystickModel {
            // Left Thumbstick, Right Thumbstick, Mouse
            if joystick.keyName.contains(Character("u")) {
                actions.append(ContinuousJoystickAction(data: joystick))
            } else { // Keyboard
                actions.append(JoystickAction(data: joystick))
            }
        }
        if !PlayInput.shouldLockCursor {
            PlayInput.shouldLockCursor = PlayMice.shared.mouseMovementMapped()
        }
    }

    public func toggleEditor(show: Bool) {
        mode.setMapping(!show)
        Toucher.writeLog(logMessage: "editor opened? \(show)")
        if show {
            self.invalidate()
            // there is no special reason to use GC API for editor, instead of NSEvents.
            // just voider did this and I'm not changing it yet.
            if let keyboard = GCKeyboard.coalesced!.keyboardInput {
                keyboard.keyChangedHandler = { _, _, keyCode, pressed in
                    PlayKeyboard.handleEditorEvent(keyCode: keyCode, pressed: pressed)
                }
            }
            if let controller = GCController.current?.extendedGamepad {
                controller.valueChangedHandler = PlayController.handleEditorEvent
            }
        } else {
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
            PlayController.initialize()
            parseKeymap()
            _ = ControlMode.trySwap()
        }
    }

    static public func cmdPressed() -> Bool {
        return AKInterface.shared!.cmdPressed
    }

    func initialize() {
        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name.GCControllerDidConnect, object: nil, queue: main) { _ in
            if EditorController.shared.editorMode {
                self.toggleEditor(show: true)
            } else {
                PlayController.initialize()
            }
        }
        parseKeymap()
        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if !mode.visible {
                AKInterface.shared!.warpCursor()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
            if !mode.visible || self.actions.count <= 0 || !PlayInput.shouldLockCursor {
                return
            }
            Toast.initialize()
        }
        PlayKeyboard.initialize()
        PlayMice.shared.initialize()

    }
}

class PlayKeyboard {
    public static func handleEditorEvent(keyCode: GCKeyCode, pressed: Bool) {
        if !PlayInput.cmdPressed()
            && !PlayKeyboard.FORBIDDEN.contains(keyCode)
            && KeyCodeNames.keyCodes[keyCode.rawValue] != nil {
            EditorController.shared.setKey(keyCode.rawValue)
        }
    }

    private static let FORBIDDEN: [GCKeyCode] = [
        .leftGUI,
        .rightGUI,
        .leftAlt,
        .rightAlt,
        .printScreen
    ]

    static func handleEvent(_ keyCode: UInt16, _ pressed: Bool) -> Bool {
        let name = KeyCodeNames.virtualCodes[keyCode] ?? "Btn"
        guard let handlers = PlayInput.buttonHandlers[name] else {
            return false
        }
        var mapped = false
        for handler in handlers {
            PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                handler(pressed)
            })
            mapped = true
        }
        return mapped
    }

    public static func initialize() {
        let centre = NotificationCenter.default
        let main = OperationQueue.main
        if PlaySettings.shared.noKMOnInput {
            centre.addObserver(forName: UIApplication.keyboardDidHideNotification, object: nil, queue: main) { _ in
                mode.setMapping(true)
                Toucher.writeLog(logMessage: "virtual keyboard did hide")
            }
            centre.addObserver(forName: UIApplication.keyboardWillShowNotification, object: nil, queue: main) { _ in
                mode.setMapping(false)
                Toucher.writeLog(logMessage: "virtual keyboard will show")
            }
        } else {
            // we want to initialize keymapping to false
            mode.setMapping(false)
        }
        AKInterface.shared!.setupKeyboard(keyboard: {keycode, pressed, isRepeat in
            if !mode.keyboardMapped {
                // explicitly ignore repeated Enter key
                return isRepeat && keycode == 36
            }
            if isRepeat {
                return true
            }
            let mapped = PlayKeyboard.handleEvent(keycode, pressed)
            return mapped
        }, // passing the function to be called when `option` pressed.
          // return `true` meaning this key press is consumed, `false` dispatching it to the App
           swapMode: ControlMode.trySwap)
    }
}
