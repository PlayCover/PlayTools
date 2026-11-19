//
//  ScreenController.swift
//  PlayTools
//
import Foundation
import UIKit

let screen = PlayScreen.shared
let isInvertFixEnabled = PlaySettings.shared.inverseScreenValues && PlaySettings.shared.adaptiveDisplay
let mainScreenWidth =  !isInvertFixEnabled ? PlaySettings.shared.windowSizeWidth : PlaySettings.shared.windowSizeHeight
let mainScreenHeight = !isInvertFixEnabled ? PlaySettings.shared.windowSizeHeight : PlaySettings.shared.windowSizeWidth
let customScaler = PlaySettings.shared.customScaler

extension CGSize {
    func aspectRatio() -> CGFloat {
        if mainScreenWidth > mainScreenHeight {
            return mainScreenWidth / mainScreenHeight
        } else {
            return mainScreenHeight / mainScreenWidth
        }
    }

    func toAspectRatio() -> CGSize {
        if #available(iOS 16.3, *) {
            return CGSize(width: mainScreenWidth, height: mainScreenHeight)
        } else {
            return CGSize(width: mainScreenHeight, height: mainScreenWidth)
        }
    }

    func toAspectRatioInternal() -> CGSize {
        return CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioDefault() -> CGSize {
        return CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioInternalDefault() -> CGSize {
        return CGSize(width: mainScreenWidth, height: mainScreenHeight)
    }
}

extension CGRect {
    func aspectRatio() -> CGFloat {
        if mainScreenWidth > mainScreenHeight {
            return mainScreenWidth / mainScreenHeight
        } else {
            return mainScreenHeight / mainScreenWidth
        }
    }

    func toAspectRatio(_ multiplier: CGFloat = 1) -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversed() -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }
    func toAspectRatioReversedDefault() -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
}

extension UIScreen {
    static var aspectRatio: CGFloat {
        let count = AKInterface.shared!.screenCount
        if PlaySettings.shared.notch {
            if count == 1 {
                return mainScreenWidth / mainScreenHeight // 1.6 or 1.77777778
            } else {
                if AKInterface.shared!.isMainScreenEqualToFirst {
                    return mainScreenWidth / mainScreenHeight
                }
            }

        }

        let frame = AKInterface.shared!.mainScreenFrame
        return frame.aspectRatio()
    }
}

public class PlayScreen: NSObject {
    @objc public static let shared = PlayScreen()

    private var lastDuoLandscapeActive = false
    private var isHostLiveResizing = false
    private var relayoutWorkItem: DispatchWorkItem?

    private var isDuoIdentity: Bool {
        PlaySettings.shared.layoutIdiom == 3
            || (PlaySettings.shared.deviceModel as String) == "iPhone19,4"
    }

    private var isForcedPhoneAdaptive: Bool {
        let idiom = PlaySettings.shared.layoutIdiom
        return (idiom == 1 || idiom == 3) && PlaySettings.shared.resizableWindow
    }

