//
//  PlayAction.swift
//  PlayTools
//

// swiftlint:disable file_length
import Foundation
import UIKit

protocol Action {
    func invalidate()
}
// Actions hold touch point IDs, perform fake touch

class ButtonAction: Action {
    func invalidate() {
        keyIsPressed = false
        cancelPendingHold()
        if touchIsActive {
            touchIsActive = false
            releaseTouch()
        }
    }

    let keyCode: Int
    let keyName: String
    let modifierKeyCode: Int?
    let modifierKeyName: String?
    private let modifierKeys: [String]
    private let holdDuration: CGFloat?
    let point: CGPoint
    var id: Int?
    private var keyIsPressed = false
    private var touchIsActive = false
    private var pendingHold: DispatchWorkItem?

    init(keyCode: Int,
         keyName: String,
         modifierKeyCode: Int? = nil,
         modifierKeyName: String? = nil,
         holdDuration: CGFloat? = nil,
         point: CGPoint) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.modifierKeyCode = modifierKeyCode
        self.modifierKeyName = modifierKeyName
        self.modifierKeys = Self.dispatchNames(code: modifierKeyCode, name: modifierKeyName)
        self.holdDuration = holdDuration
        self.point = point
        // TODO: set both key names in draggable button, so as to depracate key code
        for key in Self.dispatchNames(code: keyCode, name: keyName) {
            ActionDispatcher.register(key: key, modifierKeys: modifierKeys, handler: self.update)
        }
        for key in modifierKeys {
            ActionDispatcher.register(key: key, handler: self.updateModifier)
        }
    }

    convenience init(data: Button) {
        let keyCode = data.keyCode
        self.init(
            keyCode: keyCode,
            keyName: data.keyName,
            modifierKeyCode: data.modifierKeyCode,
            modifierKeyName: data.modifierKeyName,
            holdDuration: data.holdDuration,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY))
    }

    func update(pressed: Bool) {
        if pressed {
            guard !keyIsPressed else {
                return
            }
            keyIsPressed = true
            beginAfterHoldIfNeeded()
        } else {
            guard keyIsPressed else {
                return
            }
            keyIsPressed = false
            cancelPendingHold()
            if touchIsActive {
                touchIsActive = false
                releaseTouch()
            }
        }
    }

    private func updateModifier(pressed: Bool) {
        if !pressed {
            keyIsPressed = false
            cancelPendingHold()
            if touchIsActive {
                touchIsActive = false
                releaseTouch()
            }
        }
    }

    private func beginAfterHoldIfNeeded() {
        guard let holdDuration = holdDuration else {
            touchIsActive = true
            beginTouch()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.keyIsPressed else {
                return
            }
            self.pendingHold = nil
            self.touchIsActive = true
            self.beginTouch()
        }
        pendingHold = workItem
        PlayInput.touchQueue.asyncAfter(deadline: .now() + Double(holdDuration),
                                        execute: workItem)
    }

    private func cancelPendingHold() {
        pendingHold?.cancel()
        pendingHold = nil
    }

    func beginTouch() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                         actionName: "Button", keyName: keyName)
    }

    func releaseTouch() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "Button", keyName: keyName)
    }

    fileprivate static func dispatchNames(code: Int?, name: String?) -> [String] {
        guard let name = name, !name.isEmpty else {
            return []
        }

        let resolvedCode = KeyCodeNames.keyCodeByName[name] ?? code
        if let resolvedCode = resolvedCode, resolvedCode != KeyCodeNames.defaultCode {
            return KeyCodeNames.dispatchNames(for: resolvedCode, fallback: name)
        }
        return [name]
    }
}

class TriggeredSwipeAction: Action {
    private let keyName: String
    private let modifierKeys: [String]
    private let holdDuration: CGFloat?
    private let startPoint: CGPoint
    private let endPoint: CGPoint
    private var keyIsPressed = false
    private var pendingHold: DispatchWorkItem?
    private var id: Int?

    init(data: Swipe) {
        self.keyName = data.keyName
        self.modifierKeys = ButtonAction.dispatchNames(code: data.modifierKeyCode,
                                                       name: data.modifierKeyName)
        self.holdDuration = data.holdDuration
        self.startPoint = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY)
        let length = data.transform.size.absoluteSize
        self.endPoint = CGPoint(
            x: startPoint.x + cos(data.angle) * length,
            y: startPoint.y + sin(data.angle) * length)

