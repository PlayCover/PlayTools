//
//  ControlMode.swift
//  PlayTools
//

import Foundation

let mode = ControlMode.mode

public class ControlMode {

    static public let mode = ControlMode()
    public var visible: Bool = PlaySettings.shared.mouseMapping

    static public func isMouseClick(_ event: Any) -> Bool {
        return false
        // TODO: Re-implement
        // return [1, 2].contains(Dynamic(event).type.asInt)
    }

    func show(_ show: Bool) {
        if !editor.editorMode {
            if show {
                if !visible {
                    if screen.fullscreen {
                        screen.switchDock(true)
                    }
                    if PlaySettings.shared.mouseMapping {
                        AKInterface.shared!.unhideCursor()
						disableCursor(1)
                    }
                    PlayInput.shared.invalidate()
                }
            } else {
                if visible {
                    if PlaySettings.shared.mouseMapping {
                        AKInterface.shared!.hideCursor()
                        disableCursor(0)
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
