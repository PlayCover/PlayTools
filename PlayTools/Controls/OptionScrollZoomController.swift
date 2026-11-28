//
//  OptionScrollZoomController.swift
//  PlayTools
//
//  Synthesizes symmetric two-finger pinch gestures from Option + Mouse Scroll Wheel.
//

import CoreGraphics
import Foundation
import UIKit

// MARK: - OptionScrollZoomMath (extracted for standalone contract testing)

struct OptionScrollZoomAnchor: Equatable {
    let center: CGPoint
    let startRadius: CGFloat
    let minRadius: CGFloat
    let maxRadius: CGFloat
}

enum OptionScrollZoomMath {
    static let invSqrt2: CGFloat = 1.0 / sqrt(2.0)
    static let edgeMargin: CGFloat = 16.0
    static let minRadius: CGFloat = 32.0
    static let maxBoundsRadiusRatio: CGFloat = 0.42
    static let zoomInStartRadius: CGFloat = 60.0
    static let zoomOutStartRadius: CGFloat = 180.0
    static let discreteZoomExponent: CGFloat = 0.165
    static let preciseZoomExponent: CGFloat = 0.012
    static let maxDiscreteDelta: CGFloat = 3.5
    static let maxPreciseDelta: CGFloat = 36.0
    static let maxFrameExpandRatio: CGFloat = 1.18
    static let maxFrameShrinkRatio: CGFloat = 0.84
    static let maxFrameExpandPoints: CGFloat = 28.0
    static let maxFrameShrinkPoints: CGFloat = 24.0
    static let minInitialKick: CGFloat = 6.0
    static let maxInitialKick: CGFloat = 10.0

    static func zoomFactor(deltaY: CGFloat, isPrecise: Bool) -> CGFloat {
        guard deltaY.isFinite, abs(deltaY) >= 0.0001 else { return 1.0 }
        let limit = isPrecise ? maxPreciseDelta : maxDiscreteDelta
        let clamped = min(max(deltaY, -limit), limit)
        return exp(clamped * (isPrecise ? preciseZoomExponent : discreteZoomExponent))
    }

    static func targetRadius(
        from radius: CGFloat, deltaY: CGFloat, isPrecise: Bool, anchor: OptionScrollZoomAnchor
    ) -> CGFloat {
        let proposed = radius * zoomFactor(deltaY: deltaY, isPrecise: isPrecise)
        return min(max(proposed, anchor.minRadius), anchor.maxRadius)
    }

    static func nextFrameRadius(current: CGFloat, target: CGFloat, isFirstMove: Bool) -> CGFloat {
        let delta = target - current
        let magnitude = abs(delta)
        guard magnitude > 0.5 else { return target }
        let direction: CGFloat = delta >= 0 ? 1.0 : -1.0
        if isFirstMove && magnitude > 8.0 {
            let kick = min(maxInitialKick, max(minInitialKick, magnitude * 0.45))
            if kick < magnitude - 1.0 { return current + direction * kick }
        }
        if delta > 0 {
            let maxStep = min(maxFrameExpandPoints, max(6.0, current * (maxFrameExpandRatio - 1.0)))
            return magnitude <= maxStep ? target : current + maxStep
        }
        let maxStep = min(maxFrameShrinkPoints, max(5.0, current * (1.0 - maxFrameShrinkRatio)))
        return magnitude <= maxStep ? target : current - maxStep
    }

    static func computeAnchor(cursor: CGPoint, bounds: CGRect, deltaY: CGFloat) -> OptionScrollZoomAnchor? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 80, bounds.height > 80 else { return nil }
        let minDim = min(bounds.width, bounds.height)
        let safeRect = bounds.insetBy(dx: min(edgeMargin, minDim * 0.1), dy: min(edgeMargin, minDim * 0.1))
        guard safeRect.width > 64, safeRect.height > 64 else { return nil }

        let boundsMaxRadius = minDim * maxBoundsRadiusRatio
        let maxPossibleRadius = min(boundsMaxRadius, (min(safeRect.width, safeRect.height) * 0.5) / invSqrt2)
        guard maxPossibleRadius > minRadius + 16.0 else { return nil }

