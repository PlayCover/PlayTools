//
//  PlayMice.swift
//  PlayTools
//

import Foundation
import GameController

public class PlayMice {

    public static let shared = PlayMice()
    public static let elementName = "Mouse"

    public func initialize() {
        setupMouseButton(_up: 2, _down: 4)
        setupMouseButton(_up: 8, _down: 16)
        setupMouseButton(_up: 33554432, _down: 67108864)
        setupScrollWheelHandler()
    }

    var fakedMouseTouchPointId: Int?
    var fakedMousePressed: Bool {fakedMouseTouchPointId != nil}
    private var directionPadXValue: Float = 0,
                directionPadYValue: Float = 0,
                thumbstickCursorControl: [String: (((CGFloat, CGFloat) -> Void)?, CGFloat, CGFloat) -> Void]
    = ["Left Thumbstick": ThumbstickCursorControl().update, "Right Thumbstick": ThumbstickCursorControl().update]
    public var draggableHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               cameraMoveHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               cameraScaleHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               joystickHandler: [String: (CGFloat, CGFloat) -> Void] = [:]

    public func mouseMovementMapped() -> Bool {
        for handler in [draggableHandler, cameraMoveHandler, joystickHandler]
        where handler[PlayMice.elementName] != nil {
            return true
        }
        return false
    }

    public func cursorPos() -> CGPoint? {
        var point = AKInterface.shared!.mousePoint
        let rect = AKInterface.shared!.windowFrame
        if rect.width < 1 || rect.height < 1 {
            return nil
        }
        let viewRect: CGRect = screen.screenRect
        let widthRate = viewRect.width / rect.width
        var rate = viewRect.height / rect.height
        if widthRate > rate {
            // Keep aspect ratio
            rate = widthRate
        }
        if screen.fullscreen {
            // Vertically in center
            point.y -= (rect.height - viewRect.height / rate)/2
        }
        point.y *= rate
        point.y = viewRect.height - point.y
        // For traffic light buttons when not fullscreen
        if point.y < 0 {
            return nil
        }
        // Horizontally in center
        point.x -= (rect.width - viewRect.width / rate)/2
        point.x *= rate
        return point
    }

    public func setupScrollWheelHandler() {
        AKInterface.shared!.setupScrollWheel({deltaX, deltaY in
            if let cameraScale = self.cameraScaleHandler[PlayMice.elementName] {
                cameraScale(deltaX, deltaY)
                let eventConsumed = !mode.visible
                return eventConsumed
            }
            return false
        })
    }

    public func handleControllerDirectionPad(_ profile: GCExtendedGamepad, _ dpad: GCControllerDirectionPad) {
        let name = dpad.aliases.first!
        let xAxis = dpad.xAxis, yAxis = dpad.yAxis
        if name == "Direction Pad" {
            if (xAxis.value > 0) != (directionPadXValue > 0) {
                PlayInput.shared.controllerButtonHandler(profile, dpad.right)
            }
            if (xAxis.value < 0) != (directionPadXValue < 0) {
                PlayInput.shared.controllerButtonHandler(profile, dpad.left)
            }
            if (yAxis.value > 0) != (directionPadYValue > 0) {
                PlayInput.shared.controllerButtonHandler(profile, dpad.up)
            }
            if (yAxis.value < 0) != (directionPadYValue < 0) {
                PlayInput.shared.controllerButtonHandler(profile, dpad.down)
            }
            directionPadXValue = xAxis.value
            directionPadYValue = yAxis.value
            return
        }
        let deltaX = xAxis.value, deltaY = yAxis.value
        let cgDx = CGFloat(deltaX)
        let cgDy = CGFloat(deltaY)
        thumbstickCursorControl[name]!(draggableHandler[name] ?? cameraMoveHandler[name], cgDx * 6, cgDy * 6)
        joystickHandler[name]?(cgDx, cgDy)
    }

