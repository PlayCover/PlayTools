//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?
    private static var windowInitRetryCount = 0
    private static let maxRetries = 10 // Maximum number of retries

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        
        // Configure window for resizing through AKInterface
        if let window = screen.window {
            // Make underlying NSWindow resizable via KVC
            enableWindowResize(window)
            
            // Enable automatic window sizing
            if let hostingWindow = window.value(forKey: "_hostWindow") as? NSObject {
                hostingWindow.setValue(true, forKey: "allowsAutomaticWindowSizeAdjustment")
                hostingWindow.setValue(true, forKey: "allowsResizing")
                hostingWindow.setValue(true, forKey: "allowsAutoResizing")
                
                // Set content size behavior
                hostingWindow.setValue(true, forKey: "preservesContentSizeWhenMovedToActiveSpace")
//                hostingWindow.setValue(NSSize(width: 640, height: 480), forKey: "minContentSize")
            }
            
            // Update window frame to match screen
            if let windowScene = window.windowScene {
                // Remove Catalyst size restrictions to allow free corner dragging
                if let restrictions = windowScene.sizeRestrictions {
                    restrictions.minimumSize = .zero
                    restrictions.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
                }
                // Hide titlebar via UIKit reflection and keep traffic lights
                hideTitleBar(windowScene)
                // Ensure window is resizable
                enableWindowResize(window)

                let screenSize = windowScene.screen.bounds.size
                window.frame = CGRect(origin: window.frame.origin, size: screenSize)
            }
        }
        
        PlayInput.shared.initialize()
        // DiscordIPC.shared.initialize()

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }
        
        // Also listen for window creation
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let win = screen.keyWindow {
                enableWindowResize(win)
                if let ws = win.windowScene {
                    hideTitleBar(ws)
                }
            }
        }

        // Also hide titlebar for new key window
//        if let win = screen.keyWindow, let ws = win.windowScene, #available(macCatalyst 15.0, *) {
//            if let titlebar = ws.titlebar {
//                titlebar.titleVisibility = .hidden
//                titlebar.toolbar = nil
//            }
//        }
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

    // Helper: add resizable style mask to underlying NSWindow via KVC (works on Catalyst without AppKit)
    fileprivate static func enableWindowResize(_ uiWindow: UIWindow?) {
        guard let nsWindow = uiWindow?.nsWindow else { return }
        // NSWindowStyleMaskResizable = 1 << 3
        let resizableBit: UInt64 = 1 << 3
        // NSWindowStyleMaskFullSizeContentView = 1 << 15
        let fullSizeContentViewBit: UInt64 = 1 << 15
        if let maskNumber = nsWindow.value(forKey: "styleMask") as? NSNumber {
            var mask = maskNumber.uint64Value
            var changed = false
            if mask & resizableBit == 0 {
                mask |= resizableBit
                changed = true
            }
            if mask & fullSizeContentViewBit == 0 {
                mask |= fullSizeContentViewBit
                changed = true
            }
            if changed {
                nsWindow.setValue(NSNumber(value: mask), forKey: "styleMask")
            }
        }
        // Hide titlebar but keep traffic lights
        nsWindow.setValue(NSNumber(value: 1), forKey: "titleVisibility") // hidden
        nsWindow.setValue(true, forKey: "titlebarAppearsTransparent")
        nsWindow.setValue(nil, forKey: "toolbar")
    }

    // Helper: hide titlebar while keeping traffic lights using UIKit reflection
    fileprivate static func hideTitleBar(_ scene: UIWindowScene?) {
        guard let scene = scene else { return }
        // Use KVC to access private 'titlebar' property if it exists (macOS 13+)
        if let titlebar = (scene as AnyObject).value(forKey: "titlebar") {
            // 1 == UITitlebarTitleVisibility.hidden
            (titlebar as AnyObject).setValue(1, forKey: "titleVisibility")
            // Remove toolbar to shrink title area
            (titlebar as AnyObject).setValue(nil, forKey: "toolbar")
        }
    }
}
