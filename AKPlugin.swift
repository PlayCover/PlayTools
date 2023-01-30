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
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    func unhideCursor() {
        NSCursor.unhide()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func makeWindowBorderless() {
        if let window = NSApplication.shared.windows.first {
            let titlebarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            var originalFrame = window.frame
            window.styleMask.insert(NSWindow.StyleMask.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setFrame(NSRect(origin: originalFrame.origin, size: CGSize(width: originalFrame.width, height: originalFrame.height + titlebarHeight)), display: true)
        }
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

    func setupMouseButton(_ _up: Int, _ _down: Int, _ dontIgnore: @escaping(Int, Bool, Bool) -> Bool) {
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask(rawValue: UInt64(_up)), handler: { event in
            let isEventWindow = event.window == NSApplication.shared.windows.first!
            if dontIgnore(_up, true, isEventWindow) {
                return event
            }
            return nil
        })
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask(rawValue: UInt64(_down)), handler: { event in
            if dontIgnore(_up, false, true) {
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
