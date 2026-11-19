// swiftlint:disable file_length
//
//  ScreenController.swift
//  PlayTools
//
import Foundation
import UIKit

let screen = PlayScreen.shared
let isInvertFixEnabled = PlaySettings.shared.inverseScreenValues && PlaySettings.shared.adaptiveDisplay
let mainScreenWidth = !isInvertFixEnabled
    ? PlaySettings.shared.windowSizeWidth
    : PlaySettings.shared.windowSizeHeight
let mainScreenHeight = !isInvertFixEnabled
    ? PlaySettings.shared.windowSizeHeight
    : PlaySettings.shared.windowSizeWidth
let customScaler = PlaySettings.shared.customScaler

extension CGSize {
    func aspectRatio() -> CGFloat {
        mainScreenWidth > mainScreenHeight
            ? mainScreenWidth / mainScreenHeight
            : mainScreenHeight / mainScreenWidth
    }

    func toAspectRatio() -> CGSize {
        if #available(iOS 16.3, *) {
            return CGSize(width: mainScreenWidth, height: mainScreenHeight)
        } else {
            return CGSize(width: mainScreenHeight, height: mainScreenWidth)
        }
    }

    func toAspectRatioInternal() -> CGSize {
        CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioDefault() -> CGSize {
        CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioInternalDefault() -> CGSize {
        CGSize(width: mainScreenWidth, height: mainScreenHeight)
    }
}

extension CGRect {
    func aspectRatio() -> CGFloat {
        mainScreenWidth > mainScreenHeight
            ? mainScreenWidth / mainScreenHeight
            : mainScreenHeight / mainScreenWidth
    }

    func toAspectRatio(_ multiplier: CGFloat = 1) -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversed() -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversedDefault() -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
}

extension UIScreen {
    static var aspectRatio: CGFloat {
        let count = AKInterface.shared!.screenCount
        if PlaySettings.shared.notch {
            if count == 1 || AKInterface.shared!.isMainScreenEqualToFirst {
                return mainScreenWidth / mainScreenHeight
            }
        }
        let frame = AKInterface.shared!.mainScreenFrame
        return frame.aspectRatio()
    }
}

private struct ScreenAppCapabilities {
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
        let forceShift = PlaySettings.shared.dynamicWindowMode && PlaySettings.shared.sdkShift
        let sdk = Self.parseSDKVersion(info["DTSDKName"] as? String)
        supportsDuoAdaptive = forceShift
            || (families.contains(1) && (sdk.major > 27 || (sdk.major == 27 && sdk.minor >= 1)))
        let rawRequiresFullScreen = info["UIRequiresFullScreen"] as? Bool ?? false
        let ignoredFromStr = (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? String)
            ?? (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? NSNumber)?.stringValue
        let ignoredFrom = Self.parseSDKVersion(ignoredFromStr)
        let runtimeVer = ProcessInfo.processInfo.operatingSystemVersion
        let ignoresRequiresFullScreen = ignoredFrom.major > 0
            && (runtimeVer.majorVersion > ignoredFrom.major
                || (runtimeVer.majorVersion == ignoredFrom.major && runtimeVer.minorVersion >= ignoredFrom.minor))
        requiresFullScreen = !forceShift && rawRequiresFullScreen && !ignoresRequiresFullScreen
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
        isAdaptive = forceShift
            || ((supportsIPad || supportsDuoAdaptive)
                && !requiresFullScreen
                && ((hasPortrait && hasLandscape) || hasScene))
    }

    fileprivate static func parseSDKVersion(_ sdkName: String?) -> (major: Int, minor: Int) {
        guard let sdk = sdkName else { return (0, 0) }
        let digits = sdk.drop { !$0.isNumber }
        let parts = digits.split(separator: ".")
        let major = parts.first.flatMap { Int($0) } ?? 0
        let minor = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return (major, minor)
    }
}

enum PlayDisplayMode: Equatable {
    case adaptive
    case scaled(logicalSize: CGSize, ratioW: CGFloat, ratioH: CGFloat)
}

public class PlayScreen: NSObject {
    @objc public static let shared = PlayScreen()

    private let appCapabilities = ScreenAppCapabilities()
    private var displayMode: PlayDisplayMode = .adaptive
    private var lastAdaptiveBounds: CGRect?
    private var lastAdaptiveLayoutSize: CGSize = .zero
    private var isResolvingBounds = false
    private var isApplyingScaledLayout = false
    private var didInitialPlaceWindow = false
    private var didTriggerRuntimeFallback = false
    private var relayoutWorkItem: DispatchWorkItem?
    private var lastRelayoutTime: CFAbsoluteTime = 0
    private var fallbackWorkItem: DispatchWorkItem?
    private var originalWindowBackground: UIColor?
    private var savedRootAutoresizingMask: UIView.AutoresizingMask?
    private var scaledViews = NSHashTable<UIView>.weakObjects()
    private var scaledWindows = NSHashTable<UIWindow>.weakObjects()

