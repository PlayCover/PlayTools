//
//  ControlMode.swift
//  PlayTools
//

import Foundation

let mode = ControlMode.mode

public class ControlMode {

    static public let mode = ControlMode()
    public var visible: Bool = PlaySettings.shared.mouseMapping

    func show(_ show: Bool) {
        if !editor.editorMode {
            if show {
                if !visible {
                    if screen.fullscreen {
                        screen.switchDock(true)
                    }
                    if PlaySettings.shared.mouseMapping {
                        AKInterface.shared!.unhideCursor()
                    }
                    PlayInput.shared.invalidate()
                }
            } else {
                if visible {
                    if PlaySettings.shared.mouseMapping {
                        AKInterface.shared!.hideCursor()
                    }
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
