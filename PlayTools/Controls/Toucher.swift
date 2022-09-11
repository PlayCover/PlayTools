//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {

    static weak var keyWindow: UIWindow?
    static weak var keyView: UIView?
    static var touchQueue = DispatchQueue.init(label: "playcover.toucher", qos: .userInteractive)

    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: Int) {
        touchQueue.async {
            if keyWindow == nil || keyView == nil {
                keyWindow = screen.keyWindow
                DispatchQueue.main.sync {
                    keyView = keyWindow?.hitTest(point, with: nil)
                }
            }
            PTFakeMetaTouch.fakeTouchId(tid, at: point, with: phase, in: keyWindow, on: keyView)
        }
    }
}
