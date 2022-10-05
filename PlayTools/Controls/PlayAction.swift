//
//  PlayAction.swift
//  PlayTools
//

import Foundation
import GameController

protocol Action {
    func invalidate()
}

extension GCKeyboard {
    static func pressed(key: GCKeyCode) -> Bool {
        return GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: key)?.isPressed ?? false
    }
}

class ButtonAction: Action {
    func invalidate() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
        if let gcKey = GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: keyCode) {
            gcKey.pressedChangedHandler = nil

        } else if let gcControllerElement = GCController.current?.extendedGamepad?.elements[keyName] {

            if let gcControllerButton = gcControllerElement as? GCControllerButtonInput {
                gcControllerButton.pressedChangedHandler = nil
            }

        }
    }

    let keyCode: GCKeyCode
    let keyName: String
    let point: CGPoint
    var id: Int

    private func getChangedHandler<T1>(handler: ((T1, Float, Bool) -> Void)?) -> (T1, Float, Bool) -> Void {
        return { button, value, pressed in
            if !mode.visible && !PlayInput.cmdPressed() {
                self.update(pressed: pressed)
            }
            if let previous = handler {
                previous(button, value, pressed)
            }
        }
    }

    init(id: Int, keyCode: GCKeyCode, keyName: String, point: CGPoint) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.point = point
        self.id = id
        if PlayMice.shared.setMiceButtons(keyCode.rawValue, action: self) {
            // No more work to do for mouse buttons
        } else if let gcKey = GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: keyCode) {
            let handler = gcKey.pressedChangedHandler
            gcKey.pressedChangedHandler = getChangedHandler(handler: handler)

        } else if let gcControllerElement = GCController.current?.extendedGamepad?.elements[keyName] {

            if let gcControllerButton = gcControllerElement as? GCControllerButtonInput {
                let handler = gcControllerButton.pressedChangedHandler
                gcControllerButton.pressedChangedHandler = getChangedHandler(handler: handler)
            }

        } else {
            Toast.showOver(msg: "failed to map button at point \(point)")
        }
    }

    convenience init(id: Int, data: Button) {
        let keyCode = GCKeyCode(rawValue: data.keyCode)
        self.init(
            id: id,
            keyCode: keyCode,
            keyName: data.keyName,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY))
    }

    func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
        }
    }
}

class DraggableButtonAction: ButtonAction {
    var releasePoint: CGPoint

    override init(id: Int, keyCode: GCKeyCode, keyName: String, point: CGPoint) {
        self.releasePoint = point
        super.init(id: id, keyCode: keyCode, keyName: keyName, point: point)
        _ = PlayMice.shared.setupThumbstickChangedHandler(name: keyName)
    }

    override func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
            self.releasePoint = point
            PlayMice.shared.draggableHandler[keyName] = self.onMouseMoved
        } else {
            PlayMice.shared.draggableHandler.removeValue(forKey: keyName)
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: id)
        }
    }

    override func invalidate() {
        PlayMice.shared.draggableHandler.removeValue(forKey: keyName)
        PlayMice.shared.stop()
        super.invalidate()
    }

    func onMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        self.releasePoint.x += deltaX
        self.releasePoint.y -= deltaY
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: id)
    }
}

class ConcreteJoystickAction: Action {
    var key: String
    var center: CGPoint
    var position: CGPoint!
    var id: Int
    var sensitivity: CGFloat
    var begun = false

    init(id: Int, data: Joystick) {
        self.id = id
        self.center = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY)
        self.key = data.keyName
        position = center
        self.sensitivity = data.transform.size.absoluteSize / 4
        if PlayMice.shared.setupThumbstickChangedHandler(name: key) {
            PlayMice.shared.joystickHandler[key] = thumbstickUpdate
        } else {
            PlayMice.shared.joystickHandler[key] = mouseUpdate
        }
    }

    func update(_ point: CGPoint) {
        let dis = (center.x - point.x).magnitude + (center.y - point.y).magnitude
        if dis < 16 {
            if begun {
                begun = false
                Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
            }
        } else if !begun {
            begun = true
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: id)
        }
    }

    func thumbstickUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let pos = CGPoint(x: center.x + deltaX * sensitivity,
                          y: center.y - deltaY * sensitivity)
        self.update(pos)
    }

    func mouseUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        position.x += deltaX
        position.y -= deltaY
        self.update(position)
    }

    func invalidate() {
        PlayMice.shared.joystickHandler.removeValue(forKey: key)
    }
}

class JoystickAction: Action {
    let keys: [GCKeyCode]
    let center: CGPoint
    let shift: CGFloat
    var id: Int
    var moving = false

    init(id: Int, keys: [GCKeyCode], center: CGPoint, shift: CGFloat) {
        self.keys = keys
        self.center = center
        self.shift = shift / 2
        self.id = id
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for key in keys {
                let handler = keyboard.button(forKeyCode: key)?.pressedChangedHandler
                keyboard.button(forKeyCode: key)?.pressedChangedHandler = { button, value, pressed in
                    Toucher.touchQueue.async(execute: self.update)
                    if let previous = handler {
                        previous(button, value, pressed)
                    }
                }
            }
        }
    }

    convenience init(id: Int, data: Joystick) {
        self.init(
            id: id,
            keys: [
                GCKeyCode(rawValue: CFIndex(data.upKeyCode)),
                GCKeyCode(rawValue: CFIndex(data.downKeyCode)),
                GCKeyCode(rawValue: CFIndex(data.leftKeyCode)),
                GCKeyCode(rawValue: CFIndex(data.rightKeyCode))
            ],
            center: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY),
            shift: data.transform.size.absoluteSize)
    }

    func invalidate() {
        Toucher.touchcam(point: center, phase: UITouch.Phase.ended, tid: id)
        self.moving = false
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for key in keys {
                keyboard.button(forKeyCode: key)?.pressedChangedHandler = nil
            }
        }
    }

    func update() {
        if mode.visible {
            return
        }
        var touch = center
        var start = center
        if GCKeyboard.pressed(key: keys[0]) {
            touch.y -= shift / 3
        } else if GCKeyboard.pressed(key: keys[1]) {
            touch.y += shift / 3
        }
        if GCKeyboard.pressed(key: keys[2]) {
            touch.x -= shift / 3
        } else if GCKeyboard.pressed(key: keys[3]) {
            touch.x += shift / 3
        }
        if moving {
            if touch.equalTo(center) {
                moving = false
                Toucher.touchcam(point: touch, phase: UITouch.Phase.ended, tid: id)
            } else {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: id)
            }
        } else {
            if !touch.equalTo(center) {
                start.x += (touch.x - start.x) / 8
                start.y += (touch.y - start.y) / 8
                moving = true
                Toucher.touchcam(point: start, phase: UITouch.Phase.began, tid: id)
                Toucher.touchQueue.asyncAfter(deadline: .now() + 0.04) {
                    if self.moving {
                        Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: self.id)
                    } // end if
                } // end closure
            } // end if
        } // end else
    }
}
