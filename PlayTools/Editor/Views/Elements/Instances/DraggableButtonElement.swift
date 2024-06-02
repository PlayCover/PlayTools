//
//  Draggable.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/6/2.
//

import Foundation

class DraggableButtonElement: Element {
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func commonInit() {
        super.commonInit()
        titleEdgeInsets = UIEdgeInsets(top: frame.height / 2, left: 0, bottom: 0, right: 0)
    }

    override func update() {
        super.update()
        guard let child = (model as? DraggableButtonModel)?.childButton?.button else {
//            Toast.showHint(title: "Draggable button view update error",
//                           text: ["failed to obtain child button"])
            return
        }
        let buttonSize = frame.width / 3
        let coord = (frame.width - buttonSize) / 2
        child.frame = CGRect(x: coord, y: coord, width: buttonSize, height: buttonSize)
        child.layer.cornerRadius = 0.5 * child.bounds.size.width
    }
}