    public func handleFakeMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        if self.fakedMousePressed {
            if let pos = self.cursorPos() {
                Toucher.touchcam(point: pos, phase: UITouch.Phase.moved, tid: &fakedMouseTouchPointId)
            }
        }
    }

    public func handleMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        let sensy = CGFloat(PlaySettings.shared.sensitivity * 0.6)
        let cgDx = deltaX * sensy,
            cgDy = -deltaY * sensy
        let name = PlayMice.elementName
        if let draggableUpdate = self.draggableHandler[name] {
            draggableUpdate(cgDx, cgDy)
            return
        }
        self.cameraMoveHandler[name]?(cgDx, cgDy)
        self.joystickHandler[name]?(cgDx, cgDy)
    }

    // TODO: get rid of this shit
    let buttonIndex: [Int: Int] = [2: -1, 8: -2, 33554432: -3]

    private func setupMouseButton(_up: Int, _down: Int) {
        AKInterface.shared!.setupMouseButton(_up, _down, dontIgnore)
    }

    private func dontIgnore(_ actionIndex: Int, _ pressed: Bool) -> Bool {
        if !PlayInput.shouldLockCursor {
            return true
        }
        if EditorController.shared.editorMode {
            if pressed && actionIndex != 2 {
                EditorController.shared.setKey(buttonIndex[actionIndex]!)
            }
            return true
        }
        guard let curPos = self.cursorPos() else { return true }
        PlayInput.touchQueue.async(qos: .userInteractive, execute: {
            if self.fakedMousePressed {
                Toucher.touchcam(point: curPos, phase: UITouch.Phase.ended, tid: &self.fakedMouseTouchPointId)
                return
            }
            if mode.visible && pressed {
                Toucher.touchcam(point: curPos,
                                 phase: UITouch.Phase.began,
                                 tid: &self.fakedMouseTouchPointId)
            } else {
                if let handlers = PlayInput.buttonHandlers[KeyCodeNames.keyCodes[self.buttonIndex[actionIndex]!]!] {
                    for handler in handlers {
                        handler(pressed)
                    }
                }
            }
        })
        return false
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
            DispatchQueue.main.async(execute: self.thumbstickPoll)
            self.thumbstickPolling = true
        }
    }

    private func thumbstickPoll() {
        if !ThumbstickCursorControl.isVectorSignificant(self.thumbstickVelocity) {
            self.thumbstickPolling = false
            return
        }
        self.eventHandler(self.thumbstickVelocity.dx, self.thumbstickVelocity.dy)
        DispatchQueue.main.asyncAfter(
            deadline: DispatchTime.now() + 0.017, execute: self.thumbstickPoll)
    }
}

class CameraAction: Action {
    var swipeMove, swipeScale1, swipeScale2: SwipeAction
    static var swipeDrag = SwipeAction()
    var key: String!
    var center: CGPoint
    var distance1: CGFloat = 100, distance2: CGFloat = 100
    init(data: MouseArea) {
        self.key = data.keyName
        let centerX = data.transform.xCoord.absoluteX
        let centerY = data.transform.yCoord.absoluteY
        center = CGPoint(x: centerX, y: centerY)
        swipeMove = SwipeAction()
        swipeScale1 = SwipeAction()
        swipeScale2 = SwipeAction()
        PlayMice.shared.cameraMoveHandler[key] = self.moveUpdated
        PlayMice.shared.cameraScaleHandler[PlayMice.elementName] = {deltaX, deltaY in
            PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                if mode.visible {
                    CameraAction.dragUpdated(deltaX, deltaY)
                } else {
                    self.scaleUpdated(deltaX, deltaY)
                }
            })
        }
    }
    func moveUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeMove.move(from: {return center}, deltaX: deltaX, deltaY: deltaY)
    }

    func scaleUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let distance = distance1 + distance2
        let moveY = deltaY * (distance / 100.0)
        distance1 += moveY
        distance2 += moveY

        swipeScale1.move(from: {
            self.distance1 = 100
            return CGPoint(x: center.x, y: center.y - 100)
        }, deltaX: 0, deltaY: moveY)

        swipeScale2.move(from: {
            self.distance2 = 100
            return CGPoint(x: center.x, y: center.y + 100)
        }, deltaX: 0, deltaY: -moveY)
    }

    static func dragUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeDrag.move(from: PlayMice.shared.cursorPos, deltaX: deltaX * 4, deltaY: -deltaY * 4)
    }

    func invalidate() {
        PlayMice.shared.cameraMoveHandler.removeValue(forKey: key)
        PlayMice.shared.cameraScaleHandler[PlayMice.elementName] = nil
        swipeMove.invalidate()
        swipeScale1.invalidate()
        swipeScale2.invalidate()
    }
}

class SwipeAction: Action {
    var location: CGPoint = CGPoint.zero
    var id: Int?
    let timer = DispatchSource.makeTimerSource(flags: [], queue: PlayInput.touchQueue)
    init() {
        timer.schedule(deadline: DispatchTime.now() + 1, repeating: 0.1, leeway: DispatchTimeInterval.milliseconds(50))
        timer.setEventHandler(qos: DispatchQoS.background, handler: self.checkEnded)
        timer.activate()
        timer.suspend()
    }

    // Count swipe duration
    var counter = 0
    var lastCounter = 0

    func checkEnded() {
        if self.counter == self.lastCounter {
            if self.counter < 12 {
                counter += 12
            } else {
                timer.suspend()
                self.doLiftOff()
            }
        }
        self.lastCounter = self.counter
     }

    public func move(from: () -> CGPoint?, deltaX: CGFloat, deltaY: CGFloat) {
        if id == nil {
            guard let start = from() else {return}
            location = start
            counter = 0
            Toucher.touchcam(point: location, phase: UITouch.Phase.began, tid: &id)
            timer.resume()
        }
        // count touch duration
        counter += 1
        self.location.x += deltaX
        self.location.y -= deltaY
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: &id)
    }

    public func doLiftOff() {
        if id == nil {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: &id)
    }

    func invalidate() {
        timer.cancel()
        self.doLiftOff()
    }
}