    private var shouldAllowRuntimeFallback: Bool {
        PlaySettings.shared.smartAdaptive
            && displayMode == .adaptive
            && !PlaySettings.shared.sdkShift
    }

    override init() {
        super.init()
        displayMode = Self.initialDisplayMode(capabilities: appCapabilities)
    }

    func initialize() {
        guard PlaySettings.shared.dynamicWindowMode else { return }
        let center = NotificationCenter.default
        let handleAppearance: (Notification) -> Void = { [weak self] notif in
            self?.handleSceneOrWindowEvent(notif.object)
        }
        for name in [
            UIWindow.didBecomeKeyNotification,
            UIWindow.didBecomeVisibleNotification,
            UIScene.didActivateNotification,
            UIScene.willConnectNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main, using: handleAppearance)
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidResizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleHostWindowResize()
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleHostWindowResize()
        }
    }

    @objc public static func frame(_ rect: CGRect) -> CGRect { rect.toAspectRatioReversed() }
    @objc public static func bounds(_ rect: CGRect) -> CGRect { rect.toAspectRatio() }
    @objc public static func nativeBounds(_ rect: CGRect) -> CGRect { rect.toAspectRatio(CGFloat(customScaler)) }
    @objc public static func width(_ size: Int) -> Int { size }
    @objc public static func height(_ size: Int) -> Int { Int(size / Int(UIScreen.aspectRatio)) }
    @objc public static func sizeAspectRatio(_ size: CGSize) -> CGSize { size.toAspectRatio() }
    @objc public static func frameReversedDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioReversedDefault() }
    @objc public static func frameDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func boundsDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func nativeBoundsDefault(_ rect: CGRect) -> CGRect {
        rect.toAspectRatioDefault(CGFloat(customScaler))
    }
    @objc public static func sizeAspectRatioDefault(_ size: CGSize) -> CGSize { size.toAspectRatioDefault() }
    @objc public static func frameInternalDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func boundsResizable(_ rect: CGRect) -> CGRect { shared.resolveBoundsResizable(rect) }

    @objc public static func nativeBoundsResizable(_ rect: CGRect) -> CGRect {
        let logical = boundsResizable(rect)
        let scale = shared.effectiveScale
        return CGRect(origin: .zero, size: CGSize(width: logical.width * scale, height: logical.height * scale))
    }

    @objc public static func onWindowLayoutSubviews(_ window: UIWindow) {
        shared.handleWindowLayoutSubviews(window)
    }

    @objc public static func onViewControllerLayout(_ viewController: UIViewController) {
        shared.handleViewControllerLayout(viewController)
    }

    @objc public static func interceptWindowSetFrame(_ window: UIWindow, frame: CGRect) -> Bool {
        shared.handleWindowSetFrame(window, frame: frame)
    }

    @objc public static func interceptWindowSetBounds(_ window: UIWindow, bounds: CGRect) -> Bool {
        shared.handleWindowSetBounds(window, bounds: bounds)
    }

    @objc public static func onWindowWillSetRootViewController(_ window: UIWindow) {
        shared.ensureWindowScaledBeforeRootVC(window)
    }

    @objc public static func onWindow(_ window: UIWindow, didAddSubview subview: UIView) {
        shared.handleWindowDidAddSubview(window, subview: subview)
    }

    @objc public static func resolvedMainBundleInfoValue(
        _ original: Any?,
        forKey key: String
    ) -> Any? {
        guard PlaySettings.shared.dynamicWindowMode,
              PlaySettings.shared.sdkShift else {
            return original
        }
        switch key {
        case "DTSDKName":
            let sdk = ScreenAppCapabilities.parseSDKVersion(original as? String)
            if sdk.major < 27 || (sdk.major == 27 && sdk.minor < 1) {
                return "iphoneos27.2"
            }
            return original
        case "UIRequiresFullScreen":
            return NSNumber(value: false)
        case "UIRequiresFullScreenIgnoredStartingWithVersion":
            return original ?? "27.0"
        default:
            return original
        }
    }

    @objc public static func resolvedMainBundleInfoDictionary(
        _ original: [AnyHashable: Any]?
    ) -> [AnyHashable: Any]? {
        guard PlaySettings.shared.dynamicWindowMode,
              PlaySettings.shared.sdkShift,
              var dict = original else {
            return original
        }
        let sdk = ScreenAppCapabilities.parseSDKVersion(dict["DTSDKName"] as? String)
        if sdk.major < 27 || (sdk.major == 27 && sdk.minor < 1) {
            dict["DTSDKName"] = "iphoneos27.2"
        }
        dict["UIRequiresFullScreen"] = NSNumber(value: false)
        if dict["UIRequiresFullScreenIgnoredStartingWithVersion"] == nil {
            dict["UIRequiresFullScreenIgnoredStartingWithVersion"] = "27.0"
        }
        return dict
    }

    var fullscreen: Bool { AKInterface.shared?.isFullscreen ?? false }
    var resizable: Bool { PlaySettings.shared.resizableWindow }
    @objc public var screenRect: CGRect { UIScreen.main.bounds }
    var width: CGFloat { screenRect.width }
    var height: CGFloat { screenRect.height }
    var max: CGFloat { Swift.max(width, height) }
    var percent: CGFloat { max / 100.0 }

    var activePrimaryWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { sceneRank($0.activationState) < sceneRank($1.activationState) }
        var candidates: [UIWindow] = []
        for scene in scenes {
            for win in scene.windows where isEligiblePrimaryWindow(win) {
                candidates.append(win)
            }
        }
        return candidates.max { windowScore($0) < windowScore($1) }
    }

    var primaryWindowBounds: CGRect? {
        activePrimaryWindow?.bounds
    }

    func windowPoint(forNormalizedContentX normX: CGFloat, y normY: CGFloat) -> CGPoint? {
        guard let win = activePrimaryWindow else {
            return CGPoint(x: normX * screenRect.width, y: normY * screenRect.height)
        }
        if case .scaled = displayMode,
           let sceneBounds = win.windowScene?.coordinateSpace.bounds,
           sceneBounds.width > 1, sceneBounds.height > 1,
           win.frame.width > 1, win.frame.height > 1 {
            let sceneX = normX * sceneBounds.width
            let sceneY = normY * sceneBounds.height
            let winFrame = win.frame
            let point = CGPoint(
                x: (sceneX - winFrame.minX) * (win.bounds.width / winFrame.width),
                y: (sceneY - winFrame.minY) * (win.bounds.height / winFrame.height)
            )
            let inside = point.x >= 0 && point.x <= win.bounds.width
                && point.y >= 0 && point.y <= win.bounds.height
            return inside ? point : nil
        }
        return CGPoint(x: normX * win.bounds.width, y: normY * win.bounds.height)
    }

    var keyWindow: UIWindow? { activePrimaryWindow }
    var windowScene: UIWindowScene? { activePrimaryWindow?.windowScene }
    var window: UIWindow? { activePrimaryWindow }
    var nsWindow: NSObject? { activePrimaryWindow?.nsWindow }

    func switchDock(_ visible: Bool) {
        AKInterface.shared?.setMenuBarVisible(visible)
    }
}

