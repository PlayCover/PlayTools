//
//  PlayMice.swift
//  PlayTools
//

import Foundation

public class PlayMice: Action {

    public static let shared = PlayMice()
    public static let elementName = "Mouse"

    public func initialize() {
        setupLeftButton()
        setupMouseButton(right: true)
        setupMouseButton(right: false)
        AKInterface.shared!.setupMouseMoved(mouseMoved: {deltaX, deltaY in
            // this closure's return value only takes effect when any mouse button pressed
            if !mode.keyboardMapped {
                return false
            }
            PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                self.handleMouseMoved(deltaX: deltaX, deltaY: deltaY)
            })
            return true
        })
        AKInterface.shared!.setupScrollWheel({deltaX, deltaY in
            if let cameraScale = PlayInput.cameraScaleHandler[PlayMice.elementName] {
                cameraScale(deltaX, deltaY)
                let eventConsumed = !mode.visible
                return eventConsumed
            }
            return false
        })
    }

    var fakedMouseTouchPointId: Int?
    var fakedMousePressed: Bool {fakedMouseTouchPointId != nil}

    public func mouseMovementMapped() -> Bool {
        // this is called from `parseKeymap` to set `shouldLockCursor`'s value
        for handler in [PlayInput.cameraMoveHandler, PlayInput.joystickHandler]
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

    public func handleMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        let sensy = CGFloat(PlaySettings.shared.sensitivity * 0.6)
        let cgDx = deltaX * sensy,
            cgDy = -deltaY * sensy
        let name = PlayMice.elementName
        if let draggableUpdate = PlayInput.draggableHandler[name] {
            draggableUpdate(cgDx, cgDy)
        } else if mode.visible {
            if self.fakedMousePressed {
                if let pos = self.cursorPos() {
                    Toucher.touchcam(point: pos, phase: UITouch.Phase.moved, tid: &fakedMouseTouchPointId)
                }
            }
        } else {
            PlayInput.cameraMoveHandler[name]?(cgDx, cgDy)
            PlayInput.joystickHandler[name]?(cgDx, cgDy)
        }
    }

    private func setupMouseButton(right: Bool) {
        let keyCode = right ? -2 : -3
        guard let keyName = KeyCodeNames.keyCodes[keyCode] else {
            Toast.showHint(title: "Failed initializing \(right ? "right" : "other") mouse button input")
            return
        }
        AKInterface.shared!.setupMouseButton(left: false, right: right) {pressed in
            if mode.keyboardMapped { // if mapping
                if let handlers = PlayInput.buttonHandlers[keyName] {
                    PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                        for handler in handlers {
                            handler(pressed)
                        }
                    })
                    // if mapped to any button, consumed and dispatch
                    return false
                }
                // if not mapped, transpass to app
                return true
            } else if EditorController.shared.editorMode { // if editor is open, consumed and set button
                if pressed {
                    // asynced to return quickly. this branch contains UI operation so main queue.
                    // main queue is fine. should not be slower than keyboard
                    DispatchQueue.main.async(qos: .userInteractive, execute: {
                        EditorController.shared.setKey(keyCode)
                        Toucher.writeLog(logMessage: "mouse button editor set")
                    })
                }
                return false
            } else { // if typing, transpass event to app
                Toucher.writeLog(logMessage: "mouse button pressed? \(pressed)")
                return true
            }
        }
    }
    // using high priority event handlers to prevent lag and stutter in demanding games
    // but no free lunch. high priority handlers cannot execute for too long
    // exceeding the time limit causes even more lag
    private func setupLeftButton() {
        AKInterface.shared!.setupMouseButton(left: true, right: false) {pressed in
            if !mode.keyboardMapped {
                Toucher.writeLog(logMessage: "left button pressed? \(pressed)")
                return true
            }
            guard let curPos = self.cursorPos() else { return true }
            PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                // considering cases where cursor becomes hidden while holding left button
                if self.fakedMousePressed {
                    Toucher.touchcam(point: curPos, phase: UITouch.Phase.ended, tid: &self.fakedMouseTouchPointId)
                    return
                }
                if mode.visible && pressed {
                    Toucher.touchcam(point: curPos,
                                     phase: UITouch.Phase.began,
                                     tid: &self.fakedMouseTouchPointId)
                    return
                }
                // considering cases where cursor becomes visible while holding left button
                if let handlers = PlayInput.buttonHandlers["LMB"] {
                    for handler in handlers {
                        handler(pressed)
                    }
                    return
                }
            })
            return false
        }
    }
    // For all other actions, this is a destructor. should release held resources.
    func invalidate() {
        Toucher.touchcam(point: self.cursorPos() ?? CGPoint(x: 10, y: 10),
                         phase: UITouch.Phase.ended, tid: &self.fakedMouseTouchPointId)
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
        PlayInput.cameraMoveHandler[key] = self.moveUpdated
        PlayInput.cameraScaleHandler[PlayMice.elementName] = {deltaX, deltaY in
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
        PlayInput.cameraMoveHandler.removeValue(forKey: key)
        // when noKMOnInput is false, swipe/pan gesture handler would be invalidated when keymapping disabled.
        // as it's just a temporary toggle, not fixing it.
        // but should remove that toggle as long as new feature considered stable.
        PlayInput.cameraScaleHandler[PlayMice.elementName] = nil
        swipeMove.invalidate()
        swipeScale1.invalidate()
        swipeScale2.invalidate()
    }
}

class SwipeAction: Action {
    var location: CGPoint = CGPoint.zero
    private var id: Int?
    let timer = DispatchSource.makeTimerSource(flags: [], queue: PlayInput.touchQueue)
    init() {
        timer.schedule(deadline: DispatchTime.now() + 1, repeating: 0.1, leeway: DispatchTimeInterval.milliseconds(50))
        timer.setEventHandler(qos: .userInteractive, handler: self.checkEnded)
        timer.activate()
        timer.suspend()
    }

    func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        PlayInput.touchQueue.asyncAfter(deadline: when, execute: closure)
    }
    // Count swipe duration
    var counter = 0
    // if should wait before beginning next touch
    var cooldown = false
    var lastCounter = 0

    func checkEnded() {
        if self.counter == self.lastCounter {
            if self.counter < 4 {
                counter += 1
            } else {
                timer.suspend()
                self.doLiftOff()
            }
        }
        self.lastCounter = self.counter
     }

    public func move(from: () -> CGPoint?, deltaX: CGFloat, deltaY: CGFloat) {
        if id == nil {
            if cooldown {
                return
            }
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
        delay(0.02) {
            self.cooldown = false
        }
        cooldown = true
    }

    func invalidate() {
        timer.cancel()
        self.doLiftOff()
    }
}