        let preferredStart: CGFloat = deltaY >= 0
            ? min(zoomInStartRadius, minRadius + (maxPossibleRadius - minRadius) * 0.30)
            : min(zoomOutStartRadius, minRadius + (maxPossibleRadius - minRadius) * 0.85)
        let clampedStart = max(minRadius + 8.0, min(preferredStart, maxPossibleRadius - 6.0))
        let neededHalf = clampedStart * invSqrt2 + (deltaY > 0 ? 24.0 : 4.0)
        let padX = min(neededHalf, safeRect.width * 0.45)
        let padY = min(neededHalf, safeRect.height * 0.45)
        let centerX = min(max(cursor.x, safeRect.minX + padX), safeRect.maxX - padX)
        let centerY = min(max(cursor.y, safeRect.minY + padY), safeRect.maxY - padY)
        let availHalf = min(
            min(centerX - safeRect.minX, safeRect.maxX - centerX),
            min(centerY - safeRect.minY, safeRect.maxY - centerY)
        )
        let maxRadius = min(boundsMaxRadius, availHalf / invSqrt2)
        guard maxRadius > minRadius + 12.0 else { return nil }
        let finalStart = max(minRadius + 6.0, min(clampedStart, maxRadius - 6.0))
        return OptionScrollZoomAnchor(
            center: CGPoint(x: centerX, y: centerY),
            startRadius: finalStart,
            minRadius: minRadius,
            maxRadius: maxRadius
        )
    }

    static func fingerPoints(center: CGPoint, radius: CGFloat) -> (CGPoint, CGPoint) {
        let offset = radius * invSqrt2
        return (
            CGPoint(x: center.x - offset, y: center.y - offset),
            CGPoint(x: center.x + offset, y: center.y + offset)
        )
    }
}

// MARK: - OptionScrollZoomController

final class OptionScrollZoomController {
    static let shared = OptionScrollZoomController()

    private enum PinchState { case idle, beganPendingFirstMove, active, reanchoring }

    private struct PendingReanchor {
        weak var window: UIWindow?
        weak var view: UIView?
        var point: CGPoint
        var deltaY: CGFloat
        var isPrecise: Bool
    }

    private static let idleLiftOffMs = 220
    private static let initialMoveDelayMs = 12
    private static let frameStepDelayMs = 14
    private static let reanchorDelayMs = 24
    private static let cursorJumpThreshold: CGFloat = 96.0

    private var initialized = false
    private var state: PinchState = .idle
    private var generation: UInt64 = 0
    private weak var targetWindow: UIWindow?
    private weak var targetView: UIView?
    private var anchor: OptionScrollZoomAnchor?
    private var currentRadius: CGFloat = 0
    private var pendingRadius: CGFloat = 0
    private var firstTouchId: Int?
    private var secondTouchId: Int?
    private var stepWorkItem: DispatchWorkItem?
    private var idleWorkItem: DispatchWorkItem?
    private var reanchorWorkItem: DispatchWorkItem?
    private var pendingReanchor: PendingReanchor?

    private init() {}

    func initialize() {
        guard !initialized else { return }
        initialized = true
        guard PlaySettings.shared.optionScrollZoom, let akInterface = AKInterface.shared else { return }

        akInterface.setupOptionScrollZoom?(
            { [weak self] normalizedX, normalizedY, deltaY, isPrecise in
                self?.handleScrollZoom(
                    normalizedX: normalizedX, normalizedY: normalizedY, deltaY: deltaY, isPrecise: isPrecise
                ) ?? false
            },
            onEnd: { [weak self] in self?.endZoomOnMain() }
        )

        let center = NotificationCenter.default
        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            NSNotification.Name.playtoolsCursorWillHide
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.endZoom() }
        }
    }

    func endZoom() {
        generation &+= 1
        idleWorkItem?.cancel()
        idleWorkItem = nil
        pendingReanchor = nil
        endActiveTouchesOnly()
        state = .idle
    }
}