private extension PlayScreen {
    var effectiveScale: CGFloat {
        let raw = PlaySettings.shared.customScaler
        return CGFloat(round(raw > 0 ? raw : 2.0))
    }

    static func initialDisplayMode(capabilities: ScreenAppCapabilities) -> PlayDisplayMode {
        guard PlaySettings.shared.smartAdaptive else {
            return .adaptive
        }
        if capabilities.isAdaptive {
            return .adaptive
        }
        let data = PlaySettings.shared.settingsData
        if data.resizableAspectRatioType != 0,
           data.resizableAspectRatioWidth > 0,
           data.resizableAspectRatioHeight > 0 {
            let ratioW = CGFloat(data.resizableAspectRatioWidth)
            let ratioH = CGFloat(data.resizableAspectRatioHeight)
            return .scaled(
                logicalSize: logicalSizeForRatio(
                    width: data.resizableAspectRatioWidth,
                    height: data.resizableAspectRatioHeight
                ),
                ratioW: ratioW,
                ratioH: ratioH
            )
        }
        if capabilities.hasLandscape && !capabilities.hasPortrait {
            return .scaled(logicalSize: CGSize(width: 1280, height: 720), ratioW: 16, ratioH: 9)
        }
        if capabilities.supportsIPad && !capabilities.families.contains(1) {
            return .scaled(logicalSize: CGSize(width: 768, height: 1024), ratioW: 3, ratioH: 4)
        }
        return .scaled(logicalSize: CGSize(width: 414, height: 736), ratioW: 9, ratioH: 16)
    }

    static func logicalSizeForRatio(width: Int, height: Int) -> CGSize {
        if width == 9 && height == 16 { return CGSize(width: 414, height: 736) }
        if width == 16 && height == 9 { return CGSize(width: 1280, height: 720) }
        if width == 3 && height == 4 { return CGSize(width: 768, height: 1024) }
        if width == 4 && height == 3 { return CGSize(width: 1024, height: 768) }
        let ratio = CGFloat(width) / CGFloat(height)
        if width >= height {
            return CGSize(width: round(720 * ratio), height: 720)
        }
        return CGSize(width: 414, height: round(414 / ratio))
    }

