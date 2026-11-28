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

// Add a lightweight struct so we can decode only the flags we care about
private struct AKAppSettingsData: Codable {
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioType: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
    var sdkShift: Bool?
}

private struct AKAspectSpec {
    let width: CGFloat
    let height: CGFloat
    let minW: CGFloat
    let minH: CGFloat
}

private struct AKAppLayoutInfo {
    let families: [Int]
    let supportsIPad: Bool
    let supportsDuoAdaptive: Bool
    let requiresFullScreen: Bool
    let hasPortrait: Bool
    let hasLandscape: Bool
    let hasScene: Bool
    let isAdaptive: Bool

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let nums = info["UIDeviceFamily"] as? [NSNumber] {
            families = nums.map { $0.intValue }
        } else {
            families = info["UIDeviceFamily"] as? [Int] ?? [1]
        }
        supportsIPad = families.contains(2)
        let sdk = Self.parseSDKVersion(info["DTSDKName"] as? String)
        supportsDuoAdaptive = families.contains(1) && (sdk.major > 27 || (sdk.major == 27 && sdk.minor >= 1))
        let rawRequiresFullScreen = info["UIRequiresFullScreen"] as? Bool ?? false
        let ignoredFromStr = (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? String)
            ?? (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? NSNumber)?.stringValue
        let ignoredFrom = Self.parseSDKVersion(ignoredFromStr)
        let runtimeVer = ProcessInfo.processInfo.operatingSystemVersion
        let ignoresRequiresFullScreen = ignoredFrom.major > 0
            && (runtimeVer.majorVersion > ignoredFrom.major
                || (runtimeVer.majorVersion == ignoredFrom.major && runtimeVer.minorVersion >= ignoredFrom.minor))
        requiresFullScreen = rawRequiresFullScreen && !ignoresRequiresFullScreen
        let ipadOrients = info["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []
        let iphoneOrients = (info["UISupportedInterfaceOrientations~iphone"] as? [String])
            ?? (info["UISupportedInterfaceOrientations"] as? [String]) ?? []
        let orients = (supportsIPad && !ipadOrients.isEmpty) ? ipadOrients : iphoneOrients
        let fallbackOrient = info["UIInterfaceOrientation"] as? String ?? ""
        hasPortrait = orients.contains { $0.contains("Portrait") }
            || (orients.isEmpty && fallbackOrient.contains("Portrait"))
        hasLandscape = orients.contains { $0.contains("Landscape") }
            || (orients.isEmpty && fallbackOrient.contains("Landscape"))
        hasScene = info["UIApplicationSceneManifest"] != nil
        isAdaptive = (supportsIPad || supportsDuoAdaptive)
            && !requiresFullScreen
            && ((hasPortrait && hasLandscape) || hasScene)
    }

    private static func parseSDKVersion(_ sdkName: String?) -> (major: Int, minor: Int) {
        guard let sdk = sdkName else { return (0, 0) }
        let digits = sdk.drop { !$0.isNumber }
        let parts = digits.split(separator: ".")
        let major = parts.first.flatMap { Int($0) } ?? 0
        let minor = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return (major, minor)
    }

    var recommendedAspect: AKAspectSpec {
        if hasLandscape && !hasPortrait {
            return AKAspectSpec(width: 16, height: 9, minW: 480, minH: 270)
        }
        if supportsIPad && !families.contains(1) {
            return AKAspectSpec(width: 3, height: 4, minW: 360, minH: 480)
        }
        return AKAspectSpec(width: 9, height: 16, minW: 270, minH: 480)
    }
}

class AKPlugin: NSObject, Plugin {
    private static let savedFrameDefaultsKey = "PlayCover.SavedWindowFrame.v1"

    private let layoutInfo = AKAppLayoutInfo()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private var isRestoringSavedFrame = false