private extension OptionScrollZoomController {
    func handleScrollZoom(
        normalizedX: CGFloat, normalizedY: CGFloat, deltaY: CGFloat, isPrecise: Bool
    ) -> Bool {
        guard PlaySettings.shared.optionScrollZoom else { return false }
        if PlaySettings.shared.keymapping,
           mode == .cameraRotate || mode == .editor || mode.cursorHidden() {
            endZoom()
            return false
        }
        guard deltaY.isFinite, abs(deltaY) >= 0.0001 else {
            if state != .idle { scheduleIdleLiftOff() }
            return true
        }
        guard let target = PlayScreen.shared.resolveTouchTarget(
            forNormalizedContentX: normalizedX, y: normalizedY
        ) else { return false }
        scheduleIdleLiftOff()
        switch state {
        case .idle:
            return beginPinch(
                window: target.window, view: target.hitView,
                cursor: target.point, deltaY: deltaY, isPrecise: isPrecise
            )
        case .reanchoring:
            accumulateReanchor(
                window: target.window, view: target.hitView,
                cursor: target.point, deltaY: deltaY, isPrecise: isPrecise
            )
            return true
        case .beganPendingFirstMove, .active:
            return continuePinch(
                window: target.window, view: target.hitView,
                cursor: target.point, deltaY: deltaY, isPrecise: isPrecise
            )
        }
    }

    func beginPinch(
        window: UIWindow, view: UIView, cursor: CGPoint, deltaY: CGFloat, isPrecise: Bool
    ) -> Bool {
        guard let newAnchor = OptionScrollZoomMath.computeAnchor(
            cursor: cursor, bounds: window.bounds, deltaY: deltaY
        ) else { return false }
        let (pointA, pointB) = OptionScrollZoomMath.fingerPoints(
            center: newAnchor.center, radius: newAnchor.startRadius
        )
        let tidA = PTFakeMetaTouch.fakeTouchId(-1, at: pointA, with: .began, in: window, on: view)
        guard tidA >= 0 else { return false }
        let tidB = PTFakeMetaTouch.fakeTouchId(-1, at: pointB, with: .began, in: window, on: view)
        guard tidB >= 0 else {
            _ = PTFakeMetaTouch.fakeTouchId(tidA, at: pointA, with: .ended, in: window, on: view)
            return false
        }
        generation &+= 1
        targetWindow = window
        targetView = view
        anchor = newAnchor
        firstTouchId = tidA
        secondTouchId = tidB
        currentRadius = newAnchor.startRadius
        pendingRadius = OptionScrollZoomMath.targetRadius(
            from: newAnchor.startRadius, deltaY: deltaY, isPrecise: isPrecise, anchor: newAnchor
        )
        state = .beganPendingFirstMove
        scheduleNextStep(for: generation, delayMs: Self.initialMoveDelayMs)
        return true
    }

    func continuePinch(
        window: UIWindow, view: UIView, cursor: CGPoint, deltaY: CGFloat, isPrecise: Bool
    ) -> Bool {
        guard let activeAnchor = anchor,
              let activeWindow = targetWindow,
              targetView != nil,
              activeWindow === window else {
            triggerReanchor(window: window, view: view, cursor: cursor, deltaY: deltaY, isPrecise: isPrecise)
            return true
        }
        let cursorShift = hypot(cursor.x - activeAnchor.center.x, cursor.y - activeAnchor.center.y)
        let hitMin = deltaY < 0 && currentRadius <= activeAnchor.minRadius + 2.0
        let hitMax = deltaY > 0 && currentRadius >= activeAnchor.maxRadius - 2.0
        if cursorShift > Self.cursorJumpThreshold || hitMin || hitMax {
            triggerReanchor(window: window, view: view, cursor: cursor, deltaY: deltaY, isPrecise: isPrecise)
            return true
        }
        pendingRadius = OptionScrollZoomMath.targetRadius(
            from: pendingRadius, deltaY: deltaY, isPrecise: isPrecise, anchor: activeAnchor
        )
        if state == .active && stepWorkItem == nil {
            performFrameStep(expectedGen: generation)
        }
        return true
    }

