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
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

class AKPlugin: NSObject, Plugin {
    private static let globalBackChangedNotification = Notification.Name(
        "io.playcover.PlayCover.GlobalBackSettingsChanged"
    )
    private var globalBackSettings = AKGlobalBackSettingsData.load()
    private var globalBackQueryState: ((Bool) -> Int)?
    private var globalBackPerformBack: ((Bool) -> Bool)?
    private var globalHomeQueryState: (() -> Bool)?
    private var globalHomePerformHome: (() -> Bool)?
    private var globalBackMonitorInstalled = false
    private var globalBackPostClickWorkItem: DispatchWorkItem?
    private let globalBackAccessoryByWindow =
        NSMapTable<NSWindow, NSTitlebarAccessoryViewController>.weakToStrongObjects()
    private let globalBackButtonByWindow =
        NSMapTable<NSWindow, AKGlobalBackTitlebarButton>.weakToStrongObjects()
    private let globalHomeButtonByWindow =
        NSMapTable<NSWindow, AKGlobalBackTitlebarButton>.weakToStrongObjects()

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

        self.registerGlobalBackObservers()
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
}

private struct GlobalBackAccessoryViews {
    let container: NSView
    let backButton: AKGlobalBackTitlebarButton
    let homeButton: AKGlobalBackTitlebarButton
    let controller: NSTitlebarAccessoryViewController
}

private struct GlobalBackShortcutSpec {
    let kind: String
    let keyCode: UInt16
    let buttonNumber: Int
    let targetFlags: NSEvent.ModifierFlags
}

struct AKGlobalBackSettingsData: Codable {
    var titlebarBackEnabled: Bool = true
    var onlyWhenNoSidebarBackButton: Bool = true
    var includeTopCloseButtons: Bool = true
    var shortcutEnabled: Bool = true
    var shortcutKind: String = "mouse"
    var shortcutKeyCode: UInt16 = 0
    var shortcutButtonNumber: Int = 3
    var shortcutModifiersRaw: UInt = 0
    var shortcutDisplayName: String = "Mouse Button 4"
    var titlebarHomeEnabled: Bool = true
    var homeShortcutEnabled: Bool = true
    var homeShortcutKind: String = "none"
    var homeShortcutKeyCode: UInt16 = 0
    var homeShortcutButtonNumber: Int = -1
    var homeShortcutModifiersRaw: UInt = 0
    var homeShortcutDisplayName: String = ""

    static var defaultSettings: AKGlobalBackSettingsData { AKGlobalBackSettingsData() }

    static var configURL: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("GlobalBackSettings.plist")
    }

    static func load() -> AKGlobalBackSettingsData {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? PropertyListDecoder().decode(AKGlobalBackSettingsData.self, from: data) else {
            return .defaultSettings
        }
        return decoded
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AKGlobalBackSettingsData.defaultSettings
        titlebarBackEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .titlebarBackEnabled
        ) ?? defaults.titlebarBackEnabled
        onlyWhenNoSidebarBackButton = try container.decodeIfPresent(
            Bool.self, forKey: .onlyWhenNoSidebarBackButton
        ) ?? defaults.onlyWhenNoSidebarBackButton
        includeTopCloseButtons = try container.decodeIfPresent(
            Bool.self, forKey: .includeTopCloseButtons
        ) ?? defaults.includeTopCloseButtons
        shortcutEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .shortcutEnabled
        ) ?? defaults.shortcutEnabled
        shortcutKind = try container.decodeIfPresent(
            String.self, forKey: .shortcutKind
        ) ?? defaults.shortcutKind
        shortcutKeyCode = try container.decodeIfPresent(
            UInt16.self, forKey: .shortcutKeyCode
        ) ?? defaults.shortcutKeyCode
        shortcutButtonNumber = try container.decodeIfPresent(
            Int.self, forKey: .shortcutButtonNumber
        ) ?? defaults.shortcutButtonNumber
        shortcutModifiersRaw = try container.decodeIfPresent(
            UInt.self, forKey: .shortcutModifiersRaw
        ) ?? defaults.shortcutModifiersRaw
        shortcutDisplayName = try container.decodeIfPresent(
            String.self, forKey: .shortcutDisplayName
        ) ?? defaults.shortcutDisplayName
        titlebarHomeEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .titlebarHomeEnabled
        ) ?? defaults.titlebarHomeEnabled
        homeShortcutEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .homeShortcutEnabled
        ) ?? defaults.homeShortcutEnabled
        homeShortcutKind = try container.decodeIfPresent(
            String.self, forKey: .homeShortcutKind
        ) ?? defaults.homeShortcutKind
        homeShortcutKeyCode = try container.decodeIfPresent(
            UInt16.self, forKey: .homeShortcutKeyCode
        ) ?? defaults.homeShortcutKeyCode
        homeShortcutButtonNumber = try container.decodeIfPresent(
            Int.self, forKey: .homeShortcutButtonNumber
        ) ?? defaults.homeShortcutButtonNumber
        homeShortcutModifiersRaw = try container.decodeIfPresent(
            UInt.self, forKey: .homeShortcutModifiersRaw
        ) ?? defaults.homeShortcutModifiersRaw
        homeShortcutDisplayName = try container.decodeIfPresent(
            String.self, forKey: .homeShortcutDisplayName
        ) ?? defaults.homeShortcutDisplayName
    }

    var normalizedModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: shortcutModifiersRaw).intersection([.command, .option, .control, .shift])
    }

    var homeNormalizedModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: homeShortcutModifiersRaw).intersection([.command, .option, .control, .shift])
    }
}

