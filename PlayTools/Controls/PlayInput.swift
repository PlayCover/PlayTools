import Foundation
import GameController
import UIKit

class PlayInput {
    static let shared = PlayInput()
    var actions = [Action]()
    var timeoutForBind = true

    static private var lCmdPressed = false
    static private var rCmdPressed = false

    func invalidate() {
        PlayMice.shared.stop()
        for action in self.actions {
            action.invalidate()
        }
    }

    func setup() {
        actions = []
        // ID 1 is left for mouse area
        var counter = 2
        for button in keymap.keymapData.buttonModels {
            actions.append(ButtonAction(id: counter, data: button))
            counter += 1
        }

        for draggableButton in keymap.keymapData.draggableButtonModels {
                actions.append(DraggableButtonAction(id: counter, data: draggableButton))
                counter += 1
        }

        if settings.mouseMapping {
            for mouse in keymap.keymapData.mouseAreaModel {
                PlayMice.shared.setup(mouse)
                counter += 1
            }
        }

        for joystick in keymap.keymapData.joystickModel {
            actions.append(JoystickAction(id: counter, data: joystick))
            counter += 1
        }

        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.keyChangedHandler = { _, _, keyCode, _ in
                if editor.editorMode
                    && !PlayInput.cmdPressed()
                    && !PlayInput.FORBIDDEN.contains(keyCode)
                    && self.isSafeToBind(keyboard) {
                    EditorController.shared.setKeyCode(keyCode.rawValue)
                }
            }
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
        }
    }

    static public func cmdPressed() -> Bool {
        return lCmdPressed || rCmdPressed
    }

    private func isSafeToBind(_ input: GCKeyboardInput) -> Bool {
           var result = true
           for forbidden in PlayInput.FORBIDDEN {
               if input.button(forKeyCode: forbidden)?.isPressed ?? false {
                   result = false
                   break
               }
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

    func initialize() {
        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name.GCKeyboardDidConnect, object: nil, queue: main) { _ in
            PlayInput.shared.setup()
        }

        centre.addObserver(forName: NSNotification.Name.GCMouseDidConnect, object: nil, queue: main) { _ in
            PlayInput.shared.setup()
        }

        setup()

        // Fix beep sound
        AKInterface.shared!
            .eliminateRedundantKeyPressEvents({ self.dontIgnore() })
    }

    func dontIgnore() -> Bool {
        (mode.visible && !EditorController.shared.editorMode) || PlayInput.cmdPressed()
    }
}