    func initialize() {
        guard resizable else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            if let window = notification.object as? UIWindow, let windowScene = window.windowScene {
                windowScene.sizeRestrictions?.minimumSize = CGSize(width: 0, height: 0)
                windowScene.sizeRestrictions?.maximumSize = CGSize(width: .max, height: .max)
            }
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowWillStartLiveResizeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.handleHostWindowLiveResizeStart() }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidResizeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.handleHostWindowResize(isEndOfLiveResize: false) }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.handleHostWindowResize(isEndOfLiveResize: true) }
    }

    @objc public static func onWindowLayoutSubviews(_ window: UIWindow) {
        shared.handleWindowLayoutSubviews(window)
    }

    @objc public static func resolvedWindowSafeAreaInsets(
        _ original: UIEdgeInsets, window: UIWindow
    ) -> UIEdgeInsets {
        guard Thread.isMainThread, shared.isUnfoldedDuoLandscape(for: window) else { return original }
        return UIEdgeInsets(
            top: original.top, left: original.left, bottom: original.bottom,
            right: Swift.max(original.right, 16)
        )
    }

    @objc public static func resolvedInterfaceOrientation(
        _ original: UIInterfaceOrientation, scene: UIWindowScene?
    ) -> UIInterfaceOrientation {
        guard Thread.isMainThread, PlaySettings.shared.resizableWindow, shared.isDuoIdentity else {
            return original
        }
        let targetWindow = scene?.windows.first(where: { shared.isEligiblePrimaryWindow($0) })
            ?? scene?.windows.first(where: { shared.isAppWindow($0) && !$0.isHidden })
            ?? shared.activePrimaryWindow
        let refSize: CGSize
        if let win = targetWindow, win.bounds.width > 1, win.bounds.height > 1 {
            refSize = win.bounds.size
        } else if let sceneBounds = scene?.coordinateSpace.bounds,
                  sceneBounds.width > 1, sceneBounds.height > 1 {
            refSize = sceneBounds.size
        } else {
            return original
        }
        return refSize.width > refSize.height ? .landscapeRight : .portrait
    }

    @objc public static func resolvedGeometryInterfaceOrientation(
        _ original: UIInterfaceOrientation, coordinateSpaceBounds bounds: CGRect
    ) -> UIInterfaceOrientation {
        guard Thread.isMainThread, PlaySettings.shared.resizableWindow, shared.isDuoIdentity else {
            return original
        }
        if bounds.width > 1, bounds.height > 1 {
            return bounds.width > bounds.height ? .landscapeRight : .portrait
        }
        return resolvedInterfaceOrientation(original, scene: nil)
    }

    @objc public static func resolvedFixedCoordinateSpaceBounds(
        _ original: CGRect, screen: UIScreen?
    ) -> CGRect {
        guard Thread.isMainThread, PlaySettings.shared.resizableWindow, shared.isDuoIdentity,
              let win = shared.activePrimaryWindow, win.bounds.width > 1, win.bounds.height > 1,
              let scene = win.windowScene else { return original }
        if let screen = screen, scene.screen !== screen { return original }
        let activeAppScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter {
            ($0.activationState == .foregroundActive || $0.activationState == .foregroundInactive)
                && $0.windows.contains(where: { shared.isEligiblePrimaryWindow($0) })
        }
        let sceneBounds = scene.coordinateSpace.bounds
        guard activeAppScenes.count <= 1, sceneBounds.width > 1, sceneBounds.height > 1,
              abs(win.bounds.width - sceneBounds.width) <= 2,
              abs(win.bounds.height - sceneBounds.height) <= 2 else { return original }
        return CGRect(origin: .zero, size: win.bounds.size)
    }

    @objc public static func frame(_ rect: CGRect) -> CGRect { rect.toAspectRatioReversed() }
    @objc public static func bounds(_ rect: CGRect) -> CGRect { rect.toAspectRatio() }
    @objc public static func nativeBounds(_ rect: CGRect) -> CGRect { rect.toAspectRatio(CGFloat(customScaler)) }
    @objc public static func width(_ size: Int) -> Int { size }
    @objc public static func height(_ size: Int) -> Int { Int(size / Int(UIScreen.aspectRatio)) }
    @objc public static func sizeAspectRatio(_ size: CGSize) -> CGSize { size.toAspectRatio() }

    var fullscreen: Bool {
        return AKInterface.shared!.isFullscreen
    }

    var resizable: Bool {
        return PlaySettings.shared.resizableWindow
    }

    @objc public var screenRect: CGRect {
        return UIScreen.main.bounds
    }

    var width: CGFloat {
        screenRect.width
    }

    var height: CGFloat {
        screenRect.height
    }

    var max: CGFloat {
        Swift.max(width, height)
    }

    var percent: CGFloat {
        max / 100.0
    }

    var keyWindow: UIWindow? {
        return UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }
    }

    var windowScene: UIWindowScene? {
        window?.windowScene
    }

    var window: UIWindow? {
        return UIApplication.shared.connectedScenes
            .filter({$0.activationState == .foregroundActive})
            .compactMap({$0 as? UIWindowScene})
            .first?.windows
            .filter({$0.isKeyWindow}).first
    }

    var nsWindow: NSObject? {
        window?.nsWindow
    }

    func switchDock(_ visible: Bool) {
        AKInterface.shared!.setMenuBarVisible(visible)
    }

    // Default calculation
    @objc public static func frameReversedDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioReversedDefault()
    }
    @objc public static func frameDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault()
    }
    @objc public static func boundsDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault()
    }

    @objc public static func nativeBoundsDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault(CGFloat((customScaler)))
    }

    @objc public static func sizeAspectRatioDefault(_ size: CGSize) -> CGSize {
        return size.toAspectRatioDefault()
    }
    @objc public static func frameInternalDefault(_ rect: CGRect) -> CGRect {
            return rect.toAspectRatioDefault()
    }

    private static weak var cachedWindow: UIWindow?
    @objc public static func boundsResizable(_ rect: CGRect) -> CGRect {
        if cachedWindow == nil {
            cachedWindow = PlayScreen.shared.keyWindow
        }
        return cachedWindow?.bounds ?? rect
    }
}

