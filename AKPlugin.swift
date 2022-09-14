//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import Foundation

class AKPlugin: NSObject, Plugin {
    required override init() {
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        NSApplication.shared.windows.first!.mouseLocationOutsideOfEventStream as CGPoint
    }

    var windowFrame: CGRect {
        NSApplication.shared.windows.first!.frame as CGRect
    }

    var isMainScreenEqualToFirst: Bool {
        return NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        return NSScreen.main!.frame as CGRect
    }

    var isFullscreen: Bool {
        NSApplication.shared.windows.first!.styleMask.contains(.fullScreen)
    }

    func hideCursor() {
        NSCursor.hide()
    }

    func unhideCursor() {
        NSCursor.unhide()
    }

    func terminateApplication() {
        NSApplication.shared.terminate(self)
    }

    func eliminateRedundantKeyPressEvents(_ isVisible: Bool, _ isEditorShowing: Bool, _ cmdPressed: Bool) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if (isVisible && isEditorShowing) || cmdPressed {
                return event
            }
            return nil
        })
    }

    func setupMouseButton(_up: Int, _down: Int, visible: Bool, isEditorMode: Bool, acceptMouseEvents: Bool) -> Int {
        var returnStatus = -1

        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask(rawValue: UInt64(_up)), handler: { event in
            if !visible || acceptMouseEvents {
                returnStatus = 0
                if acceptMouseEvents {
                    return event
                }
                return nil
            } else if isEditorMode {
                if _up == 8 {
                    returnStatus = 2
                } else if _up == 33554432 {
                    returnStatus = 3
                }
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask(rawValue: UInt64(_down)), handler: { event in
            if !visible || acceptMouseEvents {
                returnStatus = 1
                if acceptMouseEvents {
                    return event
                }
                return nil
            }
            return event
        })

        return returnStatus
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }
}
