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
        Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id)
    }

    let keyCode: GCKeyCode
    let keyName: String
    let point: CGPoint
    var id: Int?

    init(keyCode: GCKeyCode, keyName: String, point: CGPoint) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.point = point
        let code = keyCode.rawValue
        // TODO: set both key names in draggable button, so as to depracate key code
        PlayInput.registerButton(key: code == KeyCodeNames.defaultCode ? keyName: KeyCodeNames.keyCodes[code]!,
                                 handler: self.update)
    }

    convenience init(data: Button) {
        let keyCode = GCKeyCode(rawValue: data.keyCode)
        self.init(
            keyCode: keyCode,
            keyName: data.keyName,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY))
    }

    func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id)
        }
    }
}

class DraggableButtonAction: ButtonAction {
    var releasePoint: CGPoint

    override init(keyCode: GCKeyCode, keyName: String, point: CGPoint) {
        self.releasePoint = point
        super.init(keyCode: keyCode, keyName: keyName, point: point)
    }

    override func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id)
            self.releasePoint = point
            PlayMice.shared.draggableHandler[keyName] = self.onMouseMoved
        } else {
            PlayMice.shared.draggableHandler.removeValue(forKey: keyName)
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: &id)
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
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: &id)
    }
}

class ContinuousJoystickAction: Action {
    var key: String
    var center: CGPoint
    var position: CGPoint!
    private var id: Int?
    var sensitivity: CGFloat
    var begun = false

    init(data: Joystick) {
        self.center = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY)
        self.key = data.keyName
        position = center
        self.sensitivity = data.transform.size.absoluteSize / 4
        if key == PlayMice.elementName {
            PlayMice.shared.joystickHandler[key] = self.mouseUpdate
        } else {
            PlayMice.shared.joystickHandler[key] = self.thumbstickUpdate
        }
    }

    func update(_ point: CGPoint) {
        let dis = (center.x - point.x).magnitude + (center.y - point.y).magnitude
        if dis < 16 {
            if begun {
                begun = false
                Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id)
            }
        } else if !begun {
            begun = true
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &id)
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
    var id: Int?
    var moving = false

    init(keys: [GCKeyCode], center: CGPoint, shift: CGFloat) {
        self.keys = keys
        self.center = center
        self.shift = shift / 2
        for key in keys {
            PlayInput.registerButton(key: KeyCodeNames.keyCodes[key.rawValue]!, handler: self.update)
        }
    }

    convenience init(data: Joystick) {
        self.init(
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
        Toucher.touchcam(point: center, phase: UITouch.Phase.ended, tid: &id)
        self.moving = false
    }

    func update(_: Bool) {
        var touch = center
        if GCKeyboard.pressed(key: keys[0]) {
            touch.y -= shift / 2
        } else if GCKeyboard.pressed(key: keys[1]) {
            touch.y += shift / 2
        }
        if GCKeyboard.pressed(key: keys[2]) {
            touch.x -= shift / 2
        } else if GCKeyboard.pressed(key: keys[3]) {
            touch.x += shift / 2
        }
        if moving {
            if touch.equalTo(center) {
                moving = false
                Toucher.touchcam(point: touch, phase: UITouch.Phase.ended, tid: &id)
            } else {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: &id)
            }
        } else {
            if !touch.equalTo(center) {
                moving = true
                Toucher.touchcam(point: touch, phase: UITouch.Phase.began, tid: &id)
            } // end if
        } // end else
    }
}
