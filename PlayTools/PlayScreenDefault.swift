////
////  ScreenController.swift
////  PlayTools
////
//import Foundation
//import UIKit
//
//let screenDefault = PlayScreenDefault.shared
//let mainScreenWidthDefault = PlaySettings.shared.windowSizeWidth
//let mainScreenHeightDefault = PlaySettings.shared.windowSizeHeight
//
//extension CGSize {
//    func aspectRatioDefault() -> CGFloat {
//        if mainScreenWidthDefault > mainScreenHeightDefault {
//            return mainScreenWidthDefault / mainScreenHeightDefault
//        } else {
//            return mainScreenHeightDefault / mainScreenWidthDefault
//        }
//    }
//
//    func toAspectRatioDefault() -> CGSize {
//            return CGSize(width: mainScreenHeightDefault, height: mainScreenWidthDefault)
//    }
//
//    func toAspectRatioInternalDefault() -> CGSize {
//        return CGSize(width: mainScreenWidthDefault, height: mainScreenHeightDefault)
//    }
//}
//
//extension CGRect {
//    func aspectRatioDefault() -> CGFloat {
//        if mainScreenWidthDefault > mainScreenHeightDefault {
//            return mainScreenWidthDefault / mainScreenHeightDefault
//        } else {
//            return mainScreenHeightDefault / mainScreenWidthDefault
//        }
//    }
//
//    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
//        return CGRect(x: minX, y: minY, width: mainScreenWidthDefault * multiplier, height: mainScreenHeightDefault * multiplier)
//    }
//
//    func toAspectRatioReversedDefault() -> CGRect {
//        return CGRect(x: minX, y: minY, width: mainScreenHeightDefault, height: mainScreenWidthDefault)
//    }
//}
//
//extension UIScreen {
//    static var aspectRatioDefault: CGFloat {
//        let count = AKInterface.shared!.screenCount
//        if PlaySettings.shared.notch {
//            if count == 1 {
//                return mainScreenWidthDefault / mainScreenHeightDefault // 1.6 or 1.77777778
//            } else {
//                if AKInterface.shared!.isMainScreenEqualToFirst {
//                    return mainScreenWidthDefault / mainScreenHeightDefault
//                }
//            }
//
//        }
//
//        let frame = AKInterface.shared!.mainScreenFrame
//        return frame.aspectRatio()
//    }
//}
//
//public class PlayScreenDefault: NSObject {
//    @objc public static let shared = PlayScreenDefault()
//
//    @objc public static func frameReversed(_ rect: CGRect) -> CGRect {
//        return rect.toAspectRatioReversedDefault()
//    }
//    @objc public static func frame(_ rect: CGRect) -> CGRect {
//        return rect.toAspectRatioDefault()
//    }
//    @objc public static func bounds(_ rect: CGRect) -> CGRect {
//        return rect.toAspectRatioDefault()
//    }
//
//    @objc public static func nativeBounds(_ rect: CGRect) -> CGRect {
//            return rect.toAspectRatioDefault(2)
//    }
//
//    @objc public static func width(_ size: Int) -> Int {
//        return size
//    }
//
//    @objc public static func height(_ size: Int) -> Int {
//        return Int(size / Int(UIScreen.aspectRatioDefault))
//    }
//
//    @objc public static func sizeAspectRatio(_ size: CGSize) -> CGSize {
//        return size.toAspectRatioDefault()
//    }
//    @objc public static func frameInternal(_ rect: CGRect) -> CGRect {
//            return rect.toAspectRatioDefault()
//    }
//
//    var fullscreen: Bool {
//        return AKInterface.shared!.isFullscreen
//    }
//
//    @objc public var screenRect: CGRect {
//        return UIScreen.main.bounds
//    }
//
//    var width: CGFloat {
//        screenRect.width
//    }
//
//    var height: CGFloat {
//        screenRect.height
//    }
//
//    var max: CGFloat {
//        Swift.max(width, height)
//    }
//
//    var percent: CGFloat {
//        max / 100.0
//    }
//
//    var keyWindow: UIWindow? {
//        return UIApplication
//            .shared
//            .connectedScenes
//            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
//            .first { $0.isKeyWindow }
//    }
//
//    var windowScene: UIWindowScene? {
//        window?.windowScene
//    }
//
//    var window: UIWindow? {
//        return UIApplication.shared.connectedScenes
//            .filter({$0.activationState == .foregroundActive})
//            .compactMap({$0 as? UIWindowScene})
//            .first?.windows
//            .filter({$0.isKeyWindow}).first
//    }
//
//    var nsWindow: NSObject? {
//        window?.nsWindow
//    }
//
//    func switchDock(_ visible: Bool) {
//        AKInterface.shared!.setMenuBarVisible(visible)
//    }
//
//}
