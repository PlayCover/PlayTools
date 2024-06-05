//
//  Joystick.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/6/2.
//

import Foundation

class JoystickElement: Element {
    func setKey(showChild: Bool, name: String) {
        guard let childButtons = (model as? JoystickModel)?.joystickButtons.map({ controller in
            controller.button }) else { return }
        setTitle(name, for: UIControl.State.normal)
        childButtons.forEach({ view in view.isHidden = !showChild})
    }

    override func update() {
        super.update()
        layer.cornerRadius = 0.3 * bounds.size.width
        let buttonSize = frame.width / 3
        let xCoord1 = (frame.width / 2) - buttonSize / 2
        let yCoord1 = buttonSize / 4.5
        let xCoord2 = (frame.width / 2) - buttonSize / 2
        let yCoord2 = frame.width - buttonSize - buttonSize / 4.5
        guard let childButtons = (model as? JoystickModel)?.joystickButtons.map({ controller in
            controller.button }) else { return }
        let upButton = childButtons[0]
        let downButton = childButtons[1]
        let leftButton = childButtons[2]
        let rightButton = childButtons[3]
        upButton.frame = CGRect(x: xCoord1, y: yCoord1, width: buttonSize, height: buttonSize)
        downButton.frame = CGRect(x: xCoord2, y: yCoord2, width: buttonSize, height: buttonSize)
        leftButton.frame = CGRect(x: yCoord1, y: xCoord1, width: buttonSize, height: buttonSize)
        rightButton.frame = CGRect(x: yCoord2, y: xCoord2, width: buttonSize, height: buttonSize)
        childButtons.forEach({ view in view.layer.cornerRadius = 0.5 * view.bounds.size.width})
    }
}
