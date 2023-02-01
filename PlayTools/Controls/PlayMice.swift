//
//  PlayMice.swift
//  PlayTools
//

import Foundation
import GameController

public class PlayMice {

    public static let shared = PlayMice()
    public static let elementName = "Mouse"
    private static var isInit = false

    private var acceptMouseEvents = !PlaySettings.shared.mouseMapping

    public init() {
        if !PlayMice.isInit {
            setupMouseButton(_up: 2, _down: 4)
            setupMouseButton(_up: 8, _down: 16)
            setupMouseButton(_up: 33554432, _down: 67108864)
            if !acceptMouseEvents {
                setupScrollWheelHandler()
            }
            PlayMice.isInit = true
        }
    }

    var fakedMouseTouchPointId: Int?
    var fakedMousePressed: Bool {fakedMouseTouchPointId != nil}
    private var thumbstickVelocity: CGVector = CGVector.zero
    public var draggableHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               cameraMoveHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               cameraScaleHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               joystickHandler: [String: (CGFloat, CGFloat) -> Void] = [:]

    public func cursorPos() -> CGPoint {
        var point = CGPoint(x: 0, y: 0)
        point = AKInterface.shared!.mousePoint
        let rect = AKInterface.shared!.windowFrame
        let viewRect: CGRect = screen.screenRect
        let widthRate = viewRect.width / rect.width
        var rate = viewRect.height / rect.height
        if widthRate > rate {
            // Keep aspect ratio
            rate = widthRate
        }
        // Horizontally in center
        point.x -= (rect.width - viewRect.width / rate)/2
        point.x *= rate
        if screen.fullscreen {
            // Vertically in center
            point.y -= (rect.height - viewRect.height / rate)/2
        }
        point.y *= rate
        point.y = viewRect.height - point.y

        return point
    }

    static private func isVectorSignificant(_ vector: CGVector) -> Bool {
        return vector.dx.magnitude + vector.dy.magnitude > 0.2
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

    public func setupThumbstickChangedHandler(name: String) -> Bool {
        if let thumbstick = GCController.current?.extendedGamepad?.elements[name] as? GCControllerDirectionPad {
            thumbstick.valueChangedHandler = { _, deltaX, deltaY in
                if !PlayMice.isVectorSignificant(self.thumbstickVelocity) {
                    if let closure = self.thumbstickPoll(name) {
                        DispatchQueue.main.async(execute: closure)
                    }
                }
                self.thumbstickVelocity.dx = CGFloat(deltaX * 6)
                self.thumbstickVelocity.dy = CGFloat(deltaY * 6)
//                Toast.showOver(msg: "thumbstick")
                if let joystickUpdate = self.joystickHandler[name] {
                    joystickUpdate(self.thumbstickVelocity.dx, self.thumbstickVelocity.dy)
                }
            }
            return true
        }
        return false
    }

    private func thumbstickPoll(_ name: String) -> (() -> Void)? {
//        DispatchQueue.main.async {
//            Toast.showOver(msg: "polling")
//        }
        let draggableUpdate = self.draggableHandler[name]
        let cameraUpdate = self.cameraMoveHandler[name]
        if  draggableUpdate == nil && cameraUpdate == nil {
            return nil
        }
        return {
            if PlayMice.isVectorSignificant(self.thumbstickVelocity) {
                var captured = false
                if let draggableUpdate = self.draggableHandler[name] {
                    draggableUpdate(self.thumbstickVelocity.dx, self.thumbstickVelocity.dy)
                    captured = true
                }
                if !captured {
                    if let cameraUpdate = self.cameraMoveHandler[name] {
                        cameraUpdate(self.thumbstickVelocity.dx, self.thumbstickVelocity.dy)
                    }
                }
                if let closure = self.thumbstickPoll(name) {
                    DispatchQueue.main.asyncAfter(
                        deadline: DispatchTime.now() + 0.017, execute: closure)
                }
            }
        }
    }

    public func handleFakeMouseMoved(_: GCMouseInput, deltaX: Float, deltaY: Float) {
        if self.fakedMousePressed {
            Toucher.touchcam(point: self.cursorPos(), phase: UITouch.Phase.moved, tid: &fakedMouseTouchPointId)
        }
    }

    public func handleMouseMoved(_: GCMouseInput, deltaX: Float, deltaY: Float) {
        let sensy = CGFloat(PlaySettings.shared.sensitivity)
        let cgDx = CGFloat(deltaX) * sensy,
            cgDy = CGFloat(deltaY) * sensy
        let name = PlayMice.elementName
        if let draggableUpdate = self.draggableHandler[name] {
            draggableUpdate(cgDx, cgDy)
            return
        }
        self.cameraMoveHandler[name]?(cgDx, cgDy)
        self.joystickHandler[name]?(cgDx, cgDy)
    }

    public func stop() {
        mouseActions.keys.forEach { key in
            mouseActions[key] = []
        }
        for mouse in GCMouse.mice() {
            mouse.mouseInput?.mouseMovedHandler = { _, _, _ in}
        }
    }

    func setMiceButtons(_ keyId: Int, action: ButtonAction) -> Bool {
        if (-3 ... -1).contains(keyId) {
            setMiceButton(keyId, action: action)
            return true
        }
        return false
    }

    var mouseActions: [Int: [ButtonAction]] = [2: [], 8: [], 33554432: []]

    private func setupMouseButton(_up: Int, _down: Int) {
        AKInterface.shared!.setupMouseButton(_up, _down, dontIgnore(_:_:_:))
    }

    private func dontIgnore(_ actionIndex: Int, _ state: Bool, _ isEventWindow: Bool) -> Bool {
        if EditorController.shared.editorMode {
            if state {
                if actionIndex == 8 {
                    EditorController.shared.setKey(-2)
                } else if actionIndex == 33554432 {
                    EditorController.shared.setKey(-3)
                }
            }
            return true
        }
        if self.acceptMouseEvents {
            let curPos = self.cursorPos()
            if state {
                if !self.fakedMousePressed
                    // For traffic light buttons when not fullscreen
                    && curPos.y > 0
                    // For traffic light buttons when fullscreen
                    && isEventWindow {
                    Toucher.touchcam(point: curPos,
                                     phase: UITouch.Phase.began,
                                     tid: &fakedMouseTouchPointId)
                    return false
                }
            } else {
                if self.fakedMousePressed {
                    Toucher.touchcam(point: curPos, phase: UITouch.Phase.ended, tid: &fakedMouseTouchPointId)
                    return false
                }
            }
            return true
        }
        if !mode.visible {
            self.mouseActions[actionIndex]!.forEach({ buttonAction in
                buttonAction.update(pressed: state)
            })
            return false
        }
        return true
    }

    private func setMiceButton(_ keyId: Int, action: ButtonAction) {
        switch keyId {
        case -1: mouseActions[2]!.append(action)
        case -2: mouseActions[8]!.append(action)
        case -3: mouseActions[33554432]!.append(action)
        default:
            mouseActions[2]!.append(action)
        }
    }
}

class CameraAction: Action {
    var swipeMove, swipeScale1, swipeScale2: SwipeAction
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
        _ = PlayMice.shared.setupThumbstickChangedHandler(name: key)
        PlayMice.shared.cameraMoveHandler[key] = self.moveUpdated
        PlayMice.shared.cameraScaleHandler[PlayMice.elementName] = self.scaleUpdated
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
    // Event handlers SHOULD be SMALL
    // DO NOT check things like mode.visible in an event handler
    // change the handler itself instead
    func dragUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeMove.move(from: PlayMice.shared.cursorPos, deltaX: deltaX * 4, deltaY: -deltaY * 4)
    }