private final class AKGlobalBackTitlebarButton: NSButton {
    var usesPillBackdrop = false {
        didSet {
            if usesPillBackdrop != oldValue {
                updateAppearance()
            }
        }
    }

    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                updateAppearance()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?

    init(
        frame frameRect: NSRect,
        symbolName: String = "chevron.backward",
        accessibilityDescription: String = "Back"
    ) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
            sym.isTemplate = true
            image = sym
        }
        contentTintColor = .labelColor
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        if usesPillBackdrop {
            layer.cornerRadius = 6
            layer.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(isHovered ? 0.92 : 0.72).cgColor
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        } else {
            layer.cornerRadius = 5
            layer.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }
}

extension AKPlugin {
    @objc func setupGlobalBackIntegration(
        queryState: @escaping (Bool) -> Int,
        performBack: @escaping (Bool) -> Bool
    ) {
        runOnMain {
            self.globalBackQueryState = queryState
            self.globalBackPerformBack = performBack
            self.globalBackSettings = AKGlobalBackSettingsData.load()
            self.installGlobalBackMonitorIfNeeded()
            self.refreshGlobalBackUI()
        }
    }

    @objc func setupGlobalHomeIntegration(
        queryHome: @escaping () -> Bool,
        performHome: @escaping () -> Bool
    ) {
        runOnMain {
            self.globalHomeQueryState = queryHome
            self.globalHomePerformHome = performHome
            self.installGlobalBackMonitorIfNeeded()
            self.refreshGlobalBackUI()
        }
    }

