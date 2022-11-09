//
//  PlayMice.swift
//  PlayTools
//

import Foundation
import GameController

public class PlayMice {
    public static let shared = PlayMice()

    var camera: CameraControl?

    func setup(_ data: MouseArea) {
        camera = CameraControl(
            centerX: data.transform.xCoord.absoluteX,
            centerY: data.transform.yCoord.absoluteY)
    }

    func initalise() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(CameraControl.updated(_:)),
                                               name: NSNotification.Name("playtools.mouseMoved"),
                                               object: nil)
    }

    public func stop() {
        camera?.stop()
        camera = nil
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

    @objc func updated(_ notification: NSNotification) {
        Toast.showOver(msg: "Mouse Update Called")
        guard let deltaX = notification.userInfo?["dx"] as? CGFloat else { return }
        guard let deltaY = notification.userInfo?["dy"] as? CGFloat else { return }

        if !PlayInput.shared.inputEnabled || cooldown {
            return
        }
        // count touch duration
        counter += 1
        if !isMoving {
            isMoving = true
            location = center
            counter = 0
            stationaryCount = 0
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: 1)

            delay(0.01, closure: checkEnded)
        }
        if self.counter == 120 {
            self.doLiftOff()
            return
        }
        self.location.x += deltaX * CGFloat(PlaySettings.shared.sensitivity)
        self.location.y -= deltaY * CGFloat(PlaySettings.shared.sensitivity)
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: 1)
        if stationaryCount > self.stationaryThreshold {
            self.counter = 0
        }
        stationaryCount = 0
    }

    public func doLiftOff() {
        if !self.isMoving {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: 1)
//        DispatchQueue.main.async {
//            Toast.showOver(msg: "mouse released")
//        }
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
