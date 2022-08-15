//
//  PlayMice.swift
//  PlayTools
//

import Foundation

import GameController
import CoreGraphics

typealias ResponseBlock = @convention(block) (_ event: Any) -> Any?

typealias ResponseBlockBool = @convention(block) (_ event: Any) -> Bool

@objc final public class PlayMice: NSObject {
    
    @objc public static let shared = PlayMice()

    private var camera: CameraControl?

    private static var isInit = false

    private var acceptMouseEvents = !PlaySettings.shared.gamingMode

    public override init() {
        super.init()
        if !PlayMice.isInit {
            setupMouseButton(_up: 2, _down: 4)
            setupMouseButton(_up: 8, _down: 16)
            setupMouseButton(_up: 33554432, _down: 67108864)
            PlayMice.isInit = true
        }
    }

    public var cursorPos: CGPoint {
        var point = CGPoint(x: 0, y: 0)
        if #available(macOS 11, *) {
            point = Dynamic(screen.nsWindow).mouseLocationOutsideOfEventStream.asCGPoint!
        }
        if let rect = (Dynamic(screen.nsWindow).frame.asCGRect) {
            point.x = (point.x / rect.width) * screen.screenRect.width
            point.y = screen.screenRect.height - ((point.y / rect.height) * screen.screenRect.height)
        }
        return point
    }

    public func setup(_ key: [CGFloat]) {
        camera = CameraControl(centerX: key[0].absoluteX, centerY: key[1].absoluteY)
        for mouse in GCMouse.mice() {
            mouse.mouseInput?.mouseMovedHandler = { _, dX, dY in
                if !mode.visible {
                    self.camera?.updated(CGFloat(dX), CGFloat(dY))
                }
            }
        }
    }

    public func stop() {
        for mouse in GCMouse.mice() {
            mouse.mouseInput?.mouseMovedHandler = nil
        }
        camera?.stop()
        camera = nil
        mouseActions = [:]
    }

    func setMiceButtons(_ keyId: Int, action: ButtonAction) -> Bool {
        if (-3 ... -1).contains(keyId) {
            setMiceButton(keyId, action: action)
            return true
        }
        return false
    }

    var mouseActions: [Int: ButtonAction] = [:]

    private func setupMouseButton(_up: Int, _down: Int) {
        Dynamic.NSEvent.addLocalMonitorForEventsMatchingMask(_up, handler: { event in
            if !mode.visible || self.acceptMouseEvents {
                self.mouseActions[_up]?.update(pressed: true)
                if self.acceptMouseEvents {
                    return event
                }
                return nil
            }
            return event
        } as ResponseBlock)
        Dynamic.NSEvent.addLocalMonitorForEventsMatchingMask(_down, handler: { event in
            if !mode.visible || self.acceptMouseEvents {
                self.mouseActions[_up]?.update(pressed: false)
                if self.acceptMouseEvents {
                    return event
                }
                return nil
            }
            return event
        } as ResponseBlock)
    }

    private func setMiceButton(_ keyId: Int, action: ButtonAction) {
        switch keyId {
        case -1: mouseActions[2] = action
        case -2: mouseActions[8] = action
        case -3: mouseActions[33554432] = action
        default:
            mouseActions[2] = action
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
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }

    // if max speed of this touch is high
    var movingFast = false
    // seq number for each move event. Used in closure to determine if this move is the last
    var sequence = 0
    // like sequence but resets when touch begins. Used to calc touch duration
    var counter = 0
    // if should wait before beginning next touch
    var cooldown = false
    // if the touch point had been prevented from lifting off because of moving slow
    var idled = false

    @objc func updated(_ dx: CGFloat, _ dy: CGFloat) {
        if mode.visible || cooldown {
            return
        }
        sequence += 1
        // count touch duration
        counter += 1
        if !isMoving {
            isMoving = true
            movingFast = false
            idled = false
            location = center
            counter = 0
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: 1)
        }
        // if not moving fast, regard the user fine-tuning the camera(e.g. aiming)
        // so hold the touch for longer to avoid cold startup
        if dx.magnitude + dy.magnitude > 4 {
            // if we had mistaken this as player aiming
            if self.idled {
                // since not aiming, re-touch to re-gain control
                self.doLiftOff()
                return
            }
            movingFast = true
        }
        self.location.x += dx * CGFloat(PlaySettings.shared.sensivity)
        self.location.y -= dy * CGFloat(PlaySettings.shared.sensivity)
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: 1)
        let previous = sequence

        delay(0.016) {
            // if no other touch events in the past 0.016 sec
            if previous != self.sequence {
                return
            }
            // and slow touch lasts for sufficient time
            if self.movingFast || self.counter > 64 {
                self.doLiftOff()
            } else {
                self.idled = true
                // idle for at most 4 seconds
                self.delay(4) {
                    if previous != self.sequence {
                        return
                    }
                    self.doLiftOff()
                }
            }
         }

    }

    public func doLiftOff() {
        if !self.isMoving {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: 1)
        self.isMoving = false
        // ending and beginning too frequently leads to the beginning event not recognized
        // so let the beginning event wait some time
        // 0.016 here is safe as long as the 0.016 above works
        delay(0.016) {
            self.cooldown = false
        }
        cooldown = true
    }

    func stop() {
        sequence = 0
        self.doLiftOff()
    }
}
