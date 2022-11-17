//
//  PlayAction.swift
//  PlayTools
//

import Foundation
import GameController

class ActionBase {
    var point: CGPoint
    var id: Int

    init(point: CGPoint, id: Int) {
        self.point = point
        self.id = id
    }
}

class MouseButtonAction: ActionBase {
    convenience init(id: Int, data: Button) {
        self.init(
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY),
            id: id)
    }

    func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
        }
    }
}

class ButtonAction: ActionBase {
    let keyCode: GCKeyCode
    let keyName: String

    init(keyCode: GCKeyCode, keyName: String, point: CGPoint, id: Int) {
        self.keyCode = keyCode
        self.keyName = keyName
        super.init(point: point, id: id)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(update(_:)),
                                               name: NSNotification.Name("playtools.\(keyCode.rawValue)"),
                                               object: nil)
    }

    convenience init(id: Int, data: Button) {
        self.init(
            keyCode: GCKeyCode(rawValue: data.keyCode),
            keyName: data.keyName,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY),
            id: id)
    }

    @objc func update(_ notification: NSNotification) {
        guard let pressed = notification.userInfo?["pressed"] as? Bool else { return }
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
        }
    }
}

class DraggableButtonAction: ButtonAction {
    static public var activeButton: DraggableButtonAction?

    var releasePoint: CGPoint

    override init(keyCode: GCKeyCode, keyName: String, point: CGPoint, id: Int) {
        self.releasePoint = point
        super.init(keyCode: keyCode, keyName: keyName, point: point, id: id)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(update(_:)),
                                               name: NSNotification.Name("playtools.\(keyCode.rawValue)"),
                                               object: nil)
    }

    @objc override func update(_ notification: NSNotification) {
        guard let pressed = notification.userInfo?["pressed"] as? Bool else { return }
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
            self.releasePoint = point
            DraggableButtonAction.activeButton = self
        } else {
            DraggableButtonAction.activeButton = nil
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: id)
        }
    }

    func onMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        self.releasePoint.x += deltaX * CGFloat(PlaySettings.shared.sensitivity)
        self.releasePoint.y -= deltaY * CGFloat(PlaySettings.shared.sensitivity)
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: id)
    }
}

class JoystickAction: ActionBase {
    let keys: [GCKeyCode]
    let center: CGPoint
    let shift: CGFloat
    var moving = false
    var isPressed: [Bool] = [false, false, false, false]

    init(id: Int, keys: [GCKeyCode], center: CGPoint, shift: CGFloat) {
        self.keys = keys
        self.center = center
        self.shift = shift / 2
        super.init(point: center, id: id)
        for key in keys {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(update(_:)),
                                                   name: NSNotification.Name("playtools.\(key.rawValue)"),
                                                   object: nil)
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

    @objc func update(_ notification: NSNotification) {
        guard let pressed = notification.userInfo?["pressed"] as? Bool else { return }
        guard let keyCode = notification.userInfo?["keyCode"] as? GCKeyCode else { return }
        guard let index = keys.firstIndex(of: keyCode) else { return }
        isPressed[index] = pressed
        updateStick()
    }

    func updateStick() {
        var touch = center
        var start = center
        if isPressed[0] {
            touch.y -= shift / 3
        } else if isPressed[1] {
            touch.y += shift / 3
        }
        if isPressed[2] {
            touch.x -= shift / 3
        } else if isPressed[3] {
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
                    }
                }
            }
        }
    }
}
