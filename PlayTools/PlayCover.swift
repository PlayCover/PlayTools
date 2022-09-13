//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit
import Security
import MetalKit
import WebKit

final public class PlayCover: NSObject {

    @objc static let shared = PlayCover()

    var firstTime = true

    private override init() {}

    @objc static public func launch() {
        quitWhenClose()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initailize()
        appKitPlugin()
    }

    private static func appKitPlugin() {
        /// 1. Form the plugin's bundle URL
        let bundleFileName = "AKInterface.bundle"
        guard let bundleURL = Bundle.main.builtInPlugInsURL?
                                    .appendingPathComponent(bundleFileName) else { return }

        /// 2. Create a bundle instance with the plugin URL
        guard let bundle = Bundle(url: bundleURL) else { return }

        /// 3. Load the bundle and our plugin class
        let className = "AKInterface.MacPlugin"
        guard let pluginClass = bundle.classNamed(className) as? Plugin.Type else { return }

//        /// 3. Load the bundle and the principal class
//        guard let pluginClass = bundle.principalClass as? Plugin.Type else { return }

        /// 4. Create an instance of the plugin class
        let plugin = pluginClass.init()
        plugin.sayHello()
    }

    @objc static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { noti in
            if PlayScreen.shared.nsWindow?.isEqual(noti.object) ?? false {
                // Dynamic.NSApplication.sharedApplication.terminate(self)
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
