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
        // NSCursor.hide()
        // CGAssociateMouseAndMouseCursorPosition(0)
    }

    func unhideCursor() {
        // NSCursor.unhide()
        // CGAssociateMouseAndMouseCursorPosition(1)
    }

    func moveCursor(_ point: CGPoint) {
        var origin = NSApplication.shared.windows.first!.frame.origin
        var windowFrame = NSApplication.shared.windows.first!.frame
        let titlebarHeight = windowFrame.height - NSApplication.shared.windows.first!.contentRect(forFrameRect: windowFrame).height
        origin = CGPoint(x: origin.x, y: (NSScreen.main!.frame.height / 2) - origin.y)
        CGWarpMouseCursorPosition(CGPoint(x: point.x + origin.x, y: point.y + origin.y - titlebarHeight))
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

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }
}
