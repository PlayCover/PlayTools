//
//  EventAdapters.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/15.
//

import Foundation

// This is a builder class for event adapters

public class EventAdapters {

    static func keyboard(controlMode: String) -> KeyboardEventAdapter {
        if controlMode == ControlMode.OFF || controlMode == ControlMode.TEXT_INPUT {
            return TransparentKeyboardEventAdapter()

        } else if controlMode == ControlMode.CAMERA_ROTATE || controlMode == ControlMode.ARBITRARY_CLICK {
            return TouchscreenKeyboardEventAdapter()
        } else if controlMode == ControlMode.EDITOR {
            return EditorKeyboardEventAdapter()
        } else {
            Toast.showHint(title: "Control mode switch error",
                           text: ["Cannot find keyboard event adapter for control mode " + controlMode])
            return TransparentKeyboardEventAdapter()
        }
    }

    static func mouse(controlMode: String) -> MouseEventAdapter {
        if controlMode == ControlMode.OFF || controlMode == ControlMode.TEXT_INPUT {
            return TransparentMouseEventAdapter()

        } else if controlMode == ControlMode.CAMERA_ROTATE {
            return CameraControlMouseEventAdapter()

        } else if controlMode == ControlMode.ARBITRARY_CLICK {
            return TouchscreenMouseEventAdapter()

        } else if controlMode == ControlMode.EDITOR {
            return EditorMouseEventAdapter()
        } else {
            Toast.showHint(title: "Control mode switch error",
                           text: ["Cannot find mouse event adapter for control mode " + controlMode])
            return TouchscreenMouseEventAdapter()
        }
    }

    static func controller(controlMode: String) -> ControllerEventAdapter {
        if controlMode == ControlMode.OFF {
            return TransparentControllerEventAdapter()

        } else if controlMode == ControlMode.CAMERA_ROTATE
                    || controlMode == ControlMode.ARBITRARY_CLICK
                    || controlMode == ControlMode.TEXT_INPUT {
            return TouchscreenControllerEventAdapter()
            
        } else if controlMode == ControlMode.EDITOR {
            return EditorControllerEventAdapter()
        } else {
            Toast.showHint(title: "Control mode switch error",
                           text: ["Cannot find controller event adapter for control mode " + controlMode])
            return TouchscreenControllerEventAdapter()
        }
    }
}
