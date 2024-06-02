//
//  ElementController.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/26.
//

import Foundation

class ControlModel {

    var data: ControlData
    var button: Element

    func focus(_ focus: Bool) {
        button.focus(focus)
//        Toast.showHint(title: "Element controller focus")
    }

    init(data: ControlData) {
        button = Element(
            // Notice: data records center coord, not start coord
            frame: CGRect(
                x: data.xCoord.absoluteX - data.size.absoluteSize/2,
                y: data.yCoord.absoluteY - data.size.absoluteSize/2,
                width: data.size.absoluteSize,
                height: data.size.absoluteSize
            )
        )
        self.data = data
        button.model = self
    }

    func remove() {
        self.button.removeFromSuperview()
    }

    func move(deltaY: CGFloat, deltaX: CGFloat) {
        let newX = button.center.x + deltaX
        let newY = button.center.y + deltaY
        if newX > 0 && newX < screen.width {
            data.xCoord = newX.relativeX
        }
        if newY > 0 && newY < screen.height {
            data.yCoord = newY.relativeY
        }
        button.setCenterXY(newX: newX, newY: newY)
    }

    func resize(down: Bool) {
        let mod = down ? 0.9 : 1/0.9
        data.size = (button.frame.width * CGFloat(mod)).relativeSize
        button.setSize(newSize: data.size)
    }

    func setKey(codes: [Int], name: String) {}

    func setKey(codes: [Int]) {
        self.setKey(codes: codes, name: KeyCodeNames.keyCodes[codes[0]] ?? "Btn")
    }

    func setKey(name: String) {
        self.setKey(codes: [KeyCodeNames.defaultCode], name: name)
    }
}
