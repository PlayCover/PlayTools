//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

final public class PlayCover: NSObject {

    @objc static let shared = PlayCover()

    var menuController: MenuController?
    var firstTime = true

    private override init() {}

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initialize()
    }

    @objc static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { noti in
            if PlayScreen.shared.nsWindow?.isEqual(noti.object) ?? false {
                AKInterface.shared!.terminateApplication()
            }
        }
    }

    @objc static public func initMenu(menu: NSObject) {
        delay(0.005) {
            guard let menuBuilder = menu as? UIMenuBuilder else { return }

            shared.menuController = MenuController(with: menuBuilder)
            delay(0.005) {
                UIMenuSystem.main.setNeedsRebuild()
                UIMenuSystem.main.setNeedsRevalidate()
            }
        }
    }

    static func delay(_ delay: Double, closure:@escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }

    func processSubviews(of viewOptional: UIView?) {
        if let view = viewOptional {
            for subview in view.subviews {
                print(subview.description)
                processSubviews(of: subview)
            }
        }
    }
}

@objc extension FileManager {
    private static let FOUNDATION = "/System/Library/Frameworks/Foundation.framework/Foundation"

    static func classInit() {
        let originalMethod = class_getInstanceMethod(FileManager.self, #selector(fileExists(atPath:)))
        let swizzledMethod = class_getInstanceMethod(FileManager.self, #selector(hook_fileExists(atPath:)))
        method_exchangeImplementations(originalMethod!, swizzledMethod!)

        let originalMethod3 = class_getInstanceMethod(FileManager.self, #selector(isReadableFile(atPath:)))
        let swizzledMethod3 = class_getInstanceMethod(FileManager.self, #selector(hook_isReadableFile(atPath:)))

        method_exchangeImplementations(originalMethod3!, swizzledMethod3!)
    }

    func hook_fileExists(atPath: String) -> Bool {
        let answer = hook_fileExists(atPath: atPath)
        if atPath.elementsEqual(FileManager.FOUNDATION) {
            return true
        }
        return answer
    }

    func hook_fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let answer = hook_fileExists(atPath: path, isDirectory: isDirectory)
        if path.elementsEqual(FileManager.FOUNDATION) {
            return true
        }
        return answer
    }

    func hook_isReadableFile(atPath path: String) -> Bool {
        let answer = hook_isReadableFile(atPath: path)
        if path.elementsEqual(FileManager.FOUNDATION) {
            return true
        }
        return answer
    }
}