        for key in ButtonAction.dispatchNames(code: data.keyCode, name: data.keyName) {
            ActionDispatcher.register(key: key, modifierKeys: modifierKeys, handler: self.update)
        }
        for key in modifierKeys {
            ActionDispatcher.register(key: key, handler: self.updateModifier)
        }
    }

    func update(pressed: Bool) {
        if pressed {
            guard !keyIsPressed else {
                return
            }
            keyIsPressed = true
            performAfterHoldIfNeeded()
        } else {
            keyIsPressed = false
            cancelPendingHold()
        }
    }

    private func updateModifier(pressed: Bool) {
        if !pressed {
            keyIsPressed = false
            cancelPendingHold()
        }
    }

    private func performAfterHoldIfNeeded() {
        guard let holdDuration = holdDuration else {
            performSwipe()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.keyIsPressed else {
                return
            }
            self.pendingHold = nil
            self.performSwipe()
        }
        pendingHold = workItem
        PlayInput.touchQueue.asyncAfter(deadline: .now() + Double(holdDuration),
                                        execute: workItem)
    }

    private func cancelPendingHold() {
        pendingHold?.cancel()
        pendingHold = nil
    }

    private func performSwipe() {
        guard id == nil else {
            return
        }
        let length = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        let stepCount = 12
        let totalDuration = Self.swipeDuration(for: length)
        Toucher.touchcam(point: startPoint, phase: UITouch.Phase.began, tid: &id,
                         actionName: "Swipe", keyName: keyName)
        for step in 1...stepCount {
            let progress = CGFloat(step) / CGFloat(stepCount)
            let easedProgress = Self.easeInOut(progress)
            let point = CGPoint(
                x: startPoint.x + (endPoint.x - startPoint.x) * easedProgress,
                y: startPoint.y + (endPoint.y - startPoint.y) * easedProgress)
            PlayInput.touchQueue.asyncAfter(deadline: .now() + totalDuration * Double(progress),
                                            qos: .userInteractive) {
                Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &self.id,
                                 actionName: "Swipe", keyName: self.keyName)
            }
        }
        PlayInput.touchQueue.asyncAfter(deadline: .now() + totalDuration,
                                        qos: .userInteractive) {
            Toucher.touchcam(point: self.endPoint, phase: UITouch.Phase.ended, tid: &self.id,
                             actionName: "Swipe", keyName: self.keyName)
        }
    }

    private static func swipeDuration(for length: CGFloat) -> Double {
        let normalized = min(max(Double(length) / 420.0, 0.0), 1.0)
        return 0.18 + normalized * 0.16
    }

    private static func easeInOut(_ progress: CGFloat) -> CGFloat {
        progress * progress * (3 - 2 * progress)
    }

    func invalidate() {
        keyIsPressed = false
        cancelPendingHold()
        Toucher.touchcam(point: endPoint, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "Swipe", keyName: keyName)
    }
}

enum KeymapSwitchDirection {
    case next
    case previous
}

enum KeymapSwitcher {
    @discardableResult
    static func switchKeymap(_ direction: KeymapSwitchDirection) -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                switchKeymap(direction)
            }
            return true
        }

        guard keymap.keymapCount > 1 else {
            Toast.showHint(title: NSLocalizedString("hint.keymapping.onlyOneKeymap",
                                                    tableName: "Playtools",
                                                    value: "Only one keymap",
                                                    comment: ""))
            return false
        }

        switch direction {
        case .next:
            keymap.nextKeymap()
        case .previous:
            keymap.previousKeymap()
        }

        let format = NSLocalizedString("hint.keymapping.switchedKeymap",
                                       tableName: "Playtools",
                                       value: "Switched keymap: %@",
                                       comment: "")
        Toast.showHint(title: String(format: format, keymap.currentKeymapName))
        ActionDispatcher.build()
        EditorController.shared.refreshHUD()
        return true
    }
}

