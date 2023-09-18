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
        if mode == ControlMode.EDITOR || mode == ControlMode.TEXT_INPUT {
            return false
        }
        if mode == ControlMode.OFF {
            mode.set(ControlMode.CAMERA_ROTATE)

        } else if mode == ControlMode.ARBITRARY_CLICK && ActionDispatcher.cursorHideNecessary {
            mode.set(ControlMode.CAMERA_ROTATE)

        } else if mode == ControlMode.CAMERA_ROTATE {
            if PlaySettings.shared.noKMOnInput {
                mode.set(ControlMode.ARBITRARY_CLICK)
            } else {
                mode.set(ControlMode.OFF)
            }
        }
        // Some people want option key act as touchpad-touchscreen mapper
        return false
    }

    static public func onCmdK() {
        EditorController.shared.switchMode()

        if mode == ControlMode.EDITOR && !EditorController.shared.editorMode {
            mode.set(ControlMode.CAMERA_ROTATE)
            ActionDispatcher.build()
            Toucher.writeLog(logMessage: "editor closed")
        } else if EditorController.shared.editorMode {
            mode.set(ControlMode.EDITOR)
            Toucher.writeLog(logMessage: "editor opened")
        }
    }

    static public func onKeyboardShow() {
        if mode == ControlMode.EDITOR {
            return
        }
        mode.set(ControlMode.TEXT_INPUT)
    }

    static public func onKeyboardHide() {
        if mode == ControlMode.EDITOR {
            return
        }
        mode.set(ControlMode.ARBITRARY_CLICK)
    }
}
