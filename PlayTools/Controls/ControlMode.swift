//
//  ControlMode.swift
//  PlayTools
//

import Foundation

let mode = ControlMode.mode

public class ControlMode {

    static public let mode = ControlMode()
    public var visible: Bool = true

    func show(_ show: Bool) {
        if !editor.editorMode {
            if show {
                if !visible {
                    if screen.fullscreen {
                        screen.switchDock(true)
                    }
                    AKInterface.shared!.unhideCursor()
//                    PlayInput.shared.invalidate()
                }
            } else {
                if visible {
                    AKInterface.shared!.hideCursor()
                    if screen.fullscreen {
                        screen.switchDock(false)
                    }

                    PlayInput.shared.setup()
                }
            }
            visible = show
        }
    }
}
