//
//  PlayAction.swift
//  PlayTools
//

import Foundation
import GameController

protocol Action {
    func initGCHandlers()
    func invalidate()
}

class ButtonAction: Action {
    let key: GCKeyCode
    let point: CGPoint
    var id: Int

    func initGCHandlers() {
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.button(forKeyCode: key)?.pressedChangedHandler = { _, _, pressed in
                self.update(pressed: pressed)
            }
        }
    }

    func invalidate() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: id)
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.button(forKeyCode: key)?.pressedChangedHandler = nil
        }
    }

    init(id: Int, key: GCKeyCode, point: CGPoint) {
        self.key = key
        self.point = point
        self.id = id
    }

    convenience init(id: Int, data: Button) {
        self.init(
            id: id,
            key: GCKeyCode(rawValue: data.keyCode),
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

class JoystickAction: Action {
    let keys: [GCKeyCode]
    let center: CGPoint
    var id: Int
    var size: CGFloat

    var direction: CGPoint = .zero
    var moving = false

    func initGCHandlers() {
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            keyboard.button(forKeyCode: keys[0])?.pressedChangedHandler = { _, _, pressed in
                self.direction.y = pressed ? 1 : 0
                self.update()
            }
            keyboard.button(forKeyCode: keys[1])?.pressedChangedHandler = { _, _, pressed in
                self.direction.y = pressed ? -1 : 0
                self.update()
            }
            keyboard.button(forKeyCode: keys[2])?.pressedChangedHandler = { _, _, pressed in
                self.direction.x = pressed ? -1 : 0
                self.update()
            }
            keyboard.button(forKeyCode: keys[3])?.pressedChangedHandler = { _, _, pressed in
                self.direction.x = pressed ? 1 : 0
                self.update()
            }
        }
    }

    func invalidate() {
        Toucher.touchcam(point: center, phase: UITouch.Phase.ended, tid: id)
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            for key in keys {
                keyboard.button(forKeyCode: key)?.pressedChangedHandler = nil
            }
        }
    }

    init(id: Int, keys: [GCKeyCode], center: CGPoint, size: CGFloat) {
        self.keys = keys
        self.center = center
        self.id = id
        self.size = size
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
            size: data.transform.size)
    }

    func update() {
        var touch = center
        var start = center
        let scaledDirection = CGPoint(x: direction.x * size, y: direction.y * size)
        touch.x += scaledDirection.x
        touch.y += scaledDirection.y

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
