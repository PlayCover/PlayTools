// swiftlint:disable file_length
//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Foundation

// Add a lightweight struct so we can decode only the flag we care about
private struct AKAppSettingsData: Codable {
    var optionScrollZoom: Bool?
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

class AKPlugin: NSObject, Plugin {
    required override init() {
        super.init()
        if let window = NSApplication.shared.windows.first {
            window.styleMask.insert([.resizable])
            window.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
            window.isMovable = true
            window.isMovableByWindowBackground = true

            if self.hideTitleBarSetting == true {
                window.styleMask.insert([.fullSizeContentView])
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbar = nil
                window.title = ""
            }

            if self.floatingWindowSetting == true {
                window.level = .floating
            }

            if let aspectRatio = self.aspectRatioSetting {
                window.contentAspectRatio = aspectRatio
            }

            NSWindow.allowsAutomaticWindowTabbing = true
        }

        // Apply the same appearance rules to any subsequent windows that may be created
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main) { notif in
                guard let win = notif.object as? NSWindow else { return }
                win.styleMask.insert([.resizable])

                if self.hideTitleBarSetting == true {
                    win.styleMask.insert([.fullSizeContentView])
                    win.titlebarAppearsTransparent = true
                    win.titleVisibility = .hidden
                    win.toolbar = nil
                    win.title = ""
                }

                if self.floatingWindowSetting == true {
                    win.level = .floating
                }

                if let aspectRatio = self.aspectRatioSetting {
                    win.contentAspectRatio = aspectRatio
                }
        }
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        NSApplication.shared.windows.first?.mouseLocationOutsideOfEventStream ?? CGPoint()
    }

    var windowFrame: CGRect {
        NSApplication.shared.windows.first?.frame ?? CGRect()
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

    var cmdPressed: Bool = false
    var cursorHideLevel = 0
    func hideCursor() {
        NSCursor.hide()
        cursorHideLevel += 1
        CGAssociateMouseAndMouseCursorPosition(0)
        warpCursor()
    }

    func hideCursorMove() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func warpCursor() {
        guard let firstScreen = NSScreen.screens.first else {return}
        let frame = windowFrame
        // Convert from NS coordinates to CG coordinates
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: firstScreen.frame.height - frame.midY))
    }

    func unhideCursor() {
        NSCursor.unhide()
        cursorHideLevel -= 1
        if cursorHideLevel <= 0 {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func terminateApplication() {
        NSApplication.shared.terminate(self)
    }

    private var modifierFlag: UInt = 0
    private var optionScrollZoomEndHandler: (() -> Void)?
    private var optionScrollZoomActive = false
    private var optionScrollZoomInstalled = false

    // swiftlint:disable:next function_body_length
    func setupKeyboard(keyboard: @escaping (UInt16, Bool, Bool, Bool) -> Bool,
                       swapMode: @escaping () -> Bool) {
        func checkCmd(modifier: NSEvent.ModifierFlags) -> Bool {
            if modifier.contains(.command) {
                self.cmdPressed = true
                return true
            } else if self.cmdPressed {
                self.cmdPressed = false
            }
            return false
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, true, event.isARepeat,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, false, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let pressed = self.modifierFlag < event.modifierFlags.rawValue
            let changed = self.modifierFlag ^ event.modifierFlags.rawValue
            self.modifierFlag = event.modifierFlags.rawValue
            let changedFlags = NSEvent.ModifierFlags(rawValue: changed)
            if pressed && changedFlags.contains(.option) {
                if swapMode() {
                    return nil
                }
                return event
            }
            let consumed = keyboard(event.keyCode, pressed, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
    }

    func setupMouseMoved(_ mouseMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .otherMouseDragged, .rightMouseDragged]
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            let consumed = mouseMoved(event.deltaX, event.deltaY)
            if consumed {
                return nil
            }
            return event
        })
        // transpass mouse moved event when no button pressed, for traffic light button to light up
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            _ = mouseMoved(event.deltaX, event.deltaY)
            return event
        })
    }

    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool) {
        let downType: NSEvent.EventTypeMask = left ? .leftMouseDown : right ? .rightMouseDown : .otherMouseDown
        let upType: NSEvent.EventTypeMask = left ? .leftMouseUp : right ? .rightMouseUp : .otherMouseUp

        // Helper to detect whether the event is inside any of the window "traffic-light" buttons
        func isInTrafficLightArea(_ event: NSEvent) -> Bool {
            if self.hideTitleBarSetting == false {
                return false
            }
            guard let win = event.window else { return false }
            let pointInWindow = event.locationInWindow
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
            for type in buttonTypes {
                if let button = win.standardWindowButton(type) {
                    let localPoint = button.convert(pointInWindow, from: nil) // convert from window coords
                    if button.bounds.contains(localPoint) {
                        return true
                    }
                }
            }
            return false
        }

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            // Always allow clicks on the window traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                return event
            }

            // Detect double-clicks on the title-bar area (respecting system preference)

            if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                let contentRect = win.contentLayoutRect
                // Title-bar area is the region above contentLayoutRect
                if event.locationInWindow.y > contentRect.maxY {
                    win.performZoom(nil)
                    return nil
                }
            }

            // For traffic light buttons when fullscreen
            if event.window != NSApplication.shared.windows.first! {
                return event
            }
            if consumed(event.buttonNumber, true) {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
            // Always allow releases on the traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                return event
            }
            if consumed(event.buttonNumber, false) {
                return nil
            }
            return event
        })
    }

    func setupScrollWheel(_ onMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.scrollWheel, handler: { event in
            var deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                deltaX *= 16
                deltaY *= 16
            }
            let consumed = onMoved(deltaX, deltaY)
            if consumed {
                return nil
            }
            return event
        })
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    fileprivate static var akAppSettingsData: AKAppSettingsData? = {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let settingsURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AKAppSettingsData.self, from: data) else {
            return nil
        }
        return decoded
    }()
}

