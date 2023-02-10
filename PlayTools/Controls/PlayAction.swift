//
//  PlayAction.swift
//  PlayTools
//

import Foundation

protocol Action {
    func invalidate()
}

class ButtonAction: Action {
    func invalidate() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id)
    }

    let keyCode: Int
    let keyName: String
    let point: CGPoint
    var id: Int?

    init(keyCode: Int, keyName: String, point: CGPoint) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.point = point
        let code = keyCode
        guard let codeName = KeyCodeNames.keyCodes[code] else {
            Toast.showOver(msg: keyName+"(\(keyCode)) cannot be mapped")
            return
        }
        // TODO: set both key names in draggable button, so as to depracate key code
        PlayInput.registerButton(key: code == KeyCodeNames.defaultCode ? keyName: codeName, handler: self.update)
    }

    convenience init(data: Button) {
        let keyCode = data.keyCode
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

    override init(keyCode: Int, keyName: String, point: CGPoint) {
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
    let keys: [Int]
    let center: CGPoint
    let shift: CGFloat
    var id: Int?
    var moving = false
    private var keyPressed = [Bool](repeating: false, count: 4)

    init(keys: [Int], center: CGPoint, shift: CGFloat) {
        self.keys = keys
        self.center = center
        self.shift = shift / 2
        for index in 0..<keys.count {
            let key = keys[index]
            PlayInput.registerButton(key: KeyCodeNames.keyCodes[key]!,
                                     handler: self.getPressedHandler(index: index))
        }
    }

    convenience init(data: Joystick) {
        self.init(
            keys: [
                data.upKeyCode,
                data.downKeyCode,
                data.leftKeyCode,
                data.rightKeyCode
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

    func getPressedHandler(index: Int) -> (Bool) -> Void {
        return { pressed in
            self.keyPressed[index] = pressed
            self.update()
        }
    }

    func update() {
        var touch = center
        if keyPressed[0] {
            touch.y -= shift / 2
        } else if keyPressed[1] {
            touch.y += shift / 2
        }
        if keyPressed[2] {
            touch.x -= shift / 2
        } else if keyPressed[3] {
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
