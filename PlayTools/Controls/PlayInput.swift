import Foundation
import GameController
import UIKit

final class PlayInput: NSObject {
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

        if settings.gamingMode {
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
            keyboard.button(forKeyCode: GCKeyCode(rawValue: 227))?.pressedChangedHandler = { _, _, pressed in
                PlayInput.lCmdPressed = pressed
            }
            keyboard.button(forKeyCode: GCKeyCode(rawValue: 231))?.pressedChangedHandler = { _, _, pressed in
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
        // return keyboard.button(forKeyCode: GCKeyCode(rawValue: 227))!.isPressed
        // || keyboard.button(forKeyCode: GCKeyCode(rawValue: 231))!.isPressed
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
        GCKeyCode.init(rawValue: 227), // LCmd
        GCKeyCode.init(rawValue: 231), // RCmd
        .leftAlt,
        .rightAlt,
        .printScreen
    ]

    private func swapMode(_ pressed: Bool) {
        if !PlaySettings.shared.gamingMode {
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
        // fix beep sound
        eliminateRedundantKeyPressEvents()
    }

    private func eliminateRedundantKeyPressEvents() {
        // TODO later: should not be hard-coded
        let NSEventMaskKeyDown: UInt64 = 1024
        Dynamic.NSEvent.addLocalMonitorForEventsMatchingMask( NSEventMaskKeyDown, handler: { event in
            if (mode.visible && !EditorController.shared.editorMode) || PlayInput.cmdPressed() {
                return event
            }
            return nil
        } as ResponseBlock)
    }
}