class ShoulderKeymapSwitchAction: Action {
    static private let userDefaultsKey = "playtools.shoulderKeymapSwitchEnabled"
    static private let defaultEnabled = true

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else {
                return defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: userDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
        }
    }

    private let cooldown: TimeInterval = 0.3
    private var lastSwitchDate = Date.distantPast

    init() {
        let leftShoulder = "Left Shoulder"
        let rightShoulder = "Right Shoulder"
        ActionDispatcher.register(key: rightShoulder,
                                  modifierKeys: [leftShoulder],
                                  handler: { [weak self] pressed in
                                      self?.update(pressed: pressed, direction: .next)
                                  })
        ActionDispatcher.register(key: leftShoulder,
                                  modifierKeys: [rightShoulder],
                                  handler: { [weak self] pressed in
                                      self?.update(pressed: pressed, direction: .previous)
                                  })
    }

    func invalidate() {}

    private func update(pressed: Bool, direction: KeymapSwitchDirection) {
        guard pressed else {
            return
        }
        guard Date().timeIntervalSince(lastSwitchDate) >= cooldown else {
            return
        }
        lastSwitchDate = Date()

        KeymapSwitcher.switchKeymap(direction)
    }
}

private class RadialSelectorOverlay: UIView {
    private let wheelSize: CGFloat = 192
    private let labelSize: CGFloat = 44
    private let selectorCenter: CGPoint
    private let targetPoints: [CGPoint]
    private let wheelContainer = UIView()
    private let selectionLabel = UILabel()
    private let labels = RadialSelectorModel.defaultSlots.map { slot -> UILabel in
        let label = UILabel()
        label.text = slot.title
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        return label
    }
    private let targetMarkers: [UILabel]

    init(selectorCenter: CGPoint, targetPoints: [CGPoint]) {
        self.selectorCenter = selectorCenter
        self.targetPoints = targetPoints
        self.targetMarkers = RadialSelectorModel.defaultSlots.enumerated().map { index, slot in
            let label = UILabel()
            label.text = slot.title
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 30, weight: .bold)
            label.textColor = .white
            label.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.8)
            label.layer.cornerRadius = 28
            label.clipsToBounds = true
            label.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
            label.layer.borderWidth = 3
            if !targetPoints.indices.contains(index) {
                label.isHidden = true
            }
            return label
        }
        super.init(frame: screen.screenRect)
        backgroundColor = UIColor.clear
        isUserInteractionEnabled = false
        wheelContainer.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        wheelContainer.layer.cornerRadius = wheelSize / 2
        wheelContainer.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.9).cgColor
        wheelContainer.layer.borderWidth = 3
        wheelContainer.frame = CGRect(
            x: selectorCenter.x - wheelSize / 2,
            y: selectorCenter.y - wheelSize / 2,
            width: wheelSize,
            height: wheelSize
        )
        addSubview(wheelContainer)

        selectionLabel.textAlignment = .center
        selectionLabel.font = UIFont.systemFont(ofSize: 44, weight: .heavy)
        selectionLabel.textColor = .white
        selectionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        selectionLabel.layer.cornerRadius = 30
        selectionLabel.clipsToBounds = true
        wheelContainer.addSubview(selectionLabel)

        labels.forEach(wheelContainer.addSubview)
        targetMarkers.forEach(addSubview)
        update(selectedIndex: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        wheelContainer.frame = CGRect(
            x: selectorCenter.x - wheelSize / 2,
            y: selectorCenter.y - wheelSize / 2,
            width: wheelSize,
            height: wheelSize
        )
        selectionLabel.frame = CGRect(x: 48, y: 66, width: 96, height: 60)

        let center = CGPoint(x: wheelContainer.bounds.midX, y: wheelContainer.bounds.midY)
        let radius: CGFloat = 66
        for (index, label) in labels.enumerated() {
            let angle = RadialSelectorModel.defaultSlots[index].angle
            label.frame = CGRect(
                x: center.x + cos(angle) * radius - labelSize / 2,
                y: center.y + sin(angle) * radius - labelSize / 2,
                width: labelSize,
                height: labelSize
            )
            label.layer.cornerRadius = labelSize / 2
        }

        for (index, marker) in targetMarkers.enumerated() where targetPoints.indices.contains(index) {
            let point = targetPoints[index]
            marker.frame = CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)
        }
    }

    func update(selectedIndex: Int?) {
        for (index, label) in labels.enumerated() {
            let selected = selectedIndex == index
            label.backgroundColor = selected
                ? UIColor.systemGreen.withAlphaComponent(0.92)
                : UIColor.black.withAlphaComponent(0.7)
            label.alpha = selected ? 1 : 0.28
            label.transform = selected ? CGAffineTransform(scaleX: 1.35, y: 1.35) : .identity
        }
        for (index, marker) in targetMarkers.enumerated() {
            let selected = selectedIndex == index
            marker.backgroundColor = selected
                ? UIColor.systemGreen.withAlphaComponent(0.92)
                : UIColor.systemTeal.withAlphaComponent(0.8)
            marker.alpha = selected ? 1 : 0.45
            marker.transform = selected ? CGAffineTransform(scaleX: 1.35, y: 1.35) : .identity
        }
        selectionLabel.text = selectedIndex.flatMap { labels.indices.contains($0) ? labels[$0].text : nil } ?? "RS"
        selectionLabel.backgroundColor = selectedIndex == nil
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.systemGreen.withAlphaComponent(0.9)
        wheelContainer.layer.borderColor = (selectedIndex == nil
            ? UIColor.systemTeal.withAlphaComponent(0.9)
            : UIColor.systemGreen.withAlphaComponent(0.95)).cgColor
    }
}

