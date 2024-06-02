//
//  DraggableButton.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class DraggableButtonModel: ControlModel, ParentElement {
    func unfocusChildren() {
        childButton?.focus(false)
    }

    var childButton: JoystickButtonModel?

    func save() -> Button {
        return Button(keyCode: childButton!.data.keyCodes[0], keyName: data.keyName,
                               transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override init(data: ControlData) {
        super.init(data: data)
        button = DraggableButtonElement(frame: CGRect(
            x: data.xCoord.absoluteX - data.size.absoluteSize/2,
            y: data.yCoord.absoluteY - data.size.absoluteSize/2,
            width: data.size.absoluteSize,
            height: data.size.absoluteSize
        ))
        button.model = self
        // temporarily, cannot map controller keys to draggable buttons
        // `data.keyName` is the key for the move area, not that of the button key.
        childButton = JoystickButtonModel(data: ControlData(
            keyCodes: [data.keyCodes[0]], parent: self))
        setKey(name: data.keyName)
        button.update()
    }

    override func setKey(codes: [Int], name: String) {
        let code = codes[0]
        if code == KeyCodeNames.defaultCode {
            // set the parent key
            self.data.keyName = name
            button.setTitle(data.keyName, for: UIControl.State.normal)
        } else {
            // set the child key
            childButton!.setKey(codes: codes)
        }
    }

    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            unfocusChildren()
        }
    }
}
