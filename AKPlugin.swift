//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

// Add a lightweight struct so we can decode only the flag we care about
private struct AKAppSettingsData: Codable {
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

class AKPlugin: NSObject, Plugin {
    private static let hidAxisUsages: Set<Int> = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35]
    private static let hidHatUsage = 0x39

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
    private var hidManager: IOHIDManager?
    private var hidPrimaryDevice: IOHIDDevice?
    private var hidOnConnected: (() -> Void)?
    private var hidOnDisconnected: (() -> Void)?
    private var hidOnButton: ((Int, Bool) -> Void)?
    private var hidOnAxis: ((Int, CGFloat) -> Void)?
    private var hidOnHat: ((Int) -> Void)?

    private static let hidDeviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }
        let plugin = Unmanaged<AKPlugin>.fromOpaque(context).takeUnretainedValue()
        plugin.handleHIDDeviceConnected(device)
    }

    private static let hidDeviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }
        let plugin = Unmanaged<AKPlugin>.fromOpaque(context).takeUnretainedValue()
        plugin.handleHIDDeviceRemoved(device)
    }

    private static let hidInputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }
        let plugin = Unmanaged<AKPlugin>.fromOpaque(context).takeUnretainedValue()
        plugin.handleHIDInputValue(value)
    }

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

    func setupHIDControllerInput(onConnected: @escaping () -> Void,
                                 onDisconnected: @escaping () -> Void,
                                 onButton: @escaping (Int, Bool) -> Void,
                                 onAxis: @escaping (Int, CGFloat) -> Void,
                                 onHat: @escaping (Int) -> Void) {
        hidOnConnected = onConnected
        hidOnDisconnected = onDisconnected
        hidOnButton = onButton
        hidOnAxis = onAxis
        hidOnHat = onHat

        if hidManager != nil {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        IOHIDManagerSetDeviceMatching(manager, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.hidDeviceMatchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.hidDeviceRemovalCallback, context)
        IOHIDManagerRegisterInputValueCallback(manager, Self.hidInputValueCallback, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            return
        }

        hidManager = manager

        // Callbacks are not guaranteed to fire for devices that were already connected before
        // manager registration in all launch paths. Seed initial state proactively.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            if let initialDevice = devices.first(where: { isSupportedControllerDevice($0) }) {
                handleHIDDeviceConnected(initialDevice)
            }
        }
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    /// Convenience instance property that exposes the cached static preference.
    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var aspectRatioSetting: NSSize? {
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

    private func handleHIDDeviceConnected(_ device: IOHIDDevice) {
        if !isSupportedControllerDevice(device) {
            return
        }

        if hidPrimaryDevice == nil {
            hidPrimaryDevice = device
            hidOnConnected?()
        }
    }

    private func handleHIDDeviceRemoved(_ device: IOHIDDevice) {
        guard let primary = hidPrimaryDevice, sameDevice(primary, device) else {
            return
        }
        hidPrimaryDevice = nil
        hidOnDisconnected?()

        if let manager = hidManager,
           let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
           let another = devices.first(where: { isSupportedControllerDevice($0) }) {
            hidPrimaryDevice = another
            hidOnConnected?()
        }
    }

    private func handleHIDInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let primary = hidPrimaryDevice else {
            return
        }
        if !sameDevice(primary, device) {
            return
        }

        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let rawValue = IOHIDValueGetIntegerValue(value)

        switch usagePage {
        case 0x09: // Button page
            hidOnButton?(usage, rawValue != 0)
        case 0x01: // Generic Desktop page
            if usage == 0x39 {
                hidOnHat?(Int(rawValue))
                return
            }
            if [0x30, 0x31, 0x32, 0x33, 0x34, 0x35].contains(usage) {
                let normalized = normalizeAxis(rawValue: rawValue, element: element)
                hidOnAxis?(usage, normalized)
            }
        case 0x0C:
            break
        default:
            break
        }
    }

    private func normalizeAxis(rawValue: CFIndex, element: IOHIDElement) -> CGFloat {
        let logicalMin = IOHIDElementGetLogicalMin(element)
        let logicalMax = IOHIDElementGetLogicalMax(element)
        if logicalMax <= logicalMin {
            return 0
        }

        let clamped = min(max(rawValue, logicalMin), logicalMax)
        let range = Double(logicalMax - logicalMin)
        let shifted = Double(clamped - logicalMin)
        let normalized = (shifted / range) * 2.0 - 1.0
        return CGFloat(normalized)
    }

    private func sameDevice(_ lhs: IOHIDDevice, _ rhs: IOHIDDevice) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func hidDevicePropertyInt(_ device: IOHIDDevice, key: CFString) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, key) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func isSupportedControllerDevice(_ device: IOHIDDevice) -> Bool {
        let usagePage = hidDevicePropertyInt(device, key: kIOHIDPrimaryUsagePageKey as CFString) ?? -1
        let usage = hidDevicePropertyInt(device, key: kIOHIDPrimaryUsageKey as CFString) ?? -1

        if usagePage == 0x01 && (usage == 0x04 || usage == 0x05) {
            return true
        }

        return hasGamepadLikeElements(device)
    }

    private func hasGamepadLikeElements(_ device: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else {
            return false
        }

        var buttonUsages = Set<Int>()
        var axisUsages = Set<Int>()
        var hasHat = false

        for element in elements {
            let type = IOHIDElementGetType(element)
            switch type {
            case kIOHIDElementTypeInput_Button:
                let usagePage = Int(IOHIDElementGetUsagePage(element))
                let usage = Int(IOHIDElementGetUsage(element))
                if usagePage == 0x09 {
                    buttonUsages.insert(usage)
                }
            case kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Axis:
                let usagePage = Int(IOHIDElementGetUsagePage(element))
                let usage = Int(IOHIDElementGetUsage(element))
                if usagePage != 0x01 {
                    continue
                }
                if usage == Self.hidHatUsage {
                    hasHat = true
                } else if Self.hidAxisUsages.contains(usage) {
                    axisUsages.insert(usage)
                }
            default:
                continue
            }
        }

        // Reject non-controller HID devices (headsets, media keys, etc.).
        return buttonUsages.count >= 4 && (axisUsages.count >= 2 || hasHat)
    }
}
