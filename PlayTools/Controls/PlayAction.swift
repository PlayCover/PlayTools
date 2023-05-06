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
        let codeName = KeyCodeNames.keyCodes[code] ?? "Btn"
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
            PlayInput.draggableHandler[keyName] = self.onMouseMoved
            AKInterface.shared!.hideCursor()
        } else {
            PlayInput.draggableHandler.removeValue(forKey: keyName)
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: &id)
            AKInterface.shared!.unhideCursor()
        }
    }

    override func invalidate() {
        PlayInput.draggableHandler.removeValue(forKey: keyName)
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
            PlayInput.joystickHandler[key] = self.mouseUpdate
        } else {
            PlayInput.joystickHandler[key] = self.thumbstickUpdate
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
        PlayInput.joystickHandler.removeValue(forKey: key)
    }
}

class JoystickAction: Action {
    let keys: [Int]
    let center: CGPoint
    var touch: CGPoint
    let shift: CGFloat
    var id: Int?
    private var keyPressed = [Bool](repeating: false, count: 4)
    init(keys: [Int], center: CGPoint, shift: CGFloat) {
        self.keys = keys
        self.center = center
        self.touch = center
        self.shift = shift / 4
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
    }

    func getPressedHandler(index: Int) -> (Bool) -> Void {
        // if the size of joystick is large, set control type to free, otherwise fixed.
        // this is a temporary method. ideally should give the user an option.
        if shift < 200 {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFixed()
            }
        } else {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFree()
            }
        }
    }

    func updateTouch(index: Int, pressed: Bool) {
        self.keyPressed[index] = pressed
        let isPlus = index & 1 != 0
        let realShift = isPlus ? shift : -shift
        if index > 1 {
            if pressed {
                touch.x = center.x + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.x = center.x - realShift
            } else {
                touch.x = center.x
            }
        } else {
            if pressed {
                touch.y = center.y + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.y = center.y - realShift
            } else {
                touch.y = center.y
            }
        }
    }

    func atCenter() -> Bool {
        return (center.x - touch.x).magnitude + (center.y - touch.y).magnitude < 8
    }

    func handleCommon(_ begin: () -> Void) {
        let moving = id != nil
        if atCenter() {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.ended, tid: &id)
            }
        } else {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: &id)
            } else {
                begin()
            }
        }
    }

    func handleFree() {
        handleCommon {
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: &id)
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04, qos: .userInitiated) {
                if self.id == nil {
                    return
                }
                Toucher.touchcam(point: self.touch, phase: UITouch.Phase.moved, tid: &self.id)
            } // end closure
        }
    }

    func handleFixed() {
        handleCommon {
            Toucher.touchcam(point: self.touch, phase: UITouch.Phase.began, tid: &id)
        }
    }
}
