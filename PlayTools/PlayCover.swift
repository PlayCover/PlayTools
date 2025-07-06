//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        PlayInput.shared.initialize()
        // DiscordIPC.shared.initialize()

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        // Apply window tweaks after first runloop cycle
        DispatchQueue.main.async {
            if let window = screen.window {
                // enableWindowResize(window)
                hideTitleBar(window.windowScene)

                // Lift any Catalyst size limits so the user can resize freely
                window.windowScene?.sizeRestrictions?.minimumSize = .zero
                window.windowScene?.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                            height: CGFloat.greatestFiniteMagnitude)
            }
        }

        // Re-apply when a new key window becomes active
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification,
                                               object: nil,
                                               queue: .main) { _ in
            if let win = screen.keyWindow {
                enableWindowResize(win)
                hideTitleBar(win.windowScene)
            }
        }
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
                // Step 1: Resign active
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneWillResignActive?(scene)
                    NotificationCenter.default.post(name: UIScene.willDeactivateNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillResignActive?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                                object: UIApplication.shared)

                // Step 2: Enter background
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidEnterBackground?(scene)
                    NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationDidEnterBackground?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                                object: UIApplication.shared)

                // Step 2.5: End UIBackgroundTask
                // There is an expiration handler, but idk how to invoke it. Skip for now.

                // Step 3: Terminate
                UIApplication.shared.delegate?.applicationWillTerminate?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
                                                object: UIApplication.shared)
                DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)

                // Step 3.5: End BGTask
                // BGTask typically runs in another process and is tricky to terminate.
                // It may run into infinite loops, end up silently heating the device up.
                // This actually happens for ToF. Hope future developers can solve this.
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }

    // MARK: – Catalyst window helpers

    /// Ensures the underlying NSWindow is resizable **and** hides the title-bar
    /// while preserving the red/yellow/green traffic lights.
    fileprivate static func enableWindowResize(_ uiWindow: UIWindow?) {
        guard let nsWindow = uiWindow?.nsWindow else { return }

        // 1. Make the window resizable (add the `.resizable` bit)
        let resizableBit: UInt64 = 1 << 3 // NSWindowStyleMaskResizable
        if let maskNum = nsWindow.value(forKey: "styleMask") as? NSNumber {
            var mask = maskNum.uint64Value
            if mask & resizableBit == 0 {
                mask |= resizableBit
                nsWindow.setValue(NSNumber(value: mask), forKey: "styleMask")
            }
        }

        // 2. Hide the title-bar (keep traffic lights)
        nsWindow.setValue(NSNumber(value: 1), forKey: "titleVisibility") // hidden
        nsWindow.setValue(true, forKey: "titlebarAppearsTransparent")
        nsWindow.setValue(nil, forKey: "toolbar")
    }

    /// UIKit-side helper that hides the title-bar via reflection (no AppKit import).
    fileprivate static func hideTitleBar(_ scene: UIWindowScene?) {
        guard let scene = scene else { return }
        if let titlebar = (scene as AnyObject).value(forKey: "titlebar") {
            (titlebar as AnyObject).setValue(1, forKey: "titleVisibility") // hide title text
            (titlebar as AnyObject).setValue(nil, forKey: "toolbar")       // shrink bar height
        }
    }
}