class RadialSelectorAction: Action {
    private let edgeTriggerThreshold: CGFloat = 0.92
    private let keyName: String
    private let modifierKeys: [String]
    private let holdDuration: CGFloat?
    private let threshold: CGFloat
    private let points: [CGPoint]
    private let selectorCenter: CGPoint
    private var modifierKeyDown = false
    private var modifierPressed = false
    private var pendingHold: DispatchWorkItem?
    private var lastEdgeTriggeredIndex: Int?
    private var selectedIndex: Int?
    private weak var overlay: RadialSelectorOverlay?

    init(data: RadialSelector) {
        self.keyName = data.keyName
        self.modifierKeys = ButtonAction.dispatchNames(code: data.modifierKeyCode,
                                                       name: data.modifierKeyName)
        self.holdDuration = data.holdDuration
        self.threshold = min(max(data.activationThreshold ?? 0.55, 0.2), 0.35)
        self.selectorCenter = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY
        )
        self.points = data.slots.map {
            CGPoint(x: $0.target.xCoord.absoluteX, y: $0.target.yCoord.absoluteY)
        }

        ActionDispatcher.register(key: keyName,
                                  modifierKeys: modifierKeys,
                                  handler: self.thumbstickUpdated)
        for modifierKey in modifierKeys {
            ActionDispatcher.register(key: modifierKey, handler: self.modifierUpdated)
        }
    }

    func invalidate() {
        modifierKeyDown = false
        modifierPressed = false
        cancelPendingHold()
        lastEdgeTriggeredIndex = nil
        selectedIndex = nil
        hideOverlay()
    }

    private func modifierUpdated(pressed: Bool) {
        modifierKeyDown = pressed
        if pressed {
            startAfterHoldIfNeeded()
        } else {
            cancelPendingHold()
            guard modifierPressed else {
                return
            }
            modifierPressed = false
            let alreadyTriggered = lastEdgeTriggeredIndex != nil
            let selectedPoint = selectedIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }
            lastEdgeTriggeredIndex = nil
            selectedIndex = nil
            hideOverlay()
            guard !alreadyTriggered else {
                return
            }
            guard let selectedPoint = selectedPoint else {
                return
            }
            triggerTap(at: selectedPoint)
        }
    }

    private func startAfterHoldIfNeeded() {
        guard let holdDuration = holdDuration else {
            activate()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingHold = nil
            self?.activate()
        }
        pendingHold = workItem
        PlayInput.touchQueue.asyncAfter(deadline: .now() + Double(holdDuration),
                                        execute: workItem)
    }

    private func activate() {
        guard modifierKeyDown else {
            return
        }
        guard !modifierPressed else {
            return
        }
        modifierPressed = true
        lastEdgeTriggeredIndex = nil
        showOverlay()
    }

    private func cancelPendingHold() {
        pendingHold?.cancel()
        pendingHold = nil
    }

    private func thumbstickUpdated(_ valueX: CGFloat, _ valueY: CGFloat) {
        guard modifierPressed else {
            return
        }
        let magnitude = hypot(valueX, valueY)
        guard magnitude >= threshold else {
            selectedIndex = nil
            lastEdgeTriggeredIndex = nil
            DispatchQueue.main.async {
                self.overlay?.update(selectedIndex: nil)
            }
            return
        }
        let angle = normalizedAngle(atan2(-valueY, valueX))
        let newIndex = nearestSlotIndex(for: angle)
        if newIndex != selectedIndex {
            selectedIndex = newIndex
            DispatchQueue.main.async {
                self.overlay?.update(selectedIndex: newIndex)
            }
        }

        if magnitude >= edgeTriggerThreshold,
           lastEdgeTriggeredIndex != newIndex,
           points.indices.contains(newIndex) {
            lastEdgeTriggeredIndex = newIndex
            triggerTap(at: points[newIndex])
        } else if magnitude < edgeTriggerThreshold {
            lastEdgeTriggeredIndex = nil
        }
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        let remainder = angle.truncatingRemainder(dividingBy: twoPi)
        return remainder >= 0 ? remainder : remainder + twoPi
    }

    private func nearestSlotIndex(for angle: CGFloat) -> Int {
        RadialSelectorModel.defaultSlots.enumerated().min { lhs, rhs in
            angularDistance(lhs.element.angle, angle) < angularDistance(rhs.element.angle, angle)
        }?.offset ?? 0
    }

    private func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: twoPi)
        return min(distance, twoPi - distance)
    }

    private func triggerTap(at point: CGPoint) {
        var touchId: Int?
        Toucher.touchcam(point: point, phase: .began, tid: &touchId,
                         actionName: "RadialSelector", keyName: keyName)
        PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.05, qos: .userInteractive) {
            Toucher.touchcam(point: point, phase: .ended, tid: &touchId,
                             actionName: "RadialSelector", keyName: self.keyName)
        }
    }

    private func showOverlay() {
        DispatchQueue.main.async {
            if let overlay = self.overlay {
                overlay.isHidden = false
                overlay.center = self.selectorCenter
                overlay.update(selectedIndex: self.selectedIndex)
                return
            }
            let overlay = RadialSelectorOverlay(selectorCenter: self.selectorCenter,
                                                targetPoints: self.points)
            overlay.update(selectedIndex: self.selectedIndex)
            screen.keyWindow?.addSubview(overlay)
            self.overlay = overlay
        }
    }

    private func hideOverlay() {
        DispatchQueue.main.async {
            self.overlay?.removeFromSuperview()
            self.overlay = nil
        }
    }
}