    func invalidate() {
        PlayMice.shared.cameraMoveHandler.removeValue(forKey: key)
        PlayMice.shared.cameraScaleHandler[PlayMice.elementName] = self.dragUpdated
    }
}

class SwipeAction: Action {
    var location: CGPoint = CGPoint.zero
    var id: Int?
    init() {
        // in rare cases the cooldown reset task is lost by the dispatch queue
        self.cooldown = false
    }

    func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        Toucher.touchQueue.asyncAfter(deadline: when, execute: closure)
    }

    // like sequence but resets when touch begins. Used to calc touch duration
    var counter = 0
    // if should wait before beginning next touch
    var cooldown = false
    // in how many tests has this been identified as stationary
    var stationaryCount = 0
    let stationaryThreshold = 2

    func checkEnded() {
        // if been stationary for enough time
        if self.stationaryCount < self.stationaryThreshold || (self.stationaryCount < 20 - self.counter) {
            self.stationaryCount += 1
            self.delay(0.04, closure: self.checkEnded)
            return
        }
        self.doLiftOff()
     }

    public func move(from: () -> CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        // count touch duration
        counter += 1
        if id == nil {
            if cooldown {
                return
            }
            counter = 0
            location = from()
            Toucher.touchcam(point: location, phase: UITouch.Phase.began, tid: &id)
            delay(0.01, closure: checkEnded)
        }
        if self.counter == 120 {
            self.doLiftOff()
            return
        }
        self.location.x += deltaX
        self.location.y -= deltaY
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: &id)
        stationaryCount = 0
    }

    public func doLiftOff() {
        if id == nil {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: &id)
        // ending and beginning too frequently leads to the beginning event not recognized
        // so let the beginning event wait some time
        // pause for one frame or two
        delay(0.02) {
            self.cooldown = false
        }
        cooldown = true
    }

    func invalidate() {
        // pass
    }
}
