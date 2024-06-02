//
//  Joystick.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class JoystickModel: ControlModel, ParentElement {
    var joystickButtons = [JoystickButtonModel]()

    func save() -> Joystick {
        Joystick(
            upKeyCode: joystickButtons[0].data.keyCodes[0],
            rightKeyCode: joystickButtons[3].data.keyCodes[0],
            downKeyCode: joystickButtons[1].data.keyCodes[0],
            leftKeyCode: joystickButtons[2].data.keyCodes[0],
            keyName: self.data.keyName,
            transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override init(data: ControlData) {
        super.init(data: data)
        button = JoystickElement(frame: CGRect(
            x: data.xCoord.absoluteX - data.size.absoluteSize/2,
            y: data.yCoord.absoluteY - data.size.absoluteSize/2,
            width: data.size.absoluteSize,
            height: data.size.absoluteSize
        ))
        button.model = self
        for keyCode in data.keyCodes {
            // joystick buttons cannot be mapped to controller keys.
            // Instead, map a real joystick to the joystick as a whole.
            joystickButtons.append(JoystickButtonModel(data: ControlData(
                keyCodes: [keyCode], parent: self)))
        }
        self.setKey(name: data.keyName)
        button.update()
    }

    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            unfocusChildren()
        }
    }

    func unfocusChildren() {
        for joystickButton in joystickButtons {
            joystickButton.focus(false)
        }
    }

    override func setKey(codes: [Int], name: String) {
        guard let btn = button as? JoystickElement else {
            Toast.showHint(title: "Joystick setkey error", text: ["View is not JoystickView"])
            return
        }
        if codes[0] < 0 && name != "Keyboard" {
            if name.hasSuffix("tick") {
                self.data.keyName = name
            } else {
                self.data.keyName = "Mouse"
            }
            btn.setKey(showChild: false, name: data.keyName)
        } else {
            self.data.keyName = "Keyboard"
            btn.setKey(showChild: true, name: "")
        }
    }
}
