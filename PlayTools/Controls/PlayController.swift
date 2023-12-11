//
//  PlayController.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/4/21.
//

import Foundation
import GameController

class PlayController {
    private static var directionPadXValue: Float = 0,
                directionPadYValue: Float = 0,
                thumbstickCursorControl: [String: (((CGFloat, CGFloat) -> Void)?, CGFloat, CGFloat) -> Void]
    = ["Left Thumbstick": ThumbstickCursorControl().update, "Right Thumbstick": ThumbstickCursorControl().update]

    public static func initialize() {
        GCController.current?.extendedGamepad?.valueChangedHandler = handleEvent
    }

    static func handleEditorEvent(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        // This is the index of controller buttons, which is String, not Int
        var alias: String = element.aliases.first!
        if alias == "Direction Pad" {
            guard let dpadElement = element as? GCControllerDirectionPad else {
                Toast.showOver(msg: "cannot map direction pad: element type not recognizable")
                return
            }
            if dpadElement.xAxis.value > 0 {
                alias = dpadElement.right.aliases.first!
            } else if dpadElement.xAxis.value < 0 {
                alias = dpadElement.left.aliases.first!
            }
            if dpadElement.yAxis.value > 0 {
                alias = dpadElement.down.aliases.first!
            } else if dpadElement.yAxis.value < 0 {
                alias = dpadElement.up.aliases.first!
            }
        }
        EditorController.shared.setKey(alias)
    }

    static func handleEvent(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        let name: String = element.aliases.first!
        if let buttonElement = element as? GCControllerButtonInput {
            guard let handlers = PlayInput.buttonHandlers[name] else { return }
//            Toast.showOver(msg: name + ": \(buttonElement.isPressed)")
            for handler in handlers {
                handler(buttonElement.isPressed)
            }
        } else if let dpadElement = element as? GCControllerDirectionPad {
            PlayController.handleDirectionPad(profile, dpadElement)
        } else {
            Toast.showOver(msg: "unrecognised controller element input happens")
        }
    }
    public static func handleDirectionPad(_ profile: GCExtendedGamepad, _ dpad: GCControllerDirectionPad) {
        let name = dpad.aliases.first!
        let xAxis = dpad.xAxis, yAxis = dpad.yAxis
        if name == "Direction Pad" {
            if (xAxis.value > 0) != (directionPadXValue > 0) {
                PlayController.handleEvent(profile, dpad.right)
            }
            if (xAxis.value < 0) != (directionPadXValue < 0) {
                PlayController.handleEvent(profile, dpad.left)
            }
            if (yAxis.value > 0) != (directionPadYValue > 0) {
                PlayController.handleEvent(profile, dpad.up)
            }
            if (yAxis.value < 0) != (directionPadYValue < 0) {
                PlayController.handleEvent(profile, dpad.down)
            }
            directionPadXValue = xAxis.value
            directionPadYValue = yAxis.value
            return
        }
        let deltaX = xAxis.value, deltaY = yAxis.value
        let cgDx = CGFloat(deltaX)
        let cgDy = CGFloat(deltaY)
        thumbstickCursorControl[name]!(
            PlayInput.draggableHandler[name] ?? PlayInput.cameraMoveHandler[name], cgDx * 6, cgDy * 6)
        PlayInput.joystickHandler[name]?(cgDx, cgDy)
    }
}

class ThumbstickCursorControl {
    private var thumbstickVelocity: CGVector = CGVector.zero,
                thumbstickPolling: Bool = false,
                eventHandler: ((CGFloat, CGFloat) -> Void)!

    static private func isVectorSignificant(_ vector: CGVector) -> Bool {
        return vector.dx.magnitude + vector.dy.magnitude > 0.2
    }

    public func update(handler: ((CGFloat, CGFloat) -> Void)?, velocityX: CGFloat, velocityY: CGFloat) {
        guard let hdlr = handler else {
            if thumbstickPolling {
                self.thumbstickVelocity.dx = 0
                self.thumbstickVelocity.dy = 0
            }
            return
        }
        self.eventHandler = hdlr
        self.thumbstickVelocity.dx = velocityX
        self.thumbstickVelocity.dy = velocityY
        if !thumbstickPolling {
            PlayInput.touchQueue.async(execute: self.thumbstickPoll)
            self.thumbstickPolling = true
        }
    }

    private func thumbstickPoll() {
        if !ThumbstickCursorControl.isVectorSignificant(self.thumbstickVelocity) {
            self.thumbstickPolling = false
            return
        }
        self.eventHandler(self.thumbstickVelocity.dx, self.thumbstickVelocity.dy)
        PlayInput.touchQueue.asyncAfter(
            deadline: DispatchTime.now() + 0.017, execute: self.thumbstickPoll)
    }
}
