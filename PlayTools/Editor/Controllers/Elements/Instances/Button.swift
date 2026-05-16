//
//  Button.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class ButtonModel: ControlModel<Button> {
    static let defaultHoldDuration: CGFloat = 0.5
    private static let shortKeyNames = [
        "Button Menu": "Menu",
        "Button Options": "Options",
        "Direction Pad Up": "D-Up",
        "Direction Pad Down": "D-Down",
        "Direction Pad Left": "D-Left",
        "Direction Pad Right": "D-Right",
        "Left Shoulder": "LB",
        "Left Trigger": "LT",
        "Right Shoulder": "RB",
        "Right Trigger": "RT",
        "Left Thumbstick": "LS",
        "Right Thumbstick": "RS"
    ]

    override init(data: Button) {
        super.init(data: data)
        self.setKey(code: data.keyCode, name: data.keyName)
    }

    func save() -> Button {
        data
    }

    override func setKey(code: Int, name: String) {
        var buttonData = data
        buttonData.keyCode = code
        buttonData.keyName = name
        data = buttonData
        updateTitle()
    }

    override func setModifierKey(code: Int) {
        let name = KeyCodeNames.keyCodes[code] ?? "Btn"
        setModifierKey(code: code, name: name)
    }

    override func setModifierKey(name: String) {
        let code = KeyCodeNames.keyCodeByName[name] ?? KeyCodeNames.defaultCode
        setModifierKey(code: code, name: name)
    }

    override func clearModifierKey() {
        var buttonData = data
        buttonData.modifierKeyCode = nil
        buttonData.modifierKeyName = nil
        data = buttonData
        updateTitle()
    }

    override func toggleHoldTrigger() {
        var buttonData = data
        buttonData.holdDuration = buttonData.holdDuration == nil ? Self.defaultHoldDuration : nil
        data = buttonData
        updateTitle()
    }

    private func setModifierKey(code: Int, name: String) {
        var buttonData = data
        buttonData.modifierKeyCode = code
        buttonData.modifierKeyName = name
        data = buttonData
        updateTitle()
    }

    private func updateTitle() {
        let keyName = Self.displayName(for: data.keyName)
        let holdPrefix = data.holdDuration == nil ? "" : "Hold\n"
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle("\(holdPrefix)\(keyName)", for: UIControl.State.normal)
            return
        }
        let modifierName = Self.displayName(for: modifierKeyName)
        button.setTitle("\(holdPrefix)\(modifierName)+\n\(keyName)", for: UIControl.State.normal)
    }

    static func displayName(for keyName: String) -> String {
        shortKeyNames[keyName] ?? keyName
    }
}

class SwipeModel: ControlModel<Swipe> {
    private static let directions: [(name: String, angle: CGFloat)] = [
        ("Right", 0),
        ("Down", CGFloat.pi / 2),
        ("Left", CGFloat.pi),
        ("Up", CGFloat.pi * 3 / 2)
    ]

    override init(data: Swipe) {
        super.init(data: data)
        button.removeFromSuperview()
        button = SwipeElement(
            frame: CGRect(
                x: data.transform.xCoord.absoluteX - data.transform.size.absoluteSize / 2,
                y: data.transform.yCoord.absoluteY - data.transform.size.absoluteSize / 2,
                width: data.transform.size.absoluteSize,
                height: data.transform.size.absoluteSize
            )
        )
        button.model = self
        updateTitle()
    }

    func save() -> Swipe {
        data
    }

    override func setKey(code: Int, name: String) {
        var swipeData = data
        swipeData.keyCode = code
        swipeData.keyName = name
        data = swipeData
        updateTitle()
    }

    override func setModifierKey(code: Int) {
        let name = KeyCodeNames.keyCodes[code] ?? "Btn"
        setModifierKey(code: code, name: name)
    }

    override func setModifierKey(name: String) {
        let code = KeyCodeNames.keyCodeByName[name] ?? KeyCodeNames.defaultCode
        setModifierKey(code: code, name: name)
    }

    override func clearModifierKey() {
        var swipeData = data
        swipeData.modifierKeyCode = nil
        swipeData.modifierKeyName = nil
        data = swipeData
        updateTitle()
    }

