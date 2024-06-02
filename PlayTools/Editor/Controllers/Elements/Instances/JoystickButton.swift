//
//  JoystickButton.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class JoystickButtonModel: ControlModel {
    override init(data: ControlData) {
        super.init(data: data)
        self.setKey(codes: data.keyCodes)
        guard let parent = data.parent else {
            Toast.showHint(title: "child button init error", text: ["Cannot obtain parent"])
            return
        }
        parent.button.addSubview(button)
    }

    override func remove() {
        data.parent?.button.removeFromSuperview()
    }

    override func setKey(codes: [Int], name: String) {
        data.keyCodes = codes
        data.keyName = name
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }

    override func move(deltaY: CGFloat, deltaX: CGFloat) {
        data.parent?.button.model?.move(deltaY: deltaY, deltaX: deltaX)
    }

    override func resize(down: Bool) {
        if let parentButton = data.parent?.button {
            parentButton.model?.resize(down: down)
        }
    }

    override func focus(_ focus: Bool) {
        if focus {
            guard let parent = data.parent as? ParentElement else {
                Toast.showHint(title: "Joystickbutton focus error",
                               text: ["button parent is not ParentElement"])
                return
            }
            parent.unfocusChildren()
        }
        super.focus(focus)
    }
}