private extension PlayScreen {
    var activePrimaryWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { sceneRank($0.activationState) < sceneRank($1.activationState) }
        return scenes.flatMap(\.windows).filter { isEligiblePrimaryWindow($0) }
            .max { windowScore($0) < windowScore($1) }
    }

    func sceneRank(_ state: UIScene.ActivationState) -> Int {
        state == .foregroundActive ? 0 : (state == .foregroundInactive ? 1 : (state == .background ? 2 : 3))
    }

    func isAppWindow(_ window: UIWindow) -> Bool {
        if window === EditorController.shared.editorWindow { return false }
        let cls = NSStringFromClass(type(of: window))
        return !(cls.contains("Keyboard") || cls.contains("TextEffects") || cls.contains("Snapshot")
            || cls.contains("Menu") || cls.contains("StatusBar") || cls.hasPrefix("_UI"))
    }

    func isEligiblePrimaryWindow(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0.01 && isAppWindow(window)
    }

    func windowScore(_ window: UIWindow) -> Double {
        (window.rootViewController != nil ? 10_000 : 0)
            + (window.isKeyWindow ? 1_000 : 0)
            + (window.windowLevel == .normal ? 500 : 0)
            + Double(window.bounds.width * window.bounds.height) / 1_000_000.0
    }

    func isUnfoldedDuoLandscape(for window: UIWindow) -> Bool {
        guard PlaySettings.shared.resizableWindow, isDuoIdentity else { return false }
        let sceneBounds = window.windowScene?.coordinateSpace.bounds
        let width = window.bounds.width > 1 ? window.bounds.width : (sceneBounds?.width ?? 0)
        let height = window.bounds.height > 1 ? window.bounds.height : (sceneBounds?.height ?? 0)
        return width > height && width >= 600 && isEligiblePrimaryWindow(window)
    }

    func handleWindowLayoutSubviews(_ window: UIWindow) {
        guard PlaySettings.shared.resizableWindow, isEligiblePrimaryWindow(window),
              window === activePrimaryWindow else { return }
        let nowDuoLandscape = isUnfoldedDuoLandscape(for: window)
        guard nowDuoLandscape != lastDuoLandscapeActive else { return }
        lastDuoLandscapeActive = nowDuoLandscape
        window.safeAreaInsetsDidChange()
        window.rootViewController?.viewSafeAreaInsetsDidChange()
        window.setNeedsLayout()
        if !isHostLiveResizing { scheduleFinalAdaptiveLayoutIfNeeded(for: window, delay: 0.05) }
    }

    func handleHostWindowLiveResizeStart() {
        isHostLiveResizing = true
        if isForcedPhoneAdaptive { relayoutWorkItem?.cancel(); relayoutWorkItem = nil }
    }

    func handleHostWindowResize(isEndOfLiveResize: Bool) {
        if isEndOfLiveResize { isHostLiveResizing = false }
        guard isForcedPhoneAdaptive, let win = activePrimaryWindow else { return }
        if isEndOfLiveResize {
            scheduleFinalAdaptiveLayoutIfNeeded(for: win, delay: 0.0)
        } else if !isHostLiveResizing {
            scheduleFinalAdaptiveLayoutIfNeeded(for: win, delay: 0.08)
        } else {
            relayoutWorkItem?.cancel(); relayoutWorkItem = nil
        }
    }

    func scheduleFinalAdaptiveLayoutIfNeeded(for window: UIWindow, delay: TimeInterval) {
        relayoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self = self, !self.isHostLiveResizing,
                  let win = window ?? self.activePrimaryWindow, win === self.activePrimaryWindow else { return }
            win.setNeedsLayout(); win.layoutIfNeeded()
        }
        relayoutWorkItem = item
        if delay <= 0 { DispatchQueue.main.async(execute: item) } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
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
            if uiWindows.contains(self) { return nsWindow as? NSObject }
        }
        return nil
    }
}
