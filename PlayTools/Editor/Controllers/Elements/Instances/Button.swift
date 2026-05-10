//
//  Button.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class ButtonModel: ControlModel<Button> {

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
        guard let modifierKeyName = data.modifierKeyName, !modifierKeyName.isEmpty else {
            button.setTitle(data.keyName, for: UIControl.State.normal)
            return
        }
        button.setTitle("\(modifierKeyName)+\n\(data.keyName)", for: UIControl.State.normal)
    }
}