private extension AKPlugin {
    var optionScrollZoomSetting: Bool { Self.akAppSettingsData?.optionScrollZoom ?? true }
    var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    var aspectRatioSetting: NSSize? {
        guard Self.akAppSettingsData?.resolution == 6 else {
            return nil
        }
        let width = Self.akAppSettingsData?.resizableAspectRatioWidth ?? 0
        let height = Self.akAppSettingsData?.resizableAspectRatioHeight ?? 0
        guard width > 0 && height > 0 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }
}

extension AKPlugin {
    @objc func setupOptionScrollZoom(
        _ onZoom: @escaping (CGFloat, CGFloat, CGFloat, Bool) -> Bool,
        onEnd: @escaping () -> Void
    ) {
        guard !optionScrollZoomInstalled, optionScrollZoomSetting else { return }
        optionScrollZoomInstalled = true
        optionScrollZoomEndHandler = onEnd

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleOptionScrollWheelEvent(event, onZoom: onZoom)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, self.optionScrollZoomActive, !event.modifierFlags.contains(.option) {
                self.endOptionScrollZoomIfActive()
            }
            return event
        }
        installOptionScrollZoomLifecycleObservers()
    }
}

private extension AKPlugin {
    var primaryWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.canBecomeMain && !$0.isSheet })
            ?? NSApplication.shared.windows.first
    }

    func handleOptionScrollWheelEvent(
        _ event: NSEvent,
        onZoom: (CGFloat, CGFloat, CGFloat, Bool) -> Bool
    ) -> NSEvent? {
        let relevantFlags = event.modifierFlags.intersection([.option, .command, .control])
        guard relevantFlags == .option else {
            endOptionScrollZoomIfActive()
            return event
        }
        if !event.momentumPhase.isEmpty || event.phase == .ended || event.phase == .cancelled {
            if optionScrollZoomActive {
                endOptionScrollZoomIfActive()
                return nil
            }
            return event
        }
        guard let normalizedPoint = normalizedPrimaryContentPoint(for: event) else {
            return event
        }

        var deltaY = event.scrollingDeltaY
        let isPrecise = event.hasPreciseScrollingDeltas
        if !isPrecise && event.isDirectionInvertedFromDevice {
            deltaY = -deltaY
        }
        if abs(deltaY) < 0.0001 {
            return optionScrollZoomActive ? nil : event
        }

        if onZoom(normalizedPoint.x, normalizedPoint.y, deltaY, isPrecise) {
            optionScrollZoomActive = true
            return nil
        }
        return event
    }

    func normalizedPrimaryContentPoint(for event: NSEvent) -> CGPoint? {
        guard let primary = primaryWindow, primary.isVisible, !primary.isMiniaturized else {
            return nil
        }
        let pointInWindow: NSPoint
        if let eventWindow = event.window {
            guard eventWindow === primary else { return nil }
            pointInWindow = event.locationInWindow
        } else {
            pointInWindow = primary.convertPoint(fromScreen: event.locationInWindow)
        }
        if isPointInTrafficLightArea(pointInWindow, window: primary) {
            return nil
        }

        let refRect: NSRect
        if let contentView = primary.contentView,
           contentView.frame.width >= 1,
           contentView.frame.height >= 1 {
            refRect = contentView.frame
        } else if primary.contentLayoutRect.width >= 1 && primary.contentLayoutRect.height >= 1 {
            refRect = primary.contentLayoutRect
        } else {
            refRect = NSRect(origin: .zero, size: primary.frame.size)
        }
        guard refRect.width >= 1, refRect.height >= 1, refRect.contains(pointInWindow) else {
            return nil
        }
        let normalizedX = (pointInWindow.x - refRect.minX) / refRect.width
        let normalizedY = (refRect.maxY - pointInWindow.y) / refRect.height
        return CGPoint(x: normalizedX, y: normalizedY)
    }

    func isPointInTrafficLightArea(_ pointInWindow: NSPoint, window: NSWindow) -> Bool {
        guard hideTitleBarSetting else { return false }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
        for type in buttonTypes {
            if let button = window.standardWindowButton(type) {
                let localPoint = button.convert(pointInWindow, from: nil)
                if button.bounds.contains(localPoint) {
                    return true
                }
            }
        }
        return false
    }

    func installOptionScrollZoomLifecycleObservers() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let self else { return }
                if let win = notif.object as? NSWindow, win !== self.primaryWindow {
                    return
                }
                self.endOptionScrollZoomIfActive()
            }
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.endOptionScrollZoomIfActive()
            }
        }
    }

    func endOptionScrollZoomIfActive() {
        guard optionScrollZoomActive else { return }
        optionScrollZoomActive = false
        optionScrollZoomEndHandler?()
    }
}