    static func minSizeForRatio(ratioW: CGFloat, ratioH: CGFloat) -> CGSize {
        let wInt = Int(round(ratioW))
        let hInt = Int(round(ratioH))
        if wInt == 9 && hInt == 16 { return CGSize(width: 270, height: 480) }
        if wInt == 16 && hInt == 9 { return CGSize(width: 480, height: 270) }
        if wInt == 3 && hInt == 4 { return CGSize(width: 360, height: 480) }
        if wInt == 4 && hInt == 3 { return CGSize(width: 480, height: 360) }
        if ratioW >= ratioH {
            return CGSize(width: round(270 * ratioW / ratioH), height: 270)
        }
        return CGSize(width: 270, height: round(270 * ratioH / ratioW))
    }

    func resolveBoundsResizable(_ rect: CGRect) -> CGRect {
        if case .scaled(let logicalSize, _, _) = displayMode {
            return CGRect(origin: .zero, size: logicalSize)
        }
        let fallback = lastAdaptiveBounds ?? CGRect(x: 0, y: 0, width: 900, height: 760)
        guard !isResolvingBounds else { return fallback }
        isResolvingBounds = true
        defer { isResolvingBounds = false }

        if let win = activePrimaryWindow, win.bounds.width >= 100, win.bounds.height >= 100 {
            let resolved = CGRect(origin: .zero, size: win.bounds.size)
            lastAdaptiveBounds = resolved
            return resolved
        }
        return fallback
    }

    func sceneRank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        default: return 3
        }
    }

    func isAppWindow(_ window: UIWindow) -> Bool {
        if window === EditorController.shared.editorWindow {
            return false
        }
        let cls = NSStringFromClass(type(of: window))
        if cls.contains("Keyboard") || cls.contains("TextEffects") || cls.contains("Snapshot")
            || cls.contains("Menu") || cls.contains("StatusBar") || cls.hasPrefix("_UI") {
            return false
        }
        return true
    }

    func isEligiblePrimaryWindow(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0.01 && isAppWindow(window)
    }

    func windowScore(_ window: UIWindow) -> Double {
        var score: Double = 0
        if window.rootViewController != nil { score += 10_000 }
        if window.isKeyWindow { score += 1_000 }
        if window.windowLevel == .normal { score += 500 }
        score += Double(window.bounds.width * window.bounds.height) / 1_000_000.0
        return score
    }

    func applySceneSizeRestrictions(for scene: UIWindowScene?) {
        guard let restrictions = scene?.sizeRestrictions else { return }
        switch displayMode {
        case .adaptive:
            restrictions.minimumSize = CGSize(width: 360, height: 540)
            restrictions.maximumSize = CGSize(width: 8000, height: 8000)
        case .scaled(_, let ratioW, let ratioH):
            restrictions.minimumSize = Self.minSizeForRatio(ratioW: ratioW, ratioH: ratioH)
            restrictions.maximumSize = CGSize(width: 8000, height: 8000)
        }
    }

    func handleSceneOrWindowEvent(_ object: Any?) {
        if let scene = object as? UIWindowScene {
            applySceneSizeRestrictions(for: scene)
        } else if let win = object as? UIWindow {
            applySceneSizeRestrictions(for: win.windowScene)
            handleWindowLayoutSubviews(win)
        } else {
            applySceneSizeRestrictions(for: activePrimaryWindow?.windowScene)
        }
        ensureInitialPlacementAndFallback()
    }

    func ensureInitialPlacementAndFallback() {
        if !didInitialPlaceWindow, activePrimaryWindow != nil {
            didInitialPlaceWindow = true
            if PlaySettings.shared.smartAdaptive && displayMode == .adaptive {
                AKInterface.shared?.clearWindowAspectLock(minWidth: 360, minHeight: 540)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.displayMode == .adaptive else { return }
                    AKInterface.shared?.clearWindowAspectLock(minWidth: 360, minHeight: 540)
                }
            }
            if shouldAllowRuntimeFallback {
                scheduleRuntimeFallbackCheck(delay: 0.8)
            }
        }
    }

    func handleHostWindowResize() {
        guard let win = activePrimaryWindow else { return }
        switch displayMode {
        case .adaptive:
            lastAdaptiveBounds = CGRect(origin: .zero, size: win.bounds.size)
            scheduleAdaptiveRelayout(for: win)
            if PlaySettings.shared.smartAdaptive && !didTriggerRuntimeFallback {
                scheduleRuntimeFallbackCheck(delay: 0.8)
            }
        case .scaled(let logicalSize, _, _):
            applyScaledCanvas(to: win, logicalSize: logicalSize)
            DispatchQueue.main.async { [weak self, weak win] in
                guard let self = self, let win = win,
                      case .scaled(let currentLogical, _, _) = self.displayMode else { return }
                self.applyScaledCanvas(to: win, logicalSize: currentLogical)
            }
        }
    }

    func handleWindowSetFrame(_ window: UIWindow, frame: CGRect) -> Bool {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window) else {
            return false
        }
        let container = resolveContainerBounds(for: window, candidate: frame, logicalSize: logicalSize)
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        return true
    }

    func handleWindowSetBounds(_ window: UIWindow, bounds: CGRect) -> Bool {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window) else {
            return false
        }
        let container: CGRect
        if let sceneBounds = window.windowScene?.coordinateSpace.bounds,
           sceneBounds.width > 1, sceneBounds.height > 1 {
            container = sceneBounds
        } else if bounds.width > 1, bounds.height > 1 {
            container = CGRect(origin: .zero, size: bounds.size)
        } else {
            container = CGRect(origin: .zero, size: logicalSize)
        }
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        return true
    }

    func ensureWindowScaledBeforeRootVC(_ window: UIWindow) {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window) else {
            return
        }
        let container = window.windowScene?.coordinateSpace.bounds
            ?? (window.bounds.width > 1 && window.bounds.height > 1
                ? window.bounds : CGRect(origin: .zero, size: logicalSize))
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
    }

    func handleWindowDidAddSubview(_ window: UIWindow, subview: UIView) {
        guard PlaySettings.shared.dynamicWindowMode,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window),
              subview.superview === window else {
            return
        }
        let container = window.windowScene?.coordinateSpace.bounds
            ?? (window.bounds.width > 1 && window.bounds.height > 1
                ? window.bounds : CGRect(origin: .zero, size: logicalSize))
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        clampDirectWindowSubviewIfNeeded(subview, in: window)
    }

    func handleWindowLayoutSubviews(_ window: UIWindow) {
        guard PlaySettings.shared.dynamicWindowMode, isEligiblePrimaryWindow(window) else { return }
        applySceneSizeRestrictions(for: window.windowScene)
        ensureInitialPlacementAndFallback()

        switch displayMode {
        case .scaled(let logicalSize, _, _):
            applyScaledCanvas(to: window, logicalSize: logicalSize)
        case .adaptive:
            if window === activePrimaryWindow {
                resetScaledTransformsIfNeeded(in: window)
                if abs(window.bounds.width - lastAdaptiveLayoutSize.width) > 0.5
                    || abs(window.bounds.height - lastAdaptiveLayoutSize.height) > 0.5 {
                    lastAdaptiveLayoutSize = window.bounds.size
                    lastAdaptiveBounds = CGRect(origin: .zero, size: window.bounds.size)
                    scheduleAdaptiveRelayout(for: window)
                    if PlaySettings.shared.smartAdaptive && !didTriggerRuntimeFallback {
                        scheduleRuntimeFallbackCheck(delay: 0.8)
                    }
                }
            }
        }
    }

    func handleViewControllerLayout(_ viewController: UIViewController) {
        guard PlaySettings.shared.dynamicWindowMode,
              case .scaled(let logicalSize, _, _) = displayMode,
              let win = viewController.viewIfLoaded?.window,
              isEligiblePrimaryWindow(win),
              viewController === win.rootViewController || viewController.viewIfLoaded?.superview === win else {
            return
        }
        applyScaledCanvas(to: win, logicalSize: logicalSize)
    }
}

