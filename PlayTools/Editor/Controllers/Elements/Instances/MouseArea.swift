//
//  MouseArea.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class MouseAreaModel: ControlModel {
    func save() -> MouseArea {
        MouseArea(keyName: data.keyName,
                  transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    private func setDraggableButton(code: Int) {
        EditorController.shared.removeControl()
        EditorController.shared.addDraggableButton(CGPoint(x: data.xCoord, y: data.yCoord), code)
    }

    override func setKey(codes: [Int], name: String) {
        let code = codes[0]
        if code < 0 {
            if name.hasSuffix("tick") {
                self.data.keyName = name
            } else {
                self.data.keyName = "Mouse"
            }
        } else {
            self.setDraggableButton(code: code)
        }
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }

    override init(data: ControlData) {
        super.init(data: data)
        setKey(name: data.keyName)
    }
}
