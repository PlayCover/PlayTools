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
        if PlayInput.shouldLockCursor {
            mode.show(!mode.visible)
            return true
        }
        mode.show(true)
        return false
    }

    func setMapping(_ mapped: Bool) {
        if mapped {
            PlayInput.shared.parseKeymap()
        } else {
            show(true)
            PlayInput.shared.invalidate()
        }
        keyboardMapped = mapped
    }

    func show(_ show: Bool) {
        if keyboardMapped {
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
            if PlaySettings.shared.noKMOnInput {
                keyboardMapped = false
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