private extension PlayScreen {
    func resetScaledTransformsIfNeeded(in window: UIWindow) {
        let didTrackScaledViews = scaledViews.allObjects.contains {
            $0.window === window || $0.superview === window
        }
        guard scaledWindows.contains(window)
                || didTrackScaledViews
                || originalWindowBackground != nil else {
            return
        }
        defer { scaledWindows.remove(window) }

        let sceneBounds = window.windowScene?.coordinateSpace.bounds
        let needsWindowReset = window.transform != .identity || (sceneBounds.map {
            $0.width > 1 && $0.height > 1 && (
                abs(window.frame.width - $0.width) > 0.5
                || abs(window.frame.height - $0.height) > 0.5
            )
        } ?? false)
        if needsWindowReset {
            isApplyingScaledLayout = true
            if window.transform != .identity { window.transform = .identity }
            if let sceneBounds = sceneBounds, sceneBounds.width > 1, sceneBounds.height > 1 {
                window.frame = sceneBounds
            }
            isApplyingScaledLayout = false
            window.setNeedsLayout()
        }
        resetChildViewTransformsIfNeeded(in: window)
        if let savedBg = originalWindowBackground {
            window.backgroundColor = savedBg
            originalWindowBackground = nil
        }
    }

    func restoreAutoresizingMask(for view: UIView, isRoot: Bool) {
        if isRoot, let savedMask = savedRootAutoresizingMask {
            view.autoresizingMask = savedMask
            savedRootAutoresizingMask = nil
        } else if view.autoresizingMask.isEmpty {
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    func resetChildViewTransformsIfNeeded(in window: UIWindow) {
        let rootView = window.rootViewController?.view
        for view in scaledViews.allObjects where view.window === window || view.superview === window {
            if view.transform != .identity { view.transform = .identity }
            restoreAutoresizingMask(for: view, isRoot: view === rootView)
            view.frame = view.superview?.bounds ?? window.bounds
            view.setNeedsLayout()
        }
        scaledViews.removeAllObjects()

        if let rootView = rootView {
            let targetFrame = rootView.superview?.bounds ?? window.bounds
            let needsFrameReset = abs(rootView.frame.width - targetFrame.width) > 0.5
                || abs(rootView.frame.height - targetFrame.height) > 0.5
                || abs(rootView.frame.origin.x) > 0.5
                || abs(rootView.frame.origin.y) > 0.5
            if rootView.transform != .identity {
                rootView.transform = .identity
                restoreAutoresizingMask(for: rootView, isRoot: true)
                rootView.frame = targetFrame
                rootView.setNeedsLayout()
            } else if needsFrameReset {
                restoreAutoresizingMask(for: rootView, isRoot: true)
                rootView.frame = targetFrame
                rootView.setNeedsLayout()
            }
        }
        for subview in window.subviews where subview !== rootView {
            clampDirectWindowSubviewIfNeeded(subview, in: window)
        }
    }

    func clampDirectWindowSubviewIfNeeded(_ subview: UIView, in window: UIWindow) {
        if Toast.hintView.contains(subview) || subview is CircleMenu { return }
        let cls = NSStringFromClass(type(of: subview))
        if cls.contains("PlayTools") || cls.contains("Keyboard") { return }

        let rootView = window.rootViewController?.view
        let isRootHost = subview === rootView
            || cls == "UITransitionView"
            || (rootView?.isDescendant(of: subview) ?? false)
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? .zero
        guard isRootHost || subviewNeedsClamping(subview, in: window, sceneBounds: sceneBounds) else { return }

        normalizeSubviewLayout(subview, in: window)
        if isRootHost, let rootView = rootView, rootView.superview === subview {
            clampSceneSizedDirectChildren(of: rootView, sceneBounds: sceneBounds)
        } else if subview === rootView {
            clampSceneSizedDirectChildren(of: subview, sceneBounds: sceneBounds)
        }
    }

    func subviewNeedsClamping(_ subview: UIView, in window: UIWindow, sceneBounds: CGRect) -> Bool {
        let matchesScene = sceneBounds.width > 1 && sceneBounds.height > 1
            && abs(subview.frame.width - sceneBounds.width) <= 6
            && abs(subview.frame.height - sceneBounds.height) <= 6
        let exceedsWindow = subview.frame.width > window.bounds.width + 1
            || subview.frame.height > window.bounds.height + 1
            || subview.frame.maxX > window.bounds.width + 1
            || subview.frame.maxY > window.bounds.height + 1
        return matchesScene || exceedsWindow
    }

    func normalizeSubviewLayout(_ subview: UIView, in window: UIWindow) {
        if subview.transform != .identity {
            subview.transform = .identity
        }
        if !subview.translatesAutoresizingMaskIntoConstraints
            && !window.constraints.contains(where: { $0.firstItem === subview || $0.secondItem === subview }) {
            subview.translatesAutoresizingMaskIntoConstraints = true
        }
        if subview.autoresizingMask.isEmpty {
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        if abs(subview.frame.width - window.bounds.width) > 0.5
            || abs(subview.frame.height - window.bounds.height) > 0.5
            || abs(subview.frame.origin.x) > 0.5
            || abs(subview.frame.origin.y) > 0.5 {
            subview.frame = window.bounds
            subview.setNeedsLayout()
            subview.layoutIfNeeded()
        }
    }

    func clampWindowSubviewsToBounds(_ window: UIWindow) {
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? .zero
        for subview in window.subviews {
            clampDirectWindowSubviewIfNeeded(subview, in: window)
        }
        if let rootView = window.rootViewController?.view {
            clampSceneSizedDirectChildren(of: rootView, sceneBounds: sceneBounds)
        }
    }

    func clampSceneSizedDirectChildren(of parent: UIView, sceneBounds: CGRect) {
        guard parent.bounds.width > 1, parent.bounds.height > 1 else { return }
        for child in parent.subviews
        where !(child is UIScrollView || Toast.hintView.contains(child) || child is CircleMenu) {
            let cls = NSStringFromClass(type(of: child))
            if cls.contains("PlayTools") || cls.contains("Keyboard") { continue }
            let matchesScene = sceneBounds.width > parent.bounds.width + 2
                && abs(child.frame.width - sceneBounds.width) <= 6
                && abs(child.frame.height - sceneBounds.height) <= 6
            let exceedsFull = child.frame.width > parent.bounds.width + 4
                && child.frame.height > parent.bounds.height + 4
            if matchesScene || exceedsFull {
                if child.transform != .identity { child.transform = .identity }
                if child.autoresizingMask.isEmpty {
                    child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                }
                child.frame = parent.bounds
                child.setNeedsLayout()
                child.layoutIfNeeded()
            }
        }
    }

    func resolveContainerBounds(
        for window: UIWindow,
        candidate: CGRect,
        logicalSize: CGSize
    ) -> CGRect {
        let sceneRect = window.windowScene?.coordinateSpace.bounds
        let candidateDiffersFromLogical = abs(candidate.width - logicalSize.width) > 0.5
            || abs(candidate.height - logicalSize.height) > 0.5
        if candidate.width > 1, candidate.height > 1,
           candidate.origin == .zero, candidateDiffersFromLogical {
            return candidate
        }
        if let sceneRect = sceneRect, sceneRect.width > 1, sceneRect.height > 1 {
            return sceneRect
        }
        if candidate.width > 1, candidate.height > 1 {
            return candidate
        }
        return CGRect(origin: .zero, size: logicalSize)
    }

    func applyScaledWindowGeometry(
        to window: UIWindow,
        logicalSize: CGSize,
        containerBounds: CGRect
    ) {
        guard !isApplyingScaledLayout,
              containerBounds.width > 1, containerBounds.height > 1,
              logicalSize.width > 1, logicalSize.height > 1 else { return }

        let targetBounds = CGRect(origin: .zero, size: logicalSize)
        let scale = Swift.min(
            containerBounds.width / logicalSize.width,
            containerBounds.height / logicalSize.height
        )
        let targetCenter = CGPoint(x: containerBounds.midX, y: containerBounds.midY)

        let curScale = hypot(window.transform.a, window.transform.b)
        let needsBounds = abs(window.bounds.width - targetBounds.width) > 0.25
            || abs(window.bounds.height - targetBounds.height) > 0.25
            || abs(window.bounds.origin.x) > 0.25
            || abs(window.bounds.origin.y) > 0.25
        let needsCenter = abs(window.center.x - targetCenter.x) > 0.25
            || abs(window.center.y - targetCenter.y) > 0.25
        let needsScale = abs(curScale - scale) > 0.001
            || abs(window.transform.b) > 0.001
            || abs(window.transform.c) > 0.001

        guard needsBounds || needsCenter || needsScale else { return }

        scaledWindows.add(window)
        isApplyingScaledLayout = true
        defer { isApplyingScaledLayout = false }

        if needsBounds && window.transform != .identity {
            window.transform = .identity
        }
        if needsBounds { window.bounds = targetBounds }
        if needsCenter { window.center = targetCenter }
        if needsScale { window.transform = CGAffineTransform(scaleX: scale, y: scale) }
    }

    func applyScaledCanvas(to window: UIWindow, logicalSize: CGSize) {
        scaledWindows.add(window)
        let didChangeBounds = abs(window.bounds.width - logicalSize.width) > 0.5
            || abs(window.bounds.height - logicalSize.height) > 0.5
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? window.bounds
        let container = (sceneBounds.width > 1 && sceneBounds.height > 1)
            ? sceneBounds
            : CGRect(origin: .zero, size: logicalSize)
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        resetChildViewTransformsIfNeeded(in: window)
        clampWindowSubviewsToBounds(window)
        if let savedBg = originalWindowBackground {
            window.backgroundColor = savedBg
            originalWindowBackground = nil
        }
        if didChangeBounds {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            for subview in window.subviews where !Toast.hintView.contains(subview) && !(subview is CircleMenu) {
                recursivelyRelayout(subview)
            }
            scheduleAdaptiveRelayout(for: window)
        }
    }

    func scheduleAdaptiveRelayout(for window: UIWindow) {
        relayoutWorkItem?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let delay = (now - lastRelayoutTime) < 0.05 ? 0.05 : 0.0
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self = self, let win = window else { return }
            self.lastRelayoutTime = CFAbsoluteTimeGetCurrent()
            if case .scaled = self.displayMode {
                self.clampWindowSubviewsToBounds(win)
            }
            win.setNeedsLayout()
            win.layoutIfNeeded()
            for subview in win.subviews {
                if Toast.hintView.contains(subview) || subview is CircleMenu { continue }
                self.recursivelyRelayout(subview)
            }
        }
        relayoutWorkItem = item
        if delay == 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func recursivelyRelayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if let collection = view as? UICollectionView {
            collection.collectionViewLayout.invalidateLayout()
            collection.setNeedsLayout()
            collection.layoutIfNeeded()
        } else if let table = view as? UITableView {
            table.setNeedsLayout()
            table.layoutIfNeeded()
            for cell in table.visibleCells {
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
        }
        for subview in view.subviews {
            recursivelyRelayout(subview)
        }
    }

    func scheduleRuntimeFallbackCheck(delay: TimeInterval) {
        fallbackWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateRuntimeNonAdaptiveFallback()
        }
        fallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func evaluateRuntimeNonAdaptiveFallback() {
        guard shouldAllowRuntimeFallback,
              !didTriggerRuntimeFallback,
              let win = activePrimaryWindow,
              let rootView = win.rootViewController?.view,
              win.bounds.width >= 100 else { return }

        let overflowFound = hasNonScrollableWidthOverflow(in: rootView, window: win, threshold: 24)
        guard overflowFound else { return }

        didTriggerRuntimeFallback = true
        let useLandscape = appCapabilities.hasLandscape && !appCapabilities.hasPortrait
        let ratioW: CGFloat = useLandscape ? 16 : 9
        let ratioH: CGFloat = useLandscape ? 9 : 16
        let logical = useLandscape ? CGSize(width: 1280, height: 720) : CGSize(width: 414, height: 736)
        let minSize = Self.minSizeForRatio(ratioW: ratioW, ratioH: ratioH)

        displayMode = .scaled(logicalSize: logical, ratioW: ratioW, ratioH: ratioH)
        applySceneSizeRestrictions(for: win.windowScene)
        AKInterface.shared?.applyWindowAspectLock(
            width: ratioW,
            height: ratioH,
            minWidth: minSize.width,
            minHeight: minSize.height
        )
        applyScaledCanvas(to: win, logicalSize: logical)
    }

    func hasNonScrollableWidthOverflow(in view: UIView, window: UIWindow, threshold: CGFloat) -> Bool {
        if view.isHidden || view.alpha <= 0.05 || view.bounds.width < 1 || view.bounds.height < 1 {
            return false
        }
        if !(view.layer.animationKeys()?.isEmpty ?? true) {
            return false
        }
        if isHorizontalScrollOrTabView(view) {
            return false
        }
        let rect = view.convert(view.bounds, to: window)
        let winBounds = window.bounds
        if rect.maxX <= 0 || rect.minX >= winBounds.width {
            return false
        }
        let overlapsVisibly = rect.minX < winBounds.width - 8 && rect.maxX > 8
            && rect.minY < winBounds.height - 4 && rect.maxY > 4
        if overlapsVisibly && rect.width >= 120 && rect.height >= 80 {
            if rect.maxX > winBounds.width + threshold || rect.minX < -threshold {
                return true
            }
        }
        let isBoundedClip = view !== window.rootViewController?.view && view.clipsToBounds
            && rect.minX >= -8 && rect.maxX <= winBounds.width + 8
        if isBoundedClip && rect.width < winBounds.width * 0.92 {
            return false
        }
        for subview in view.subviews
        where hasNonScrollableWidthOverflow(in: subview, window: window, threshold: threshold) {
            return true
        }
        return false
    }

    func isHorizontalScrollOrTabView(_ view: UIView) -> Bool {
        let cls = NSStringFromClass(type(of: view))
        if cls.contains("TabScroll") || cls.contains("QueuingScrollView")
            || cls.contains("PageView") || cls.contains("Pager")
            || cls.contains("Carousel") || cls.contains("Banner") {
            return true
        }
        guard let scrollView = view as? UIScrollView else { return false }
        if isHorizontalScrollCapable(scrollView) {
            return true
        }
        if scrollView.contentInset.left > 1 || scrollView.contentInset.right > 1
            || abs(scrollView.contentOffset.x) > 1 {
            return true
        }
        return scrollView.isScrollEnabled && !(scrollView is UITableView) && scrollView.bounds.height <= 90
    }

    func isHorizontalScrollCapable(_ scrollView: UIScrollView) -> Bool {
        if scrollView.contentSize.width > scrollView.bounds.width + 2 || scrollView.alwaysBounceHorizontal {
            return true
        }
        if let collection = scrollView as? UICollectionView,
           let flow = collection.collectionViewLayout as? UICollectionViewFlowLayout,
           flow.scrollDirection == .horizontal {
            return true
        }
        let cls = NSStringFromClass(type(of: scrollView))
        return cls.contains("QueuingScrollView") || cls.contains("PageView")
            || cls.contains("TabScroll") || cls.contains("Pager")
    }
}

extension CGFloat {
    var relativeY: CGFloat { self / screen.height }
    var relativeX: CGFloat { self / screen.width }
    var relativeSize: CGFloat { self / screen.percent }
    var absoluteSize: CGFloat { self * screen.percent }
    var absoluteX: CGFloat { self * screen.width }
    var absoluteY: CGFloat { self * screen.height }
}

extension UIWindow {
    var nsWindow: NSObject? {
        guard let nsWindows = NSClassFromString("NSApplication")?
            .value(forKeyPath: "sharedApplication.windows") as? [AnyObject] else { return nil }
        for nsWindow in nsWindows {
            let uiWindows = nsWindow.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []
            if uiWindows.contains(self) {
                return nsWindow as? NSObject
            }
        }
        return nil
    }
}
