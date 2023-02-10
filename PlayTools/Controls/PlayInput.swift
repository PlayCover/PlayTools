import Foundation
import GameController
import UIKit

class PlayInput {
    static let shared = PlayInput()
    var actions = [Action]()
    var timeoutForBind = true
    static private var whichShift: UInt16 = 60
    static private var lCmdPressed = false
    static private var rCmdPressed = false

    static public var buttonHandlers: [String: [(Bool) -> Void]] = [:]

    func invalidate() {
        for action in self.actions {
            action.invalidate()
        }
        PlayInput.buttonHandlers.removeAll(keepingCapacity: true)
        GCController.current?.extendedGamepad?.valueChangedHandler = nil
    }

    static public func registerButton(key: String, handler: @escaping (Bool) -> Void) {
        if PlayInput.buttonHandlers[key] == nil {
            PlayInput.buttonHandlers[key] = []
        }
        PlayInput.buttonHandlers[key]!.append(handler)
    }

    func keyboardHandler(_ keyCode: UInt16, _ pressed: Bool) {
        guard let name = KeyCodeNames.virtualCodes[keyCode] else {
            Toast.showOver(msg: "keycode \(keyCode) is not recognized")
            return
        }
        guard let handlers = PlayInput.buttonHandlers[name] else {
            return
        }
        for handler in handlers {
            handler(pressed)
        }
    }

    func controllerButtonHandler(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        let name: String = element.aliases.first!
        if let buttonElement = element as? GCControllerButtonInput {
//            Toast.showOver(msg: "recognised controller button: \(name)")
            guard let handlers = PlayInput.buttonHandlers[name] else { return }
            Toast.showOver(msg: name + ": \(buttonElement.isPressed)")
            for handler in handlers {
                handler(buttonElement.isPressed)
            }
        } else if let dpadElement = element as? GCControllerDirectionPad {
            PlayMice.shared.handleControllerDirectionPad(profile, dpadElement)
        } else {
            Toast.showOver(msg: "unrecognised controller element input happens")
        }
    }

    func parseKeymap() {
        actions = []
        for button in keymap.keymapData.buttonModels {
            actions.append(ButtonAction(data: button))
        }

        for draggableButton in keymap.keymapData.draggableButtonModels {
            actions.append(DraggableButtonAction(data: draggableButton))
        }

        for mouse in keymap.keymapData.mouseAreaModel {
            if mouse.keyName.hasSuffix("tick") || settings.mouseMapping {
                actions.append(CameraAction(data: mouse))
            }
        }

        for joystick in keymap.keymapData.joystickModel {
            // Left Thumbstick, Right Thumbstick, Mouse
            if joystick.keyName.contains(Character("u")) {
                actions.append(ContinuousJoystickAction(data: joystick))
            } else { // Keyboard
                actions.append(JoystickAction(data: joystick))
            }
        }
    }

    public func toggleEditor(show: Bool) {
        mode.show(show)
        if show {
            if let keyboard = GCKeyboard.coalesced!.keyboardInput {
                keyboard.keyChangedHandler = { _, _, keyCode, _ in
                    if !PlayInput.cmdPressed()
                        && !PlayInput.FORBIDDEN.contains(keyCode)
                        && self.isSafeToBind(keyboard) {
                        if KeyCodeNames.keyCodes[keyCode.rawValue] == nil {
                            Toast.showOver(msg: "This key cannot be mapped")
                            return
                        }
                        EditorController.shared.setKey(keyCode.rawValue)
                    }
                }
            }
            if let controller = GCController.current?.extendedGamepad {
                controller.valueChangedHandler = { _, element in
                    // This is the index of controller buttons, which is String, not Int
                    var alias: String = element.aliases.first!
                    if alias == "Direction Pad" {
                        guard let dpadElement = element as? GCControllerDirectionPad else {
                            Toast.showOver(msg: "cannot map direction pad: element type not recognizable")
                            return
                        }
                        if dpadElement.xAxis.value > 0 {
                            alias = dpadElement.right.aliases.first!
                        } else if dpadElement.xAxis.value < 0 {
                            alias = dpadElement.left.aliases.first!
                        }
                        if dpadElement.yAxis.value > 0 {
                            alias = dpadElement.down.aliases.first!
                        } else if dpadElement.yAxis.value < 0 {
                            alias = dpadElement.up.aliases.first!
                        }
                    }
                    EditorController.shared.setKey(alias)
                }
            }
        }
    }

