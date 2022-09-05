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
    }

    let key: GCKeyCode
    let keyid: Int
    let point: CGPoint
    var id: Int

    init(id: Int, keyid: Int, key: GCKeyCode, point: CGPoint) {
        self.keyid = keyid
        self.key = key
        self.point = point
        self.id = id
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            if !PlayMice.shared.setMiceButtons(keyid, action: self) {
                keyboard.button(forKeyCode: key)?.pressedChangedHandler = { _, _, pressed in
                    if !mode.visible && !PlayInput.cmdPressed() {
                        self.update(pressed: pressed)
                    }
                }
            }
        }
    }

    convenience init(id: Int, data: Button) {
        self.init(
            id: id,
            keyid: data.keyCode,
            key: GCKeyCode(rawValue: CFIndex(data.keyCode)),
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
    static public var activeButton: DraggableButtonAction?

    var releasePoint: CGPoint

    override init(id: Int, keyid: Int, key: GCKeyCode, point: CGPoint) {
        self.releasePoint = point
        super.init(id: id, keyid: keyid, key: key, point: point)
        if settings.gamingMode {
            PlayMice.shared.setupMouseMovedHandler()
        }
    }

    override func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: id)
            self.releasePoint = point
            DraggableButtonAction.activeButton = self
        } else {
            DraggableButtonAction.activeButton = nil
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: id)
        }
    }

    override func invalidate() {
        DraggableButtonAction.activeButton = nil
        PlayMice.shared.stop()
        super.invalidate()
    }

    func onMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        self.releasePoint.x += deltaX * CGFloat(PlaySettings.shared.sensitivity)
        self.releasePoint.y -= deltaY * CGFloat(PlaySettings.shared.sensitivity)
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: id)
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
                keyboard.button(forKeyCode: key)?.pressedChangedHandler = { _, _, _ in
                    Toucher.touchQueue.async(execute: self.update)
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
    }

    func update() {
        if !mode.visible {
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
                        }
                    }
                }
            }
        }
    }
}
