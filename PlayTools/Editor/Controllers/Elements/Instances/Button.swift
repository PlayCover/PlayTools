//
//  Button.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class ButtonModel: ControlModel {

    override init(data: ControlData) {
        super.init(data: data)
        self.setKey(codes: data.keyCodes, name: data.keyName)
    }

    func save() -> Button {
        Button(
            keyCode: data.keyCodes[0], keyName: data.keyName,
            transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func setKey(codes: [Int], name: String) {
        data.keyCodes = codes
        data.keyName = name
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }
}
