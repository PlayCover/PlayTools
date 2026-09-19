//
//  VirtualCursorController.swift
//  PlayTools
//

import Foundation
import UIKit

final class VirtualCursorController {
    static let shared = VirtualCursorController()

    private let cursorView = VirtualCursorView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
    private var position = CGPoint.zero
    private var velocity = CGVector.zero
    private var polling = false
    private var previousPollTime: CFTimeInterval?
    private var touchId: Int?
    private var directionalTouchId: Int?
    private var directionalTouchPosition = CGPoint.zero
    private var directionalKeys = Set<String>()
    private var directionalPolling = false
    private var visible = false
    private(set) var isActive = false
    private var triggerPressed = false
    private var pendingDrag: DispatchWorkItem?

    private let innerDeadZone: CGFloat = 0.15
    private let outerDeadZone: CGFloat = 0.05
    private let maximumSpeed: CGFloat = 1_100
    private let pollingInterval = 1.0 / 60.0
    private let dragActivationDelay = 0.22
    private let tapDuration = 0.07

    private init() {}

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate()
        }
    }

    private func activate() {
        isActive = true
        visible = true
        if position == .zero {
            position = CGPoint(x: screen.width / 2, y: screen.height / 2)
        }
        let currentPosition = position
        DispatchQueue.main.async {
            self.attachIfNeeded()
            self.cursorView.center = currentPosition
            self.cursorView.isHidden = false
        }
    }

    func update(velocityX: CGFloat, velocityY: CGFloat) {
        PlayInput.touchQueue.async {
            self.velocity = CGVector(dx: velocityX, dy: -velocityY)
            if !self.polling {
                self.polling = true
                self.poll()
            }
        }
    }

    func handleTrigger(pressed: Bool) {
        guard pressed != triggerPressed else { return }
        triggerPressed = pressed

        if pressed {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isActive, self.triggerPressed else { return }
                self.pendingDrag = nil
                Toucher.touchcam(point: self.position, phase: .began, tid: &self.touchId,
                                 actionName: "VirtualCursor", keyName: "Left Trigger")
            }
            pendingDrag = workItem
            PlayInput.touchQueue.asyncAfter(deadline: .now() + dragActivationDelay,
                                            execute: workItem)
        } else if let pendingDrag {
            pendingDrag.cancel()
            self.pendingDrag = nil
            performTap()
        } else if touchId != nil {
            Toucher.touchcam(point: position, phase: .ended, tid: &touchId,
                             actionName: "VirtualCursor", keyName: "Left Trigger")
        }
    }

    private func performTap() {
        Toucher.touchcam(point: position, phase: .began, tid: &touchId,
                         actionName: "VirtualCursor", keyName: "Left Trigger")
        PlayInput.touchQueue.asyncAfter(deadline: .now() + tapDuration) {
            Toucher.touchcam(point: self.position, phase: .ended, tid: &self.touchId,
                             actionName: "VirtualCursor", keyName: "Left Trigger")
        }
    }

    func handleDirectionalDrag(key: String, pressed: Bool) {
        PlayInput.touchQueue.async {
            if pressed {
                self.directionalKeys.insert(key)
            } else {
                self.directionalKeys.remove(key)
            }

            if self.directionalKeys.isEmpty {
                self.endDirectionalDrag()
            } else if self.directionalTouchId == nil, self.touchId == nil {
                self.beginDirectionalDrag(keyName: key)
                if !self.directionalPolling {
                    self.directionalPolling = true
                    self.pollDirectionalDrag()
                }
            }
        }
    }

    func deactivate(at newPosition: CGPoint? = nil) {
        if let newPosition {
            position = newPosition
        }
        isActive = false
        visible = false
        triggerPressed = false
        pendingDrag?.cancel()
        pendingDrag = nil
        if touchId != nil {
            Toucher.touchcam(point: position, phase: .ended, tid: &touchId,
                             actionName: "VirtualCursor", keyName: "Left Trigger")
        }
        directionalKeys.removeAll()
        endDirectionalDrag()
        DispatchQueue.main.async {
            self.cursorView.isHidden = true
        }
    }

    private func poll() {
        guard isActive else {
            polling = false
            previousPollTime = nil
            return
        }
        let vectorMagnitude = hypot(velocity.dx, velocity.dy)
        guard vectorMagnitude > innerDeadZone else {
            polling = false
            previousPollTime = nil
            return
        }

        let now = CACurrentMediaTime()
        let elapsed = previousPollTime.map { now - $0 } ?? pollingInterval
        previousPollTime = now
        let deltaTime = CGFloat(min(max(elapsed, 0), 1.0 / 30.0))

        // Preserve the stick direction while remapping the usable radial range linearly.
        // Full tilt therefore always means maximumSpeed, and half travel is predictable.
        let usableRange = 1 - innerDeadZone - outerDeadZone
        let cappedMagnitude = min(vectorMagnitude, 1 - outerDeadZone)
        let linearMagnitude = (cappedMagnitude - innerDeadZone) / usableRange
        let distance = maximumSpeed * linearMagnitude * deltaTime
        let movement = CGVector(dx: velocity.dx / vectorMagnitude * distance,
                                dy: velocity.dy / vectorMagnitude * distance)

        position.x = min(max(position.x + movement.dx, 0), screen.width)
        position.y = min(max(position.y + movement.dy, 0), screen.height)
        visible = true

        if touchId != nil {
            Toucher.touchcam(point: position, phase: .moved, tid: &touchId,
                             actionName: "VirtualCursor", keyName: "Left Trigger")
        }

        let nextPosition = position
        DispatchQueue.main.async {
            self.attachIfNeeded()
            self.cursorView.center = nextPosition
            self.cursorView.isHidden = false
        }

        PlayInput.touchQueue.asyncAfter(deadline: .now() + pollingInterval, execute: poll)
    }

    private func pollDirectionalDrag() {
        guard isActive, !directionalKeys.isEmpty, directionalTouchId != nil else {
            endDirectionalDrag()
            return
        }

        let direction = directionalVector()
        let magnitude = hypot(direction.dx, direction.dy)
        guard magnitude > 0 else {
            endDirectionalDrag()
            return
        }

        let speed: CGFloat = 8
        let point = CGPoint(x: directionalTouchPosition.x + direction.dx / magnitude * speed,
                            y: directionalTouchPosition.y + direction.dy / magnitude * speed)
        let edgeMargin: CGFloat = 12
        if point.x <= edgeMargin || point.x >= screen.width - edgeMargin ||
            point.y <= edgeMargin || point.y >= screen.height - edgeMargin {
            endDirectionalDrag()
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04) {
                guard self.isActive, !self.directionalKeys.isEmpty, self.touchId == nil else { return }
                self.beginDirectionalDrag(keyName: "Direction Pad")
                self.directionalPolling = true
                self.pollDirectionalDrag()
            }
            return
        }
        directionalTouchPosition = point
        Toucher.touchcam(point: point, phase: .moved, tid: &directionalTouchId,
                         actionName: "VirtualCursorDirectionalDrag", keyName: "Direction Pad")
        PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.017, execute: pollDirectionalDrag)
    }

    private func directionalVector() -> CGVector {
        var vector = CGVector.zero
        if directionalKeys.contains("Direction Pad Up") { vector.dy += 1 }
        if directionalKeys.contains("Direction Pad Down") { vector.dy -= 1 }
        if directionalKeys.contains("Direction Pad Left") { vector.dx += 1 }
        if directionalKeys.contains("Direction Pad Right") { vector.dx -= 1 }
        return vector
    }

    private func endDirectionalDrag() {
        if directionalTouchId != nil {
            Toucher.touchcam(point: directionalTouchPosition, phase: .ended, tid: &directionalTouchId,
                             actionName: "VirtualCursorDirectionalDrag", keyName: "Direction Pad")
        }
        directionalPolling = false
    }

    private func beginDirectionalDrag(keyName: String) {
        let direction = directionalVector()
        let resetDistance: CGFloat = 96
        directionalTouchPosition = position
        if direction.dx < 0 {
            directionalTouchPosition.x = max(directionalTouchPosition.x, resetDistance)
        } else if direction.dx > 0 {
            directionalTouchPosition.x = min(directionalTouchPosition.x, screen.width - resetDistance)
        }
        if direction.dy < 0 {
            directionalTouchPosition.y = max(directionalTouchPosition.y, resetDistance)
        } else if direction.dy > 0 {
            directionalTouchPosition.y = min(directionalTouchPosition.y, screen.height - resetDistance)
        }
        Toucher.touchcam(point: directionalTouchPosition, phase: .began, tid: &directionalTouchId,
                         actionName: "VirtualCursorDirectionalDrag", keyName: keyName)
    }

    private func attachIfNeeded() {
        guard let rootView = screen.keyWindow?.rootViewController?.view else { return }
        if cursorView.superview !== rootView {
            cursorView.removeFromSuperview()
            rootView.addSubview(cursorView)
        }
        rootView.bringSubviewToFront(cursorView)
    }
}

private final class VirtualCursorView: UIView {
    private let dot = UIView(frame: CGRect(x: 18, y: 18, width: 28, height: 28))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        dot.backgroundColor = UIColor.white.withAlphaComponent(0.82)
        dot.layer.cornerRadius = 14
        dot.layer.borderWidth = 3
        dot.layer.borderColor = UIColor.black.withAlphaComponent(0.72).cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.65
        dot.layer.shadowRadius = 10
        dot.layer.shadowOffset = .zero
        addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