class DraggableButtonAction: ButtonAction {
    var releasePoint: CGPoint

    override init(keyCode: Int,
                  keyName: String,
                  modifierKeyCode: Int? = nil,
                  modifierKeyName: String? = nil,
                  holdDuration: CGFloat? = nil,
                  point: CGPoint) {
        self.releasePoint = point
        super.init(
            keyCode: keyCode,
            keyName: keyName,
            modifierKeyCode: modifierKeyCode,
            modifierKeyName: modifierKeyName,
            holdDuration: holdDuration,
            point: point)
    }

    convenience init(data: Button) {
        self.init(
            keyCode: data.keyCode,
            keyName: data.keyName,
            modifierKeyCode: data.modifierKeyCode,
            modifierKeyName: data.modifierKeyName,
            holdDuration: data.holdDuration,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY))
    }

    override func beginTouch() {
        Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                         actionName: "DraggableButton", keyName: keyName)
        self.releasePoint = point
        ActionDispatcher.register(key: keyName,
                                  handler: self.onMouseMoved,
                                  priority: .DRAGGABLE)
        if keyName == KeyCodeNames.mouseMove && !mode.cursorHidden() {
            AKInterface.shared!.hideCursor()
        }
    }

    override func releaseTouch() {
        Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "DraggableButton", keyName: keyName)
        if id == nil {
            ActionDispatcher.unregister(key: keyName)
            if keyName == KeyCodeNames.mouseMove && !mode.cursorHidden() {
                AKInterface.shared!.unhideCursor()
            }
        }
    }

    override func invalidate() {
        ActionDispatcher.unregister(key: keyName)
        super.invalidate()
    }

    func onMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        self.releasePoint.x += deltaX
        self.releasePoint.y -= deltaY
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: &id,
                         actionName: "DraggableButton", keyName: keyName)
    }
}

class ContinuousJoystickAction: Action {
    var key: String
    var center: CGPoint
    var position: CGPoint!
    private var id: Int?
    var sensitivity: CGFloat
    var mode: JoystickMode
    var begun = false

