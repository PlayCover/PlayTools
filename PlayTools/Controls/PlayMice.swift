//
//  PlayMice.swift
//  PlayTools
//

import Foundation
import GameController

public class PlayMice {

    public static let shared = PlayMice()
    private static var isInit = false

    private var camera: CameraControl?
    private var acceptMouseEvents = !PlaySettings.shared.mouseMapping

    public init() {
        if !PlayMice.isInit {
            setupMouseButton(_up: 2, _down: 4)
            setupMouseButton(_up: 8, _down: 16)
            setupMouseButton(_up: 33554432, _down: 67108864)
            PlayMice.isInit = true
            if acceptMouseEvents {
                setupMouseMovedHandler()
            }
        }
    }

    var fakedMousePressed = false

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

    func setup(_ data: MouseArea) {
        camera = CameraControl(
            centerX: data.transform.xCoord.absoluteX,
            centerY: data.transform.yCoord.absoluteY)
        setupMouseMovedHandler()
    }

    public func setupMouseMovedHandler() {
        for mouse in GCMouse.mice() {
            mouse.mouseInput?.mouseMovedHandler = { _, deltaX, deltaY in
                if !mode.visible {
                    if let draggableButton = DraggableButtonAction.activeButton {
                        draggableButton.onMouseMoved(deltaX: CGFloat(deltaX), deltaY: CGFloat(deltaY))
                    } else {
                        self.camera?.updated(CGFloat(deltaX), CGFloat(deltaY))
                    }
                    if self.acceptMouseEvents && self.fakedMousePressed {
                        Toucher.touchcam(point: self.cursorPos, phase: UITouch.Phase.moved, tid: 1)
                    }
                }
//                Toast.showOver(msg: "\(self.cursorPos)")
            }
        }
    }

    public func stop() {
//        for mouse in GCMouse.mice() {
//            mouse.mouseInput?.mouseMovedHandler = nil
//        }
        camera?.stop()
        camera = nil
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
                    EditorController.shared.setKeyCode(-2)
                } else if actionIndex == 33554432 {
                    EditorController.shared.setKeyCode(-3)
                }
                return true
            } else {
                return true
            }
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
                return true
            } else {
                if self.fakedMousePressed {
                    self.fakedMousePressed = false
                    Toucher.touchcam(point: self.cursorPos, phase: UITouch.Phase.ended, tid: 1)
                    return false
                }
                return true
            }
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

final class CameraControl {

    var center: CGPoint = CGPoint.zero
    var location: CGPoint = CGPoint.zero

    init(centerX: CGFloat = screen.width / 2, centerY: CGFloat = screen.height / 2) {
        self.center = CGPoint(x: centerX, y: centerY)
        // in rare cases the cooldown reset task is lost by the dispatch queue
        self.cooldown = false
    }

    var isMoving = false

    func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        Toucher.touchQueue.asyncAfter(deadline: when, execute: closure)
    }

    // if max speed of this touch is high
    var movingFast = false
    // like sequence but resets when touch begins. Used to calc touch duration
    var counter = 0
    // if should wait before beginning next touch
    var cooldown = false
    // if the touch point had been prevented from lifting off because of moving slow
    var idled = false
    // in how many tests has this been identified as stationary
    var stationaryCount = 0
    let stationaryThreshold = 2

    @objc func checkEnded() {
        // if been stationary for enough time
        if self.stationaryCount < self.stationaryThreshold {
            self.stationaryCount += 1
            self.delay(0.1, closure: checkEnded)
            return
        }
        // and slow touch lasts for sufficient time
        if self.movingFast || self.counter > 64 {
            self.doLiftOff()
        } else {
            self.idled = true
            // idle for at most 4 seconds
            self.delay(4) {
                if self.stationaryCount < self.stationaryThreshold {
                    self.stationaryCount += 1
                    self.delay(0.1, closure: self.checkEnded)
                    return
                }
                self.doLiftOff()
            }
        }
     }

    @objc func updated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        if mode.visible || cooldown {
            return
        }
        // count touch duration
        counter += 1
        if !isMoving {
            isMoving = true
            movingFast = false
            idled = false
            location = center
            counter = 0
            stationaryCount = 0
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: 1)

            delay(0.1, closure: checkEnded)
        }
        // if not moving fast, regard the user fine-tuning the camera(e.g. aiming)
        // so hold the touch for longer to avoid cold startup
        if deltaX.magnitude + deltaY.magnitude > 12 {
            // if we had mistaken this as player aiming
            if self.idled {
//                Toast.showOver(msg: "idled")
                // since not aiming, re-touch to re-gain control
                self.doLiftOff()
                return
            }
            movingFast = true
        }
        self.location.x += deltaX * CGFloat(PlaySettings.shared.sensitivity)
        self.location.y -= deltaY * CGFloat(PlaySettings.shared.sensitivity)
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: 1)
        stationaryCount = 0
    }

    public func doLiftOff() {
        if !self.isMoving {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: 1)
        self.isMoving = false
        // ending and beginning too frequently leads to the beginning event not recognized
        // so let the beginning event wait some time
        // pause for one frame or two
        delay(0.02) {
            self.cooldown = false
        }
        cooldown = true
    }

    func stop() {
        self.doLiftOff()
    }
}