    @objc func refreshGlobalBackUI() {
        let work = { [weak self] in
            guard let self else { return }
            for win in NSApplication.shared.windows where self.isMainAppWindow(win) {
                self.updateGlobalBackButton(for: win)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

private extension AKPlugin {
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

    static var akAppSettingsData: AKAppSettingsData? = {
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

    func isPointInTrafficLightArea(_ pointInWindow: NSPoint, window: NSWindow) -> Bool {
        guard hideTitleBarSetting else { return false }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
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

    func registerGlobalBackObservers() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.globalBackChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadGlobalBackSettingsAndRefresh()
        }
        let center = NotificationCenter.default
        for name in [
            NSApplication.didFinishLaunchingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshGlobalBackUI()
            }
        }
    }

    func scheduleDebouncedGlobalBackRefresh() {
        globalBackPostClickWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.globalBackPostClickWorkItem = nil
            self.refreshGlobalBackUI()
        }
        globalBackPostClickWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    func reloadGlobalBackSettingsAndRefresh() {
        globalBackSettings = AKGlobalBackSettingsData.load()
        refreshGlobalBackUI()
    }

    func shortcutTooltip(base: String, enabled: Bool, kind: String, displayName: String) -> String {
        if enabled, kind != "none", !displayName.isEmpty {
            return "\(base) (\(displayName))"
        }
        return base
    }

    func resolveGlobalBackVisibility(for win: NSWindow) -> (showBack: Bool, showHome: Bool) {
        guard win === primaryWindow else { return (false, false) }
        var showBack = false
        if let query = globalBackQueryState {
            let state = query(globalBackSettings.includeTopCloseButtons)
            let hasBack = (state & 1) != 0
            let hasSidebarBack = (state & 2) != 0
            showBack = globalBackSettings.titlebarBackEnabled
                && hasBack
                && (!globalBackSettings.onlyWhenNoSidebarBackButton || !hasSidebarBack)
        }
        var showHome = false
        if let queryHome = globalHomeQueryState {
            showHome = globalBackSettings.titlebarHomeEnabled && queryHome()
        }
        return (showBack, showHome)
    }

    func makeGlobalBackButton(
        symbolName: String,
        accessibilityDescription: String,
        action: Selector
    ) -> AKGlobalBackTitlebarButton {
        let button = AKGlobalBackTitlebarButton(
            frame: NSRect(x: 0, y: 0, width: 28, height: 22),
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    func makeGlobalBackAccessory(for win: NSWindow) -> GlobalBackAccessoryViews {
        if let accessoryVC = globalBackAccessoryByWindow.object(forKey: win),
           let back = globalBackButtonByWindow.object(forKey: win),
           let home = globalHomeButtonByWindow.object(forKey: win) {
            return GlobalBackAccessoryViews(
                container: accessoryVC.view,
                backButton: back,
                homeButton: home,
                controller: accessoryVC
            )
        }

        let hBtn = makeGlobalBackButton(
            symbolName: "house",
            accessibilityDescription: "Home",
            action: #selector(handleTitlebarGlobalHomeClick(_:))
        )
        let bBtn = makeGlobalBackButton(
            symbolName: "chevron.backward",
            accessibilityDescription: "Back",
            action: #selector(handleTitlebarGlobalBackClick(_:))
        )

        let stack = NSStackView(views: [hBtn, bBtn])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 26))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.layoutAttribute = .trailing
        accessoryVC.view = container
        globalBackAccessoryByWindow.setObject(accessoryVC, forKey: win)
        globalHomeButtonByWindow.setObject(hBtn, forKey: win)
        globalBackButtonByWindow.setObject(bBtn, forKey: win)
        return GlobalBackAccessoryViews(
            container: container,
            backButton: bBtn,
            homeButton: hBtn,
            controller: accessoryVC
        )
    }

    func updateGlobalBackButton(for win: NSWindow) {
        guard isMainAppWindow(win) else { return }
        let (showBack, showHome) = resolveGlobalBackVisibility(for: win)
        guard showHome || showBack else {
            if let existingVC = globalBackAccessoryByWindow.object(forKey: win),
               let idx = win.titlebarAccessoryViewControllers.firstIndex(where: { $0 === existingVC }) {
                win.removeTitlebarAccessoryViewController(at: idx)
            }
            return
        }

        let views = makeGlobalBackAccessory(for: win)
        views.homeButton.isHidden = !showHome
        views.backButton.isHidden = !showBack
        views.homeButton.usesPillBackdrop = hideTitleBarSetting
        views.backButton.usesPillBackdrop = hideTitleBarSetting
        views.homeButton.toolTip = shortcutTooltip(
            base: "Home",
            enabled: globalBackSettings.homeShortcutEnabled,
            kind: globalBackSettings.homeShortcutKind,
            displayName: globalBackSettings.homeShortcutDisplayName
        )
        views.backButton.toolTip = shortcutTooltip(
            base: "Back",
            enabled: globalBackSettings.shortcutEnabled,
            kind: globalBackSettings.shortcutKind,
            displayName: globalBackSettings.shortcutDisplayName
        )
        let targetWidth: CGFloat = (showHome && showBack) ? 64 : 34
        if abs(views.container.frame.size.width - targetWidth) > 0.5 {
            views.container.setFrameSize(NSSize(width: targetWidth, height: 26))
        }
        if !win.titlebarAccessoryViewControllers.contains(where: { $0 === views.controller }) {
            win.addTitlebarAccessoryViewController(views.controller)
        }
    }

    @objc func handleTitlebarGlobalBackClick(_ sender: Any?) {
        _ = globalBackPerformBack?(globalBackSettings.includeTopCloseButtons)
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
    }

    @objc func handleTitlebarGlobalHomeClick(_ sender: Any?) {
        _ = globalHomePerformHome?()
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
    }

    func isPointInGlobalBackButton(_ pointInWindow: NSPoint, window: NSWindow) -> Bool {
        for table in [globalBackButtonByWindow, globalHomeButtonByWindow] {
            if let button = table.object(forKey: window),
               button.window === window,
               !button.isHidden {
                let localPoint = button.convert(pointInWindow, from: nil)
                if button.bounds.contains(localPoint) {
                    return true
                }
            }
        }
        return false
    }

    func installGlobalBackMonitorIfNeeded() {
        guard !globalBackMonitorInstalled else { return }
        globalBackMonitorInstalled = true
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleGlobalBackMonitorEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            if self.anyGlobalBackFeatureEnabled,
               let win = event.window,
               win === self.primaryWindow,
               win.isVisible,
               !self.isPointInGlobalBackButton(event.locationInWindow, window: win) {
                self.scheduleDebouncedGlobalBackRefresh()
            }
            return event
        }
    }

    var anyGlobalBackFeatureEnabled: Bool {
        globalBackSettings.titlebarBackEnabled
            || globalBackSettings.titlebarHomeEnabled
            || globalBackSettings.shortcutEnabled
            || globalBackSettings.homeShortcutEnabled
    }

    func matchesShortcutEvent(_ event: NSEvent, spec: GlobalBackShortcutSpec, win: NSWindow) -> Bool {
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch spec.kind {
        case "keyboard":
            return event.type == .keyDown
                && !event.isARepeat
                && event.keyCode == spec.keyCode
                && relevantFlags == spec.targetFlags
        case "mouse":
            guard event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown,
                  event.buttonNumber == spec.buttonNumber,
                  relevantFlags == spec.targetFlags else {
                return false
            }
            let point = event.locationInWindow
            if isPointInTrafficLightArea(point, window: win) || isPointInGlobalBackButton(point, window: win) {
                return false
            }
            if spec.buttonNumber == 0 && relevantFlags.isEmpty && point.y > win.contentLayoutRect.maxY {
                return false
            }
            return true
        default:
            return false
        }
    }

    func tryHandleBackShortcut(_ event: NSEvent, win: NSWindow, relevantFlags: NSEvent.ModifierFlags) -> Bool {
        let spec = GlobalBackShortcutSpec(
            kind: globalBackSettings.shortcutKind,
            keyCode: globalBackSettings.shortcutKeyCode,
            buttonNumber: globalBackSettings.shortcutButtonNumber,
            targetFlags: globalBackSettings.normalizedModifierFlags
        )
        guard globalBackSettings.shortcutEnabled,
              globalBackSettings.shortcutKind != "none",
              matchesShortcutEvent(event, spec: spec, win: win),
              let query = globalBackQueryState else {
            return false
        }
        let includeClose = globalBackSettings.includeTopCloseButtons
        let state = query(includeClose)
        let hasBack = (state & 1) != 0
        let isTextInput = (state & 4) != 0
        if globalBackSettings.shortcutKind == "keyboard",
           isTextInput && relevantFlags.isEmpty && event.keyCode != 53 {
            return false
        }
        guard hasBack else { return false }
        let handled = globalBackPerformBack?(includeClose) ?? false
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
        return handled
    }

    func tryHandleHomeShortcut(_ event: NSEvent, win: NSWindow, relevantFlags: NSEvent.ModifierFlags) -> Bool {
        let spec = GlobalBackShortcutSpec(
            kind: globalBackSettings.homeShortcutKind,
            keyCode: globalBackSettings.homeShortcutKeyCode,
            buttonNumber: globalBackSettings.homeShortcutButtonNumber,
            targetFlags: globalBackSettings.homeNormalizedModifierFlags
        )
        guard globalBackSettings.homeShortcutEnabled,
              globalBackSettings.homeShortcutKind != "none",
              matchesShortcutEvent(event, spec: spec, win: win),
              let queryHome = globalHomeQueryState else {
            return false
        }
        let state = globalBackQueryState?(false) ?? 0
        let isTextInput = (state & 4) != 0
        if globalBackSettings.homeShortcutKind == "keyboard",
           isTextInput && relevantFlags.isEmpty && event.keyCode != 53 {
            return false
        }
        guard queryHome() else { return false }
        let handled = globalHomePerformHome?() ?? false
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
        return handled
    }

    func handleGlobalBackMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window,
              win === primaryWindow,
              win.isVisible else {
            return event
        }
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if tryHandleBackShortcut(event, win: win, relevantFlags: relevantFlags) {
            return nil
        }
        if tryHandleHomeShortcut(event, win: win, relevantFlags: relevantFlags) {
            return nil
        }
        return event
    }
}
