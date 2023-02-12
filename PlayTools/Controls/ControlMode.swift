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
                    NotificationCenter.default.post(name: NSNotification.Name.playtoolsKeymappingWillDisable,
                                                    object: nil, userInfo: [:])
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
                    NotificationCenter.default.post(name: NSNotification.Name.playtoolsKeymappingWillEnable,
                                                    object: nil, userInfo: [:])
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

extension NSNotification.Name {
    public static let playtoolsKeymappingWillEnable: NSNotification.Name
                    = NSNotification.Name("playtools.keymappingWillEnable")
    
    public static let playtoolsKeymappingWillDisable: NSNotification.Name
                    = NSNotification.Name("playtools.keymappingWillDisable")
}
