import Foundation
import GameController
import UIKit

class PlayInput {
    static let shared = PlayInput()
    var actions: [Action] = []
    var inputEnabled = false

    static private var lCmdPressed = false
    static private var rCmdPressed = false

    static public func cmdPressed() -> Bool {
        return lCmdPressed || rCmdPressed
    }

    func initialize() {
        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name.GCKeyboardDidConnect, object: nil, queue: main) { _ in
            self.initGCHandlers()
        }

        centre.addObserver(forName: NSNotification.Name.GCMouseDidConnect, object: nil, queue: main) { _ in
            self.initGCHandlers()
        }

        centre.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: main) { _ in
            self.initGCHandlers()
        }

        setup()

        // Fix beep sound
        AKInterface.shared!
            .eliminateRedundantKeyPressEvents({ self.dontIgnore() })
    }

    func invalidate() {
        for action in self.actions {
            action.invalidate()
        }
    }

    func setup() {
        if settings.mouseMapping {
            for mouse in keymap.keymapData.mouseAreaModel {
                PlayMice.shared.setup(mouse)
            }
        }

        // ID 1 is left for mouse area
        var counter = 2
        for button in keymap.keymapData.buttonModels {
            actions.append(ButtonAction(id: counter, data: button))
            counter += 1
        }

        for joystick in keymap.keymapData.joystickModel {
            actions.append(JoystickAction(id: counter, data: joystick))
            counter += 1
        }
    }

    func initGCHandlers() {
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.keyChangedHandler = { _, _, keyCode, _ in
                if editor.editorEnabled
                    && !PlayInput.cmdPressed()
                    && !PlayInput.forbiddenKeys.contains(keyCode) {
                    // EditorController.shared.setKeyCode(keyCode.rawValue)
                }
            }
            keyboard.button(forKeyCode: .leftGUI)?.pressedChangedHandler = { _, _, pressed in
                PlayInput.lCmdPressed = pressed
            }
            keyboard.button(forKeyCode: .rightGUI)?.pressedChangedHandler = { _, _, pressed in
                PlayInput.rCmdPressed = pressed
            }
            keyboard.button(forKeyCode: .leftAlt)?.pressedChangedHandler = { _, _, pressed in
                print("Option pressed")
                if pressed {
                    self.inputEnabled.toggle()
                }
            }
            keyboard.button(forKeyCode: .rightAlt)?.pressedChangedHandler = { _, _, pressed in
                print("Option pressed")
                if pressed {
                    self.inputEnabled.toggle()
                }
            }
        }

        print("Handlers init")
        for action in actions {
            action.initGCHandlers()
        }
    }

    func toggleInput() {
        if !EditorController.shared.editorEnabled {
            if inputEnabled {
                if PlaySettings.shared.mouseMapping {
                    AKInterface.shared!.unhideCursor()
                    disableCursor(1)
                }
                PlayInput.shared.invalidate()
            } else {
                if PlaySettings.shared.mouseMapping {
                    AKInterface.shared!.hideCursor()
                    disableCursor(0)
                }
                PlayInput.shared.initGCHandlers()
            }
        }
    }

    private static let forbiddenKeys: [GCKeyCode] = [
        .leftGUI,
        .rightGUI,
        .leftAlt,
        .rightAlt,
        .printScreen
    ]

    func dontIgnore() -> Bool {
        (inputEnabled && !EditorController.shared.editorEnabled) || PlayInput.cmdPressed()
    }
}