    init(data: Joystick) {
        self.center = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY)
        self.key = data.keyName
        position = center
        self.sensitivity = data.transform.size.absoluteSize / 4
        self.mode = data.mode ?? Joystick.defaultMode
        if key == KeyCodeNames.mouseMove {
            ActionDispatcher.register(key: key, handler: self.mouseUpdate)
        } else {
            ActionDispatcher.register(key: key, handler: self.thumbstickUpdate)
        }
    }

    func update(_ point: CGPoint) {
        let dis = (center.x - point.x).magnitude + (center.y - point.y).magnitude
        if dis < 16 {
            if begun {
                begun = false
                Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id,
                                 actionName: "ControllerJoystick", keyName: key)
            }
        } else if !begun {
            begun = true
            beginTouch(point)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
        }
    }

    func beginTouch(_ point: CGPoint) {
        if mode == .FIXED {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
        } else if mode == .FLOATING {
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04, qos: .userInitiated) {
                if self.id == nil {
                    return
                }
                Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &self.id,
                                 actionName: "ControllerJoystick", keyName: self.key)
            }
        }
    }

    func thumbstickUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let pos = CGPoint(x: center.x + deltaX * sensitivity,
                          y: center.y - deltaY * sensitivity)
        self.update(pos)
    }

    func mouseUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        position.x += deltaX
        position.y -= deltaY
        self.update(position)
    }

    func invalidate() {
        Toucher.touchcam(point: CGPoint(x: 10, y: 10), phase: UITouch.Phase.ended, tid: &id,
                         actionName: "ControllerJoystick", keyName: key)
    }
}

class JoystickAction: Action {
    let keys: [Int]
    let center: CGPoint
    var touch: CGPoint
    let shift: CGFloat
    var mode: JoystickMode
    var id: Int?
    private var keyPressed = [Bool](repeating: false, count: 4)
    init(keys: [Int], center: CGPoint, shift: CGFloat, mode: JoystickMode) {
        self.keys = keys
        self.center = center
        self.touch = center
        self.shift = shift / 4
        self.mode = mode
        for index in 0..<keys.count {
            let key = keys[index]
            for keyName in KeyCodeNames.dispatchNames(for: key) {
                ActionDispatcher.register(key: keyName,
                                         handler: self.getPressedHandler(index: index))
            }
        }
    }

    convenience init(data: Joystick) {
        self.init(
            keys: [
                data.upKeyCode,
                data.downKeyCode,
                data.leftKeyCode,
                data.rightKeyCode
            ],
            center: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY),
            shift: data.transform.size.absoluteSize,
            mode: data.mode ?? Joystick.defaultMode)
    }

    func invalidate() {
        Toucher.touchcam(point: center, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "KeyboardJoystick", keyName: "Keyboard")
    }

    func getPressedHandler(index: Int) -> (Bool) -> Void {
        if mode == .FIXED {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFixed()
            }
        } else if mode == .FLOATING {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFree()
            }
        } else {
            return { _ in
                // do nothing
            }
        }
    }

    func updateTouch(index: Int, pressed: Bool) {
        self.keyPressed[index] = pressed
        let isPlus = index & 1 != 0
        let realShift = isPlus ? shift : -shift
        if index > 1 {
            if pressed {
                touch.x = center.x + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.x = center.x - realShift
            } else {
                touch.x = center.x
            }
        } else {
            if pressed {
                touch.y = center.y + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.y = center.y - realShift
            } else {
                touch.y = center.y
            }
        }
    }

    func atCenter() -> Bool {
        return (center.x - touch.x).magnitude + (center.y - touch.y).magnitude < 8
    }

    func handleCommon(_ begin: () -> Void) {
        let moving = id != nil
        if atCenter() {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.ended, tid: &id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            }
        } else {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: &id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            } else {
                begin()
            }
        }
    }

    func handleFree() {
        handleCommon {
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: &id,
                             actionName: "KeyboardJoystick", keyName: "Keyboard")
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04, qos: .userInitiated) {
                if self.id == nil {
                    return
                }
                Toucher.touchcam(point: self.touch, phase: UITouch.Phase.moved, tid: &self.id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            } // end closure
        }
    }

    func handleFixed() {
        handleCommon {
            Toucher.touchcam(point: self.touch, phase: UITouch.Phase.began, tid: &id,
                             actionName: "KeyboardJoystick", keyName: "Keyboard")
        }
    }
}