    required override init() {
        super.init()
        configureAllWindows()

        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureAllWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.configureAllWindows()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self?.configureAllWindows()
            }
        }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let win = notif.object as? NSWindow else { return }
                self?.configureWindowIfNeeded(win)
            }
        }
        installWindowFrameObservers(on: center)
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        primaryWindow?.mouseLocationOutsideOfEventStream ?? CGPoint()
    }

    var windowFrame: CGRect {
        primaryWindow?.frame ?? CGRect()
    }

    var contentLayoutRect: CGRect {
        primaryWindow?.contentLayoutRect ?? NSApplication.shared.windows.first?.contentLayoutRect ?? CGRect()
    }

    var isMainScreenEqualToFirst: Bool {
        NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? CGRect()
    }

    var isFullscreen: Bool {
        primaryWindow?.styleMask.contains(.fullScreen) ?? false
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
        guard let firstScreen = NSScreen.screens.first else { return }
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

        func isInTrafficLightArea(_ event: NSEvent) -> Bool {
            if self.hideTitleBarSetting == false {
                return false
            }
            guard let win = event.window else { return false }
            let pointInWindow = event.locationInWindow
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
            for type in buttonTypes {
                if let button = win.standardWindowButton(type) {
                    let localPoint = button.convert(pointInWindow, from: nil)
                    if button.bounds.contains(localPoint) {
                        return true
                    }
                }
            }
            return false
        }

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            if isInTrafficLightArea(event) {
                return event
            }

            if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                let contentRect = win.contentLayoutRect
                if event.locationInWindow.y > contentRect.maxY {
                    win.performZoom(nil)
                    return nil
                }
            }

            if let primary = self.primaryWindow, event.window != primary {
                return event
            }
            if consumed(event.buttonNumber, true) {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
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

    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var resolutionSetting: Int { Self.akAppSettingsData?.resolution ?? 2 }
    private var sdkShiftSetting: Bool { Self.akAppSettingsData?.sdkShift ?? false }
    private var aspectRatioSetting: NSSize? {
        guard resolutionSetting == 6 else {
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
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? (Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String) ?? ""
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

extension AKPlugin {
    func applyWindowAspectLock(width: CGFloat, height: CGFloat, minWidth: CGFloat, minHeight: CGFloat) {
        runOnMain {
            guard width > 0, height > 0, let win = self.primaryWindow else { return }
            win.styleMask.insert([.resizable])
            let safeMinW = max(120, minWidth)
            let safeMinH = max(120, minHeight)
            win.contentMinSize = NSSize(width: safeMinW, height: safeMinH)
            win.contentAspectRatio = NSSize(width: width, height: height)

            let screen = win.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let titleOverhead = self.estimatedTitleOverhead(win)
            let maxW = max(safeMinW, floor(visible.width - 16))
            let maxH = max(safeMinH, floor(visible.height - titleOverhead - 16))

            let curRect = win.contentLayoutRect
            let cur = (curRect.width > 1 && curRect.height > 1) ? curRect.size : win.frame.size
            var newW: CGFloat
            var newH: CGFloat
            if height >= width {
                newH = min(max(cur.height, safeMinH), maxH)
                newW = round(newH * (width / height))
                if newW > maxW {
                    newW = maxW
                    newH = round(newW * (height / width))
                }
            } else {
                newW = min(max(cur.width, safeMinW), maxW)
                newH = round(newW * (height / width))
                if newH > maxH {
                    newH = maxH
                    newW = round(newH * (width / height))
                }
            }
            win.setContentSize(NSSize(width: max(safeMinW, newW), height: max(safeMinH, newH)))
            self.clampWindow(win, to: visible, centerIfOutside: true)
        }
    }

    func clearWindowAspectLock(minWidth: CGFloat, minHeight: CGFloat) {
        runOnMain {
            guard let win = self.primaryWindow else { return }
            win.styleMask.insert([.resizable])
            win.contentAspectRatio = .zero
            win.resizeIncrements = NSSize(width: 1, height: 1)
            win.contentMinSize = NSSize(width: max(120, minWidth), height: max(120, minHeight))
        }
    }
}

private extension AKPlugin {
    var primaryWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { isMainAppWindow($0) })
            ?? NSApplication.shared.windows.first
    }

    func isMainAppWindow(_ win: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: win))
        if className.contains("Menu") || className.contains("StatusBar") || className.contains("Tooltip") {
            return false
        }
        return win.canBecomeMain && !win.isSheet
    }

    func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func configureAllWindows() {
        for win in NSApplication.shared.windows {
            configureWindowIfNeeded(win)
        }
    }

    func configureWindowIfNeeded(_ win: NSWindow) {
        guard isMainAppWindow(win) else { return }
        applyAppearanceRules(win)

        if !configuredWindows.contains(win) {
            configuredWindows.add(win)
            applyInitialSizing(win)
        }
    }

    func applyAppearanceRules(_ win: NSWindow) {
        if resolutionSetting == 6 || resolutionSetting == 7 {
            win.styleMask.insert([.resizable])
        } else {
            win.styleMask.remove(.resizable)
        }
        win.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
        win.isMovable = true
        win.isMovableByWindowBackground = true

        if hideTitleBarSetting {
            win.styleMask.insert([.fullSizeContentView])
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.toolbar = nil
            win.title = ""
        }
        if floatingWindowSetting {
            win.level = .floating
        }
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applyInitialSizing(_ win: NSWindow) {
        if restoreSavedWindowFrameIfAvailable(win) {
            return
        }

        let target = win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        if resolutionSetting == 7 {
            let titleOverhead = estimatedTitleOverhead(win)
            let maxW = max(240, floor(visible.width - 24))
            let maxH = max(240, floor(visible.height - titleOverhead - 20))

            if layoutInfo.isAdaptive || sdkShiftSetting {
                win.resizeIncrements = NSSize(width: 1, height: 1)
                win.contentMinSize = NSSize(width: 360, height: 540)
                let initW = max(360, min(920, round(visible.width * 0.68), maxW))
                let initH = max(540, min(780, round(visible.height * 0.82), maxH))
                win.setContentSize(NSSize(width: initW, height: initH))
            } else {
                let aspect = resolvedNonAdaptiveAspect()
                win.contentMinSize = NSSize(width: aspect.minW, height: aspect.minH)
                win.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)
                var targetH = floor(visible.height * 0.82)
                if aspect.height > aspect.width {
                    targetH = min(targetH, 800)
                }
                targetH = min(targetH, maxH)
                var targetW = round(targetH * (aspect.width / aspect.height))
                if targetW > maxW {
                    targetW = maxW
                    targetH = round(targetW * (aspect.height / aspect.width))
                }
                win.setContentSize(NSSize(width: max(aspect.minW, targetW), height: max(aspect.minH, targetH)))
            }
            if let target = target {
                centerAndClampWindow(win, on: target)
            }
        } else if resolutionSetting == 6, let aspectRatio = aspectRatioSetting {
            win.contentAspectRatio = aspectRatio
        }
    }

    func resolvedNonAdaptiveAspect() -> AKAspectSpec {
        if let data = Self.akAppSettingsData,
           (data.resizableAspectRatioType ?? 0) != 0,
           let aspectWidth = data.resizableAspectRatioWidth,
           let aspectHeight = data.resizableAspectRatioHeight,
           aspectWidth > 0, aspectHeight > 0 {
            let ratioW = CGFloat(aspectWidth)
            let ratioH = CGFloat(aspectHeight)
            if aspectWidth == 9 && aspectHeight == 16 {
                return AKAspectSpec(width: 9, height: 16, minW: 270, minH: 480)
            }
            if aspectWidth == 16 && aspectHeight == 9 {
                return AKAspectSpec(width: 16, height: 9, minW: 480, minH: 270)
            }
            if aspectWidth == 3 && aspectHeight == 4 { return AKAspectSpec(width: 3, height: 4, minW: 360, minH: 480) }
            if aspectWidth == 4 && aspectHeight == 3 { return AKAspectSpec(width: 4, height: 3, minW: 480, minH: 360) }
            let minW = ratioW >= ratioH ? round(270 * ratioW / ratioH) : 270
            let minH = ratioH > ratioW ? round(270 * ratioH / ratioW) : 270
            return AKAspectSpec(width: ratioW, height: ratioH, minW: minW, minH: minH)
        }
        return layoutInfo.recommendedAspect
    }

    func estimatedTitleOverhead(_ win: NSWindow) -> CGFloat {
        if hideTitleBarSetting || win.styleMask.contains(.fullSizeContentView) {
            return 0
        }
        let rectH = win.contentLayoutRect.height
        if rectH > 1 && win.frame.height >= rectH {
            return min(64, win.frame.height - rectH)
        }
        return 28
    }

    func centerAndClampWindow(_ win: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let frame = win.frame
        if frame.width > visible.width || frame.height > visible.height {
            let titleOverhead = estimatedTitleOverhead(win)
            let maxW = max(240, floor(visible.width - 16))
            let maxH = max(240, floor(visible.height - titleOverhead - 16))
            let curContent = win.contentLayoutRect.width > 1 ? win.contentLayoutRect.size : frame.size
            var newW = min(curContent.width, maxW)
            var newH = min(curContent.height, maxH)
            if win.contentAspectRatio.width > 0 && win.contentAspectRatio.height > 0 {
                let ratio = win.contentAspectRatio.width / win.contentAspectRatio.height
                newH = min(maxH, round(newW / ratio))
                newW = round(newH * ratio)
            }
            win.setContentSize(NSSize(width: newW, height: newH))
        }
        let updated = win.frame
        var originX = round(visible.origin.x + (visible.width - updated.width) / 2.0)
        var originY = round(visible.origin.y + (visible.height - updated.height) / 2.0)
        originX = max(visible.minX, min(originX, visible.maxX - updated.width))
        originY = max(visible.minY, min(originY, visible.maxY - updated.height))
        win.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    func clampWindow(_ win: NSWindow, to visible: NSRect, centerIfOutside: Bool) {
        let frame = win.frame
        if centerIfOutside && !visible.intersects(frame) {
            var originX = round(visible.origin.x + (visible.width - frame.width) / 2.0)
            var originY = round(visible.origin.y + (visible.height - frame.height) / 2.0)
            originX = max(visible.minX, min(originX, visible.maxX - frame.width))
            originY = max(visible.minY, min(originY, visible.maxY - frame.height))
            win.setFrameOrigin(NSPoint(x: originX, y: originY))
            return
        }
        let originX = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        let originY = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        win.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    func installWindowFrameObservers(on center: NotificationCenter) {
        for name in [
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.willCloseNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let win = notif.object as? NSWindow else { return }
                self?.saveWindowFrameIfAppropriate(win)
            }
        }

        center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] notif in
            guard let win = notif.object as? NSWindow, !win.inLiveResize else { return }
            self?.saveWindowFrameIfAppropriate(win)
        }

        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for win in self.configuredWindows.allObjects {
                self.saveWindowFrameIfAppropriate(win)
            }
        }
    }

    func restoreSavedWindowFrameIfAvailable(_ win: NSWindow) -> Bool {
        guard resolutionSetting == 7 || resolutionSetting == 6,
              let saved = loadSavedWindowFrame(),
              saved.resolution == resolutionSetting else {
            return false
        }
        let target = screenForSavedFrame(saved.frame)
            ?? win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let titleOverhead = estimatedTitleOverhead(win)
        let maxW = max(240, floor(visible.width - 24))
        let maxH = max(240, floor(visible.height - titleOverhead - 20))

        isRestoringSavedFrame = true
        defer { isRestoringSavedFrame = false }

        if resolutionSetting == 7 && (layoutInfo.isAdaptive || sdkShiftSetting) {
            win.resizeIncrements = NSSize(width: 1, height: 1)
            let minW: CGFloat = 360
            let minH: CGFloat = 540
            win.contentMinSize = NSSize(width: minW, height: minH)
            let targetW = min(max(saved.frame.width, minW), visible.width)
            let targetH = min(max(saved.frame.height, minH + titleOverhead), visible.height)
            var clamped = NSRect(origin: saved.frame.origin, size: NSSize(width: targetW, height: targetH))
            clamped.origin.x = max(visible.minX, min(clamped.origin.x, visible.maxX - clamped.width))
            clamped.origin.y = max(visible.minY, min(clamped.origin.y, visible.maxY - clamped.height))
            win.setFrame(clamped, display: true)
            return true
        }

        let aspect: AKAspectSpec
        if resolutionSetting == 7 {
            aspect = resolvedNonAdaptiveAspect()
        } else if let ratio = aspectRatioSetting, ratio.width > 0, ratio.height > 0 {
            aspect = AKAspectSpec(width: ratio.width, height: ratio.height, minW: 240, minH: 240)
        } else {
            aspect = layoutInfo.recommendedAspect
        }
        win.contentMinSize = NSSize(width: aspect.minW, height: aspect.minH)
        win.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)
        let savedContentH = max(aspect.minH, saved.frame.height - titleOverhead)
        var targetH = min(savedContentH, maxH)
        var targetW = round(targetH * (aspect.width / aspect.height))
        if targetW > maxW {
            targetW = maxW
            targetH = round(targetW * (aspect.height / aspect.width))
        }
        win.setContentSize(NSSize(width: max(aspect.minW, targetW), height: max(aspect.minH, targetH)))
        let updated = win.frame
        let originX = max(visible.minX, min(saved.frame.origin.x, visible.maxX - updated.width))
        let originY = max(visible.minY, min(saved.frame.origin.y, visible.maxY - updated.height))
        win.setFrameOrigin(NSPoint(x: originX, y: originY))
        return true
    }

    func saveWindowFrameIfAppropriate(_ win: NSWindow) {
        guard !isRestoringSavedFrame,
              configuredWindows.contains(win),
              isMainAppWindow(win),
              win.isVisible,
              !win.styleMask.contains(.fullScreen) else {
            return
        }
        let frame = win.frame
        guard frame.width >= 200, frame.height >= 200 else { return }
        let payload: [String: Any] = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
            "resolution": resolutionSetting
        ]
        UserDefaults.standard.set(payload, forKey: Self.savedFrameDefaultsKey)
    }

    func loadSavedWindowFrame() -> (frame: NSRect, resolution: Int)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.savedFrameDefaultsKey),
              let originX = (dict["x"] as? NSNumber)?.doubleValue,
              let originY = (dict["y"] as? NSNumber)?.doubleValue,
              let width = (dict["width"] as? NSNumber)?.doubleValue,
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              let res = (dict["resolution"] as? NSNumber)?.intValue,
              width >= 200, height >= 200 else {
            return nil
        }
        return (NSRect(x: originX, y: originY, width: width, height: height), res)
    }

    func screenForSavedFrame(_ frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return NSScreen.screens.max { lhs, rhs in
            let lhsRect = lhs.frame.intersection(frame)
            let rhsRect = rhs.frame.intersection(frame)
            return (lhsRect.width * lhsRect.height) < (rhsRect.width * rhsRect.height)
        }
    }
}
