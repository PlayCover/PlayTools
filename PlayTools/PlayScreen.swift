//
//  ScreenController.swift
//  PlayTools
//

import Foundation
import UIKit
import SwiftUI

let screen = PlayScreen.shared

public class PlayScreen: NSObject {
    @objc public static let shared = PlayScreen()

    var fullscreen: Bool {
        return AKInterface.shared!.isFullscreen
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
        keyWindow?.windowScene
    }

    var nsWindow: NSObject? {
        keyWindow?.nsWindow
    }
}

extension CGFloat {
    var relativeY: CGFloat {
        self / screen.height
    }
    var relativeX: CGFloat {
        self / screen.width
    }
    var relativeSize: CGFloat {
        self / screen.percent
    }
    var absoluteSize: CGFloat {
        self * screen.percent
    }
    var absoluteX: CGFloat {
        self * screen.width
    }
    var absoluteY: CGFloat {
        self * screen.height
    }
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
