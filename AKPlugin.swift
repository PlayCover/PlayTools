//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Foundation

class AKPlugin: NSObject, Plugin {
    required override init() {
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        if let window = NSApplication.shared.windows.first {
            return window.mouseLocationOutsideOfEventStream as CGPoint
        }
        return CGPoint.zero
    }

    var windowFrame: CGRect {
        if let window = NSApplication.shared.windows.first {
            return window.frame as CGRect
        }
        return CGRect()
    }

    var isMainScreenEqualToFirst: Bool {
        return NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        if let screen = NSScreen.main {
            return screen.frame as CGRect
        }
        return CGRect()
    }

    var isFullscreen: Bool {
        if let window = NSApplication.shared.windows.first {
            return window.styleMask.contains(.fullScreen)
        }
        return false
    }

    func hideCursor() {
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    func unhideCursor() {
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func moveCursor(_ point: CGPoint) {
        guard let window = NSApplication.shared.windows.first else { return }
        guard let screen = NSScreen.main else { return }

        var origin = window.frame.origin
        origin = CGPoint(x: origin.x, y: (screen.frame.height / 2) - origin.y)
        CGWarpMouseCursorPosition(CGPoint(x: point.x + origin.x, y: point.y + origin.y))
    }

    func terminateApplication() {
        NSApplication.shared.terminate(self)
    }

    func eliminateRedundantKeyPressEvents(_ dontIgnore: @escaping() -> Bool) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if dontIgnore() {
                return event
            }
            return nil
        })
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }
}
