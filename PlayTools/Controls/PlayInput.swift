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
        for action in self.actions{
            action.invalidate()
        }
    }

    func setup() {
        actions = []
        var counter = 2
        for key in settings.layout {
            if key.count == 4 {
                actions.append(ButtonAction(id: counter,
                                            keyid: Int(key[0]),
                                            key: GCKeyCode.init(rawValue: CFIndex(key[0])),
                                            point: CGPoint(x: key[1].absoluteX,
                                                           y: key[2].absoluteY)))
            } else if key.count == 8 {
                actions.append(JoystickAction(id: counter,
                                              keys:  [GCKeyCode.init(rawValue: CFIndex(key[0])),
                                                      GCKeyCode.init(rawValue: CFIndex(key[1])),
                                                      GCKeyCode.init(rawValue: CFIndex(key[2])),
                                                      GCKeyCode.init(rawValue: CFIndex(key[3]))],
                                              center: CGPoint(x: key[4].absoluteX,
                                                              y: key[5].absoluteY),
                                              shift: key[6].absoluteSize))
            } else if key.count == 2 && PlaySettings.shared.gamingMode {
                PlayMice.shared.setup(key)
            }
            counter += 1
        }
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.keyChangedHandler = { _, _, keyCode, _ in
                if editor.editorMode
                    && !PlayInput.cmdPressed()
                    && !PlayInput.FORBIDDEN.contains(keyCode)
                    && self.isSafeToBind(keyboard){
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

    private func isSafeToBind(_ input : GCKeyboardInput) -> Bool {
           var result = true
           for forbidden in PlayInput.FORBIDDEN {
               if input.button(forKeyCode: forbidden)?.isPressed ?? false {
                   result = false
                   break
               }
           }
           return result
       }

    private static let FORBIDDEN : [GCKeyCode] = [
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
        if PlaySettings.shared.keymapping == false {
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
        // dont know how to dynamically get it here
        let NSEventMaskKeyDown: UInt64 = 1024
        Dynamic.NSEvent.addLocalMonitorForEventsMatchingMask( NSEventMaskKeyDown, handler: { event in
            if (mode.visible && !EditorController.shared.editorMode) || PlayInput.cmdPressed() {
                return event
            }
//            Toast.showOver(msg: "mask: \(NSEventMaskKeyDown)")
            return nil
        } as ResponseBlock)
    }
}