    func setup() {
        parseKeymap()
        GCController.current?.extendedGamepad?.valueChangedHandler = controllerButtonHandler
    }

    static public func cmdPressed() -> Bool {
        return lCmdPressed || rCmdPressed
    }

    private func isSafeToBind(_ input: GCKeyboardInput) -> Bool {
           var result = true
           for forbidden in PlayInput.FORBIDDEN where input.button(forKeyCode: forbidden)?.isPressed ?? false {
               result = false
               break
           }
           return result
       }

    private static let FORBIDDEN: [GCKeyCode] = [
        .leftGUI,
        .rightGUI,
        .leftAlt,
        .rightAlt,
        .printScreen
    ]

    private func swapMode(_ pressed: Bool) {
        if !settings.mouseMapping {
            return
        }
        if pressed {
            if !mode.visible {
                self.invalidate()
            }
            mode.show(!mode.visible)
        }
    }

    var root: UIViewController? {
        return screen.window?.rootViewController
    }

    func setupHotkeys() {
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.button(forKeyCode: .leftGUI)?.pressedChangedHandler = { _, _, pressed in
                PlayInput.lCmdPressed = pressed
            }
            keyboard.button(forKeyCode: .rightGUI)?.pressedChangedHandler = { _, _, pressed in
                PlayInput.rCmdPressed = pressed
            }
            keyboard.button(forKeyCode: .leftAlt)?.pressedChangedHandler = { _, _, pressed in
                self.swapMode(pressed)
            }
            keyboard.button(forKeyCode: .rightAlt)?.pressedChangedHandler = { _, _, pressed in
                self.swapMode(pressed)
            }
            // TODO: set a timeout to display usage guide of Option and Keymapping menu in turn
        }
    }

    func initialize() {
        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name.GCKeyboardDidConnect, object: nil, queue: main) { _ in
            self.setupHotkeys()
            if !mode.visible {
                self.setup()
            }
        }

        centre.addObserver(forName: NSNotification.Name.GCMouseDidConnect, object: nil, queue: main) { _ in
            if !mode.visible {
                self.setup()
            }
        }

        centre.addObserver(forName: NSNotification.Name.GCControllerDidConnect, object: nil, queue: main) { _ in
            if !mode.visible {
                self.setup()
            }
            if EditorController.shared.editorMode {
                self.toggleEditor(show: true)
            }
        }

        setupHotkeys()

        AKInterface.shared!.setupKeyboard {keycode, pressed in
            let consumed = !mode.visible && !PlayInput.cmdPressed()
            if !consumed {
                return false
            }
            var code = keycode
            if code == 56 {
                if pressed {
                    if GCKeyboard.pressed(key: GCKeyCode(rawValue: 229)) {
                        // Actually right shift
                        code = 60
                    }
                    PlayInput.whichShift = code
                } else {
                    code = PlayInput.whichShift
                }
            }
            self.keyboardHandler(code, pressed)
            return consumed
        }
        AKInterface.shared!.setupMouseMove {deltaX, deltaY in
            if mode.visible {
                return false
            }
            if settings.mouseMapping {
                PlayMice.shared.handleMouseMoved(deltaX: deltaX, deltaY: deltaY)
            } else {
                PlayMice.shared.handleFakeMouseMoved(deltaX: deltaX, deltaY: deltaY)
            }
            return true
        }
    }
}
