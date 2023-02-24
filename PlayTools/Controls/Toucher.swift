//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {
    static weak var keyWindow: UIWindow?
    static weak var keyView: UIView?
//    static var touchQueue = DispatchQueue.init(label: "playcover.toucher", qos: .userInteractive)
//    static var nextId: Int = 0
//    static var idMap = [Int?](repeating: nil, count: 64)
    /**
     on invocations with phase "began", an int id is allocated, which can be used later to refer to this touch point.
     on invocations with phase "ended", id is set to nil representing the touch point is no longer valid.
     */
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?) {
        if phase == UITouch.Phase.began {
            if tid != nil {
                return
            }
            tid = -1
            keyWindow = screen.keyWindow
            keyView = keyWindow!.hitTest(point, with: nil)
        } else if tid == nil {
            return
        }
        tid = PTFakeMetaTouch.fakeTouchId(tid!, at: point, with: phase, in: keyWindow, on: keyView)
        if tid! < 0 {
            tid = nil
        }
    }
}
