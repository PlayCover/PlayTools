//
//  TouchscreenControllerEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import GameController

// Controller events handler when keymap is on

public class TouchscreenControllerEventAdapter: ControllerEventAdapter {

    private var directionPadXValue: Float = 0,
                directionPadYValue: Float = 0
    static private var thumbstickCursorControl: [String: ThumbstickCursorControl] = [:]

    public func handleValueChanged(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        let name: String = element.aliases.first!
        if let buttonElement = element as? GCControllerButtonInput {
            if element === profile.rightThumbstickButton {
                if buttonElement.isPressed {
                    if !VirtualCursorController.shared.isActive {
                        TouchscreenControllerEventAdapter.stopThumbstickMotion(named: "Right Thumbstick")
                    }
                    VirtualCursorController.shared.toggle()
                }
                return
            }
            if VirtualCursorController.shared.isActive {
                if element === profile.leftTrigger {
                    VirtualCursorController.shared.handleTrigger(pressed: buttonElement.isPressed)
                    return
                }
                if name == "Direction Pad Up" || name == "Direction Pad Down" ||
                    name == "Direction Pad Left" || name == "Direction Pad Right" {
                    VirtualCursorController.shared.handleDirectionalDrag(key: name,
                                                                          pressed: buttonElement.isPressed)
                    return
                }
            }
            _ = ActionDispatcher.dispatch(key: name, pressed: buttonElement.isPressed)
        } else if let dpadElement = element as? GCControllerDirectionPad {
            handleDirectionPad(profile, dpadElement)
        } else {
            Toast.showOver(msg: "unrecognised controller element input happens")
        }
    }

    private func handleDirectionPad(_ profile: GCExtendedGamepad, _ dpad: GCControllerDirectionPad) {
        let name = dpad.aliases.first!
        let xAxis = dpad.xAxis, yAxis = dpad.yAxis
        if name == "Direction Pad" {
            if (xAxis.value > 0) != (directionPadXValue > 0) {
                handleValueChanged(profile, dpad.right)
            }
            if (xAxis.value < 0) != (directionPadXValue < 0) {
                handleValueChanged(profile, dpad.left)
            }
            if (yAxis.value > 0) != (directionPadYValue > 0) {
                handleValueChanged(profile, dpad.up)
            }
            if (yAxis.value < 0) != (directionPadYValue < 0) {
                handleValueChanged(profile, dpad.down)
            }
            directionPadXValue = xAxis.value
            directionPadYValue = yAxis.value
            return
        }
        let deltaX = xAxis.value, deltaY = yAxis.value
        let cgDx = CGFloat(deltaX)
        let cgDy = CGFloat(deltaY)
        if name == "Right Thumbstick", VirtualCursorController.shared.isActive {
            VirtualCursorController.shared.update(velocityX: cgDx, velocityY: cgDy)
            return
        }
        let dispatchType = ActionDispatcher.getDispatchPriority(key: name)
        if dispatchType == nil {
            return
        } else if dispatchType == .DEFAULT {
            if name == "Right Thumbstick" {
                _ = ActionDispatcher.dispatch(key: name,
                                              valueX: acceleratedViewAxis(cgDx),
                                              valueY: acceleratedViewAxis(cgDy))
            } else {
                _ = ActionDispatcher.dispatch(key: name, valueX: cgDx, valueY: cgDy)
            }
        } else {
            if TouchscreenControllerEventAdapter.thumbstickCursorControl[name] == nil {
                TouchscreenControllerEventAdapter.thumbstickCursorControl[name] = ThumbstickCursorControl(name)
            }
            TouchscreenControllerEventAdapter.thumbstickCursorControl[name]!.update(velocityX: cgDx, velocityY: cgDy)
        }
    }

    private func acceleratedViewAxis(_ value: CGFloat) -> CGFloat {
        let magnitude = pow(abs(value), 0.75) * 1.35
        return value < 0 ? -magnitude : magnitude
    }

    private static func stopThumbstickMotion(named key: String) {
        if let control = thumbstickCursorControl[key] {
            control.stop()
        } else {
            _ = ActionDispatcher.dispatch(key: key, valueX: 0, valueY: 0)
        }
    }

}

class ThumbstickCursorControl {
    private var thumbstickVelocity: CGVector = CGVector.zero,
                thumbstickPolling: Bool = false,
                key: String

    init(_ key: String) {
        self.key = key
    }

    static private func isVectorSignificant(_ vector: CGVector) -> Bool {
        return vector.dx.magnitude + vector.dy.magnitude > 0.2
    }

    public func update(velocityX: CGFloat, velocityY: CGFloat) {
        self.thumbstickVelocity.dx = velocityX
        self.thumbstickVelocity.dy = velocityY
        if !thumbstickPolling {
            PlayInput.touchQueue.async(execute: self.thumbstickPoll)
            self.thumbstickPolling = true
        }
    }

    public func stop() {
        thumbstickVelocity = .zero
        _ = ActionDispatcher.dispatch(key: key, valueX: 0, valueY: 0)
    }

    private func thumbstickPoll() {
        if !ThumbstickCursorControl.isVectorSignificant(self.thumbstickVelocity) {
            _ = ActionDispatcher.dispatch(key: key, valueX: 0, valueY: 0)
            self.thumbstickPolling = false
            return
        }
        let cameraMapping = ActionDispatcher.getDispatchPriority(key: key) == .CAMERA
        let multiplier: CGFloat = cameraMapping ? 3.8 : 6
        _ = ActionDispatcher.dispatch(key: key,
                                      valueX: thumbstickVelocity.dx * multiplier,
                                      valueY: thumbstickVelocity.dy * multiplier)
        PlayInput.touchQueue.asyncAfter(
            deadline: DispatchTime.now() + (cameraMapping ? 1.0 / 165.0 : 0.017),
            execute: self.thumbstickPoll)
    }
}