class CameraAction: Action {
    var swipeMove, swipeScale1, swipeScale2: SwipeAction
    static var swipeDrag = SwipeAction(actionName: "Drag", keyName: "ScrollWheel")
    var key: String!
    var center: CGPoint

    init(data: MouseArea) {
        self.key = data.keyName
        let centerX = data.transform.xCoord.absoluteX
        let centerY = data.transform.yCoord.absoluteY
        center = CGPoint(x: centerX, y: centerY)
        swipeMove = SwipeAction(actionName: "Camera", keyName: key)
        swipeScale1 = SwipeAction(actionName: "Zoom1", keyName: "ScrollWheel")
        swipeScale2 = SwipeAction(actionName: "Zoom2", keyName: "ScrollWheel")
        ActionDispatcher.register(key: key, handler: self.moveUpdated,
                                  priority: .CAMERA)
        ActionDispatcher.register(key: KeyCodeNames.scrollWheelScale,
                                  handler: self.scaleUpdated)
        ActionDispatcher.register(key: KeyCodeNames.scrollWheelDrag,
                                  handler: CameraAction.dragUpdated)
    }
    func moveUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeMove.move(from: {return center}, deltaX: deltaX, deltaY: deltaY)
    }

    func scaleUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let centerY = screen.height/2
        let centerX = screen.width/2
        swipeScale1.move(from: {
            CGPoint(x: centerX, y: centerY/2)
        }, deltaX: 0, deltaY: deltaY)

        swipeScale2.move(from: {
            CGPoint(x: centerX, y: centerY + (centerY/2))
        }, deltaX: 0, deltaY: -deltaY)
        // a move can't be longer than `centerY/16` due to the velocity limiter of `CameraAction`
        // so lifting off before two touches meet
        if swipeScale2.location.y - centerY < centerY/16 {
            swipeScale1.doLiftOff()
            swipeScale2.doLiftOff()
        }
    }

    static func dragUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeDrag.move(from: TouchscreenMouseEventAdapter.cursorPos, deltaX: deltaX * 4, deltaY: -deltaY * 4)
    }

    func invalidate() {
        swipeMove.invalidate()
        swipeScale1.invalidate()
        swipeScale2.invalidate()
    }
}

class SwipeAction: Action {
    var location: CGPoint = CGPoint.zero
    private var id: Int?
    let timer = DispatchSource.makeTimerSource(flags: [], queue: PlayInput.touchQueue)
    private let actionName: String, keyName: String
    init(actionName: String, keyName: String) {
        self.actionName = actionName
        self.keyName = keyName
        timer.schedule(deadline: DispatchTime.now() + 1, repeating: 0.1, leeway: DispatchTimeInterval.milliseconds(50))
        timer.setEventHandler(qos: .userInteractive, handler: self.checkEnded)
        timer.activate()
        timer.suspend()
    }