    override func toggleHoldTrigger() {
        var swipeData = data
        swipeData.holdDuration = swipeData.holdDuration == nil ? ButtonModel.defaultHoldDuration : nil
        data = swipeData
        updateTitle()
    }

    override func cycleDirection() {
        var swipeData = data
        let currentIndex = Self.nearestDirectionIndex(for: swipeData.angle)
        let nextIndex = (currentIndex + 1) % Self.directions.count
        swipeData.angle = Self.directions[nextIndex].angle
        data = swipeData
        updateTitle()
    }

    private func setModifierKey(code: Int, name: String) {
        var swipeData = data
        swipeData.modifierKeyCode = code
        swipeData.modifierKeyName = name
        data = swipeData
        updateTitle()
    }

    private func updateTitle() {
        let keyName = ButtonModel.displayName(for: data.keyName)
        let direction = Self.directions[Self.nearestDirectionIndex(for: data.angle)].name
        let holdPrefix = data.holdDuration == nil ? "" : "Hold\n"
        let title = "\(holdPrefix)\(direction)\n\(keyName)"
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle(title, for: UIControl.State.normal)
            return
        }
        let modifierName = ButtonModel.displayName(for: modifierKeyName)
        button.setTitle("\(holdPrefix)\(modifierName)+\n\(keyName) \(direction)", for: UIControl.State.normal)
    }

    private static func nearestDirectionIndex(for angle: CGFloat) -> Int {
        let twoPi = CGFloat.pi * 2
        let normalized = angle.truncatingRemainder(dividingBy: twoPi) + (angle < 0 ? twoPi : 0)
        return directions.enumerated().min { lhs, rhs in
            angularDistance(lhs.element.angle, normalized) < angularDistance(rhs.element.angle, normalized)
        }?.offset ?? 0
    }

    private static func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: twoPi)
        return min(distance, twoPi - distance)
    }
}

class RadialSelectorSlotControl: ControlElement {
    let parent: RadialSelectorModel
    let index: Int
    let button: Element

    init(parent: RadialSelectorModel, index: Int) {
        self.parent = parent
        self.index = index
        let target = parent.data.slots[index].target
        self.button = RadialSelectorSlotElement(
            frame: CGRect(
                x: target.xCoord.absoluteX - target.size.absoluteSize / 2,
                y: target.yCoord.absoluteY - target.size.absoluteSize / 2,
                width: target.size.absoluteSize,
                height: target.size.absoluteSize
            )
        )
        self.button.model = self
        updateTitle()
    }

    func move(deltaY: CGFloat, deltaX: CGFloat) {
        var slot = parent.data.slots[index]
        let newX = button.center.x + deltaX
        let newY = button.center.y + deltaY
        if newX > 0 && newX < screen.width {
            slot.target.xCoord = newX.relativeX
        }
        if newY > 0 && newY < screen.height {
            slot.target.yCoord = newY.relativeY
        }
        parent.data.slots[index] = slot
        button.setCenterXY(newX: newX, newY: newY)
    }

    func focus(_ focus: Bool) {
        parent.focusSlot(index: focus ? index : nil)
    }

    func setKey(code: Int) {
        parent.setKey(code: code)
    }

    func setKey(name: String) {
        parent.setKey(name: name)
    }

    func setModifierKey(code: Int) {
        parent.setModifierKey(code: code)
    }

    func setModifierKey(name: String) {
        parent.setModifierKey(name: name)
    }

    func clearModifierKey() {
        parent.clearModifierKey()
    }

    func toggleHoldTrigger() {
        parent.toggleHoldTrigger()
    }

    func cycleDirection() {}

    func resize(down: Bool) {
        let mod = down ? 0.9 : 1 / 0.9
        var slot = parent.data.slots[index]
        slot.target.size = (slot.target.size.absoluteSize * CGFloat(mod)).relativeSize
        parent.data.slots[index] = slot
        refresh()
    }

    func remove() {
        button.removeFromSuperview()
    }

    func refresh() {
        let slot = parent.data.slots[index]
        button.setSize(newSize: slot.target.size.absoluteSize)
        button.setCenterXY(newX: slot.target.xCoord.absoluteX, newY: slot.target.yCoord.absoluteY)
        updateTitle()
    }

    private func updateTitle() {
        let slot = parent.data.slots[index]
        let title = slot.title ?? RadialSelectorModel.defaultSlots[index].title
        button.setTitle(title, for: .normal)
    }
}

