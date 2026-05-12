//
//  Button.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class ButtonModel: ControlModel<Button> {
    fileprivate static let shortKeyNames = [
        "Button Menu": "Menu",
        "Button Options": "Options",
        "Direction Pad Up": "D-Up",
        "Direction Pad Down": "D-Down",
        "Direction Pad Left": "D-Left",
        "Direction Pad Right": "D-Right",
        "Left Shoulder": "LB",
        "Left Trigger": "LT",
        "Right Shoulder": "RB",
        "Right Trigger": "RT"
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

    private func setModifierKey(code: Int, name: String) {
        var buttonData = data
        buttonData.modifierKeyCode = code
        buttonData.modifierKeyName = name
        data = buttonData
        updateTitle()
    }

    private func updateTitle() {
        let keyName = Self.displayName(for: data.keyName)
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle(keyName, for: UIControl.State.normal)
            return
        }
        let modifierName = Self.displayName(for: modifierKeyName)
        button.setTitle("\(modifierName)+\n\(keyName)", for: UIControl.State.normal)
    }

    fileprivate static func displayName(for keyName: String) -> String {
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
        let title = "\(direction)\n\(keyName)"
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle(title, for: UIControl.State.normal)
            return
        }
        let modifierName = ButtonModel.displayName(for: modifierKeyName)
        button.setTitle("\(modifierName)+\n\(keyName) \(direction)", for: UIControl.State.normal)
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
