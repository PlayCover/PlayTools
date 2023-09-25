//
//  TouchscreenKeyboardEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// Keyboard events handler when keyboard mapping is on

public class TouchscreenKeyboardEventAdapter: KeyboardEventAdapter {
    public func handleKey(keycode: UInt16, pressed: Bool, isRepeat: Bool) -> Bool {

        if isRepeat {
            // eat, eat, eat!
            return true
        }

        let name = KeyCodeNames.virtualCodes[keycode] ?? "Btn"
        return ActionDispatcher.dispatch(key: name, pressed: pressed)
    }

}
