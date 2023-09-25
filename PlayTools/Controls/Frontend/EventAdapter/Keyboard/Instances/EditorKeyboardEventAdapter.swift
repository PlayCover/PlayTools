//
//  EditorKeyboardEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import GameController

// Keyboard events handler when in editor mode

public class EditorKeyboardEventAdapter: KeyboardEventAdapter {
    private static let FORBIDDEN: [GCKeyCode] = [
        .leftGUI,
        .rightGUI,
        .leftAlt,
        .rightAlt,
        .printScreen
    ]

    public func handleKey(keycode: UInt16, pressed: Bool, isRepeat: Bool) -> Bool {
        if AKInterface.shared!.cmdPressed || !pressed || isRepeat {
            return false
        }
        guard let rawValue = KeyCodeNames.mapNSEventVirtualCodeToGCKeyCodeRawValue[keycode] else {
            return false
        }
        let gcKeyCode = GCKeyCode(rawValue: rawValue)
        if EditorKeyboardEventAdapter.FORBIDDEN.contains(gcKeyCode) {
//                Toast.showHint(title: "Invalid Key", text: ["This key is intentionally forbidden. Keyname: \(name)"])
            return false
        }
        EditorController.shared.setKey(rawValue)
        return true
    }

}