class RadialSelectorModel: ControlModel<RadialSelector> {
    static let defaultSlots: [(title: String, angle: CGFloat)] = [
        ("↑", CGFloat.pi * 3 / 2),
        ("↗", CGFloat.pi * 7 / 4),
        ("→", 0),
        ("↘", CGFloat.pi / 4),
        ("↓", CGFloat.pi / 2),
        ("↙", CGFloat.pi * 3 / 4),
        ("←", CGFloat.pi),
        ("↖", CGFloat.pi * 5 / 4)
    ]

    var slotControls = [RadialSelectorSlotControl]()
    private var focusedSlotIndex: Int?

    override init(data: RadialSelector) {
        super.init(data: data)
        button.removeFromSuperview()
        button = RadialSelectorElement(frame: CGRect(
            x: data.transform.xCoord.absoluteX - data.transform.size.absoluteSize / 2,
            y: data.transform.yCoord.absoluteY - data.transform.size.absoluteSize / 2,
            width: data.transform.size.absoluteSize,
            height: data.transform.size.absoluteSize
        ))
        button.model = self
        for index in data.slots.indices {
            slotControls.append(RadialSelectorSlotControl(parent: self, index: index))
        }
        updateTitle()
    }

    static func makeDefaultSlots(center: CGPoint, size: CGFloat) -> [RadialSelectorSlot] {
        let radius = max(size * 0.72, CGFloat(8.5).absoluteSize)
        let slotSize = CGFloat(2.5).absoluteSize
        let inset = slotSize / 2 + 8
        return defaultSlots.map { slot in
            let rawX = center.x + cos(slot.angle) * radius
            let rawY = center.y + sin(slot.angle) * radius
            return RadialSelectorSlot(
                angle: slot.angle,
                target: KeyModelTransform(
                    size: 2.5,
                    xCoord: min(max(rawX, inset), screen.width - inset).relativeX,
                    yCoord: min(max(rawY, inset), screen.height - inset).relativeY
                ),
                title: slot.title,
                enabled: true
            )
        }
    }

    func save() -> RadialSelector {
        data
    }

    override func remove() {
        super.remove()
        slotControls.forEach { $0.remove() }
    }

    override func focus(_ focus: Bool) {
        if !focus {
            focusedSlotIndex = nil
            slotControls.forEach { $0.button.focus(false) }
        }
        button.focus(focus && focusedSlotIndex == nil)
    }

    func focusSlot(index: Int?) {
        focusedSlotIndex = index
        button.focus(index == nil)
        for (slotIndex, slotControl) in slotControls.enumerated() {
            slotControl.button.focus(index == slotIndex)
        }
    }

    override func move(deltaY: CGFloat, deltaX: CGFloat) {
        super.move(deltaY: deltaY, deltaX: deltaX)
        button.update()
    }

    override func setKey(code: Int, name: String) {
        guard KeyCodeNames.isThumbstick(name) else {
            return
        }
        data.keyCode = code
        data.keyName = name
        updateTitle()
    }

    override func setModifierKey(code: Int) {
        setModifierKey(code: code, name: KeyCodeNames.keyCodes[code] ?? "Btn")
    }

    override func setModifierKey(name: String) {
        setModifierKey(code: KeyCodeNames.keyCodeByName[name] ?? KeyCodeNames.defaultCode, name: name)
    }

    override func clearModifierKey() {
        data.modifierKeyCode = nil
        data.modifierKeyName = nil
        updateTitle()
    }

    override func toggleHoldTrigger() {
        data.holdDuration = data.holdDuration == nil ? ButtonModel.defaultHoldDuration : nil
        updateTitle()
    }

    private func setModifierKey(code: Int, name: String) {
        data.modifierKeyCode = code
        data.modifierKeyName = name
        updateTitle()
    }

    func updateTitle() {
        let keyName = ButtonModel.displayName(for: data.keyName)
        let holdPrefix = data.holdDuration == nil ? "" : "Hold\n"
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle("\(holdPrefix)\(keyName)", for: .normal)
            return
        }
        button.setTitle("\(holdPrefix)\(ButtonModel.displayName(for: modifierKeyName))+\n\(keyName)", for: .normal)
    }
}
