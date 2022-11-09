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
            PlayMice.isInit = true
        }
    }

    var fakedMousePressed = false
    private var thumbstickVelocity: CGVector = CGVector.zero
    public var draggableHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               cameraHandler: [String: (CGFloat, CGFloat) -> Void] = [:],
               joystickHandler: [String: (CGFloat, CGFloat) -> Void] = [:]

    public var cursorPos: CGPoint {
        var point = CGPoint(x: 0, y: 0)
        if #available(macOS 11, *) {
            point = AKInterface.shared!.mousePoint
        }
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
        let cameraUpdate = self.cameraHandler[name]
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
                    if let cameraUpdate = self.cameraHandler[name] {
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

    public func handleMouseMoved(deltaX: Float, deltaY: Float) {
        if self.acceptMouseEvents {
            if self.fakedMousePressed {
                Toucher.touchcam(point: self.cursorPos, phase: UITouch.Phase.moved, tid: 1)
            }
            return
        }
        if mode.visible {
            return
        }
        let cgDx = CGFloat(deltaX) * CGFloat(PlaySettings.shared.sensitivity),
            cgDy = CGFloat(deltaY) * CGFloat(PlaySettings.shared.sensitivity)
        for name in ["", PlayMice.elementName] {
            if let draggableUpdate = self.draggableHandler[name] {
                draggableUpdate(cgDx, cgDy)
                return
            }
        }
        for name in ["", PlayMice.elementName] {
            if let cameraUpdate = self.cameraHandler[name] {
                cameraUpdate(cgDx, cgDy)
            }
            if let joystickUpdate = self.joystickHandler[name] {
                joystickUpdate(cgDx, cgDy)
            }
        }
    }

    public func stop() {
//        draggableJobs.removeAll()
//        acceleratedJobs.removeAll()
//        movedJobs.removeAll()
        mouseActions.keys.forEach { key in
            mouseActions[key] = []
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
            if state {
                if !self.fakedMousePressed
                    // For traffic light buttons when not fullscreen
                    && self.cursorPos.y > 0
                    // For traffic light buttons when fullscreen
                    && isEventWindow {
                    Toucher.touchcam(point: self.cursorPos,
                                     phase: UITouch.Phase.began,
                                     tid: 1)
                    self.fakedMousePressed = true
                    return false
                }
            } else {
                if self.fakedMousePressed {
                    self.fakedMousePressed = false
                    Toucher.touchcam(point: self.cursorPos, phase: UITouch.Phase.ended, tid: 1)
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
    var center: CGPoint = CGPoint.zero
    var location: CGPoint = CGPoint.zero
    var key: String!
    var id: Int!
    init(centerX: CGFloat = screen.width / 2, centerY: CGFloat = screen.height / 2) {
        self.center = CGPoint(x: centerX, y: centerY)
        // in rare cases the cooldown reset task is lost by the dispatch queue
        self.cooldown = false
    }

    convenience init(id: Int, data: MouseArea) {
        self.init(
            centerX: data.transform.xCoord.absoluteX,
            centerY: data.transform.yCoord.absoluteY)
        self.id = id
        self.key = data.keyName
        _ = PlayMice.shared.setupThumbstickChangedHandler(name: key)
        PlayMice.shared.cameraHandler[key] = self.updated
    }
    var isMoving = false

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

    @objc func checkEnded() {
        // if been stationary for enough time
        if self.stationaryCount < self.stationaryThreshold || (self.stationaryCount < 20 - self.counter) {
            self.stationaryCount += 1
            self.delay(0.04, closure: checkEnded)
            return
        }
        self.doLiftOff()
     }

    @objc func updated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        if mode.visible || cooldown {
            return
        }
        // count touch duration
        counter += 1
        if !isMoving {
            isMoving = true
            location = center
            counter = 0
            stationaryCount = 0
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: id)

            delay(0.01, closure: checkEnded)
        }
        if self.counter == 120 {
            self.doLiftOff()
            return
        }
        self.location.x += deltaX
        self.location.y -= deltaY
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: id)
        stationaryCount = 0
    }

    public func doLiftOff() {
        if !self.isMoving {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: id)
        self.isMoving = false
        // ending and beginning too frequently leads to the beginning event not recognized
        // so let the beginning event wait some time
        // pause for one frame or two
        delay(0.02) {
            self.cooldown = false
        }
        cooldown = true
    }

    func invalidate() {
        PlayMice.shared.cameraHandler.removeValue(forKey: key)
        self.doLiftOff()
    }
}
