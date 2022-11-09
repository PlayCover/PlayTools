//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?
    var menuInit = false

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        PlayInput.shared.initialize()
        PlayMice.shared.initalise()
        DiscordIPC.shared.initialize()
    }

    @objc static public func initMenu(menu: NSObject) {
        if !shared.menuInit {
            shared.menuInit = true
            delay(0.005) {
                guard let menuBuilder = menu as? UIMenuBuilder else { return }

                shared.menuController = MenuController(with: menuBuilder)
                delay(0.005) {
                    UIMenuSystem.main.setNeedsRebuild()
                    UIMenuSystem.main.setNeedsRevalidate()
                }
            }
        }
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
                AKInterface.shared!.terminateApplication()
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }
}
