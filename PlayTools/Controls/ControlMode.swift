//
//  ControlMode.swift
//  PlayTools
//

import Foundation

let mode = ControlMode.mode

public class ControlMode {

    static public let mode = ControlMode()
    public var visible: Bool = true
    public var keyboardMapped = true

    public static func trySwap() -> Bool {
        // this function is called from `AKPlugin` when `option` is pressed.
        if PlayInput.shouldLockCursor {
            mode.show(!mode.visible)
            return true
        }
        mode.show(true)
        return false
    }

    func setMapping(_ mapped: Bool) {
        if mapped {
            // `parseKeymap` and `invalidate` roughly do the opposite thing
            PlayInput.shared.parseKeymap()
        } else {
            // to avoid infinite recursion
            if !visible {
                show(true)
            }
            PlayInput.shared.invalidate()
        }
        keyboardMapped = mapped
    }

    func show(_ show: Bool) {
        // special cases where function of `option` should be temparorily disabled.
        // if the new auto keymapping feature is enabled, it could cause problems to switch
        // cursor show state while typing.
        if (!PlaySettings.shared.noKMOnInput && !editor.editorMode)
        || (PlaySettings.shared.noKMOnInput && keyboardMapped) {
            if show {
                if !visible {
                    NotificationCenter.default.post(name: NSNotification.Name.playtoolsCursorWillShow,
                                                    object: nil, userInfo: [:])
                    if screen.fullscreen {
                        screen.switchDock(true)
                    }
                    AKInterface.shared!.unhideCursor()
                }
            } else {
                if visible {
                    NotificationCenter.default.post(name: NSNotification.Name.playtoolsCursorWillHide,
                                                    object: nil, userInfo: [:])
                    AKInterface.shared!.hideCursor()
                    if screen.fullscreen {
                        screen.switchDock(false)
                    }
                }
            }
            Toucher.writeLog(logMessage: "cursor show switched to \(show)")
            visible = show
            if !PlaySettings.shared.noKMOnInput {
                // we want to set keymapping as the reverse of curosr show status, not always false.
                // as well as do some logic along with it
                setMapping(!show)
            }
        }
    }
}

extension NSNotification.Name {
    public static let playtoolsCursorWillHide: NSNotification.Name
                    = NSNotification.Name("playtools.cursorWillHide")

    public static let playtoolsCursorWillShow: NSNotification.Name
                    = NSNotification.Name("playtools.cursorWillShow")
}