    func scheduleNextStep(for expectedGen: UInt64, delayMs: Int) {
        stepWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performFrameStep(expectedGen: expectedGen) }
        stepWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    func performFrameStep(expectedGen: UInt64) {
        guard generation == expectedGen,
              state == .beganPendingFirstMove || state == .active else { return }
        stepWorkItem = nil
        let nextRadius = OptionScrollZoomMath.nextFrameRadius(
            current: currentRadius, target: pendingRadius, isFirstMove: state == .beganPendingFirstMove
        )
        sendMoved(to: nextRadius)
        guard generation == expectedGen else { return }
        state = .active
        scheduleIdleLiftOff()
        if abs(pendingRadius - currentRadius) > 0.5 {
            scheduleNextStep(for: expectedGen, delayMs: Self.frameStepDelayMs)
        }
    }

    func sendMoved(to radius: CGFloat) {
        guard let activeAnchor = anchor,
              let window = targetWindow,
              let view = targetView,
              let tidA = firstTouchId,
              let tidB = secondTouchId else {
            endZoom()
            return
        }
        let (pointA, pointB) = OptionScrollZoomMath.fingerPoints(center: activeAnchor.center, radius: radius)
        let nextA = PTFakeMetaTouch.fakeTouchId(tidA, at: pointA, with: .moved, in: window, on: view)
        let nextB = PTFakeMetaTouch.fakeTouchId(tidB, at: pointB, with: .moved, in: window, on: view)
        if nextA < 0 || nextB < 0 {
            firstTouchId = nextA >= 0 ? nextA : nil
            secondTouchId = nextB >= 0 ? nextB : nil
            endZoom()
            return
        }
        firstTouchId = nextA
        secondTouchId = nextB
        currentRadius = radius
    }

    func triggerReanchor(
        window: UIWindow, view: UIView, cursor: CGPoint, deltaY: CGFloat, isPrecise: Bool
    ) {
        endActiveTouchesOnly()
        generation &+= 1
        let expectedGen = generation
        state = .reanchoring
        pendingReanchor = PendingReanchor(
            window: window, view: view, point: cursor, deltaY: deltaY, isPrecise: isPrecise
        )
        let item = DispatchWorkItem { [weak self] in self?.completeReanchor(expectedGen: expectedGen) }
        reanchorWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.reanchorDelayMs), execute: item)
    }

    func accumulateReanchor(
        window: UIWindow, view: UIView, cursor: CGPoint, deltaY: CGFloat, isPrecise: Bool
    ) {
        let limit = isPrecise ? OptionScrollZoomMath.maxPreciseDelta : OptionScrollZoomMath.maxDiscreteDelta
        let combined = min(max((pendingReanchor?.deltaY ?? 0) + deltaY, -limit), limit)
        pendingReanchor = PendingReanchor(
            window: window, view: view, point: cursor, deltaY: combined, isPrecise: isPrecise
        )
    }

    func completeReanchor(expectedGen: UInt64) {
        guard generation == expectedGen, state == .reanchoring else { return }
        reanchorWorkItem = nil
        let queued = pendingReanchor
        pendingReanchor = nil
        state = .idle
        guard let queued, let window = queued.window, let view = queued.view else { return }
        _ = beginPinch(
            window: window, view: view, cursor: queued.point,
            deltaY: queued.deltaY, isPrecise: queued.isPrecise
        )
    }

    func scheduleIdleLiftOff() {
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endZoom() }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.idleLiftOffMs), execute: item)
    }

    func endActiveTouchesOnly() {
        stepWorkItem?.cancel()
        stepWorkItem = nil
        reanchorWorkItem?.cancel()
        reanchorWorkItem = nil
        if let activeAnchor = anchor {
            let (pointA, pointB) = OptionScrollZoomMath.fingerPoints(
                center: activeAnchor.center, radius: currentRadius
            )
            if let tidA = firstTouchId {
                _ = PTFakeMetaTouch.fakeTouchId(tidA, at: pointA, with: .ended, in: targetWindow, on: targetView)
            }
            if let tidB = secondTouchId {
                _ = PTFakeMetaTouch.fakeTouchId(tidB, at: pointB, with: .ended, in: targetWindow, on: targetView)
            }
        }
        firstTouchId = nil
        secondTouchId = nil
        targetWindow = nil
        targetView = nil
        anchor = nil
        currentRadius = 0
        pendingRadius = 0
    }

    func endZoomOnMain() {
        if Thread.isMainThread { endZoom() } else { DispatchQueue.main.async { [weak self] in self?.endZoom() } }
    }
}