    deinit {
        timer.cancel()
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
    var shouldEdgeReset = false

    func checkEnded() {
        if self.counter == self.lastCounter {
            if self.counter < 4 {
                counter += 1
            } else {
                self.doLiftOff()
            }
        }
        self.lastCounter = self.counter
     }

    private func checkXYOutOfWindow(coordX: CGFloat, coordY: CGFloat) -> Bool {
        return coordX < 0 || coordY < 0 || coordX > screen.width || coordY > screen.height
    }

    /**
     get a multiplier to current velocity, so as to make the predicted coordinate inside window
     */
    private func getVelocityScaler(predictX: CGFloat, predictY: CGFloat,
                                   nowX: CGFloat, nowY: CGFloat) -> CGFloat {
        var scaler = 1.0
        if predictX < 0 {
            let scale =  (0 - nowX) / (predictX - nowX)
            scaler = min(scaler, scale)
        } else if predictX > screen.width {
            let scale =  (screen.width - nowX) / (predictX - nowX)
            scaler = min(scaler, scale)
        }

        if predictY < 0 {
            let scale =  (0 - nowY) / (predictY - nowY)
            scaler = min(scaler, scale)
        } else if predictY > screen.height {
            let scale =  (screen.height - nowY) / (predictY - nowY)
            scaler = min(scaler, scale)
        }
        return scaler
    }

    public func move(from: () -> CGPoint?, deltaX: CGFloat, deltaY: CGFloat) {
        if id == nil {
            if cooldown {
                return
            }
            guard let start = from() else {return}
            location = start
            counter = 0
            Toucher.touchcam(point: location, phase: UITouch.Phase.began, tid: &id,
                             actionName: actionName, keyName: keyName)
            timer.resume()
        } else {
            if shouldEdgeReset {
                doLiftOff()
                return
            }
            // 1. Put location update after touch action, so that final `end` touch has different location
            // 2. If `began` touched, do not `move` touch at the same time, otherwise the two may conflict
            Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: &id,
                             actionName: actionName, keyName: keyName)
        }
        // Scale movement down, so that an edge reset won't cause a too short touch sequence
        var scaledDeltaX = deltaX
        var scaledDeltaY = deltaY
        // A scroll must have this number of touch events to get inertia
        let minTotalCounter = 16
        if counter < minTotalCounter {
            // Suppose the touch velocity doesn't change
            let predictX = self.location.x + CGFloat((minTotalCounter - counter)) * deltaX
            let predictY = self.location.y - CGFloat((minTotalCounter - counter)) * deltaY
            if checkXYOutOfWindow(coordX: predictX, coordY: predictY) {
                // Velocity needs scale down
                let scaler = getVelocityScaler(predictX: predictX, predictY: predictY,
                                               nowX: self.location.x, nowY: self.location.y)
                scaledDeltaX *= scaler
                scaledDeltaY *= scaler
            }
        }
        // count touch duration
        counter += 1
        self.location.x += scaledDeltaX
        self.location.y -= scaledDeltaY
        // Check if new location is out of window (position overflows)
        // May fail in some games if point moves out of window
        // If next touch is predicted out of window then this lift off instead
        if checkXYOutOfWindow(coordX: self.location.x + scaledDeltaX,
                              coordY: self.location.y - scaledDeltaY) {
            // Wait until next event to lift off, so as to maintain smooth scrolling speed
            shouldEdgeReset = true
        }
    }

    public func doLiftOff() {
        if id == nil {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: &id,
                         actionName: actionName, keyName: keyName)
        // Touch might somehow fail to end
        if id == nil {
            timer.suspend()
            delay(0.02) {
                self.cooldown = false
            }
            cooldown = true
            shouldEdgeReset = false
        }
    }

    func invalidate() {
        PlayInput.touchQueue.async(execute: self.doLiftOff)
    }
}

class FakeMouseAction: Action {
    var id: Int?
    var pos: CGPoint = CGPoint()
    public init() {
        ActionDispatcher.register(key: KeyCodeNames.fakeMouse, handler: buttonPressHandler)
        ActionDispatcher.register(key: KeyCodeNames.fakeMouse, handler: buttonLiftHandler)
    }

    func buttonPressHandler(xValue: CGFloat, yValue: CGFloat) {
        pos = CGPoint(x: xValue, y: yValue)
//        DispatchQueue.main.async {
//            Toast.showHint(title: "Fake mouse pressed", text: ["\(self.pos)"])
//        }
        Toucher.touchcam(point: pos, phase: UITouch.Phase.began, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
        ActionDispatcher.register(key: KeyCodeNames.fakeMouse,
                                  handler: movementHandler,
                                  priority: .DRAGGABLE)
    }

    func buttonLiftHandler(pressed: Bool) {
        if pressed {
            Toast.showHint(title: "Error", text: ["Fake mouse lift handler received a press event"])
            return
        }
//        DispatchQueue.main.async {
//            Toast.showHint(title: " lift Fake mouse", text: ["\(self.pos)"])
//        }
        Toucher.touchcam(point: pos, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
        if id == nil {
            ActionDispatcher.unregister(key: KeyCodeNames.fakeMouse)
        }
    }

    func movementHandler(xValue: CGFloat, yValue: CGFloat) {
        pos.x = xValue
        pos.y = yValue
        Toucher.touchcam(point: pos, phase: UITouch.Phase.moved, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
    }

    func invalidate() {
        ActionDispatcher.unregister(key: KeyCodeNames.fakeMouse)
        Toucher.touchcam(point: pos ?? CGPoint(x: 10, y: 10),
                         phase: UITouch.Phase.ended, tid: &self.id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
    }

}
