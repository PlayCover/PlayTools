//
//  ModeAutomaton.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/17.
//

import Foundation

// This class manages control mode transitions

public class ModeAutomaton {
    static public func onOption() -> Bool {
        if mode == .editor || mode == .textInput {
            return false
        }
        if mode == .off {
            mode.set(.cameraRotate)

        } else if mode == .arbitraryClick && ActionDispatcher.cursorHideNecessary {
            mode.set(.cameraRotate)

        } else if mode == .cameraRotate {
            if PlaySettings.shared.noKMOnInput {
                mode.set(.arbitraryClick)
            } else {
                mode.set(.off)
            }
        }
        // Some people want option key act as touchpad-touchscreen mapper
        return false
    }

    static public func onCmdK() {
        guard settings.keymapping else {
            return
        }

        EditorController.shared.switchMode()

        if mode == .editor && !EditorController.shared.editorMode {
            mode.set(.cameraRotate)
            ActionDispatcher.build()
            Toucher.writeLog(logMessage: "editor closed")
        } else if EditorController.shared.editorMode {
            mode.set(.editor)
            Toucher.writeLog(logMessage: "editor opened")
        }
    }

    static public func onUITextInputBeginEdit() {
        if mode == .editor {
            return
        }
        mode.set(.textInput)
    }

    static public func onUITextInputEndEdit() {
        if mode == .editor {
            return
        }
        mode.set(.arbitraryClick)
    }
}
