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
    static var nextId: Int = 0
    static var idMap = [Int?](repeating: nil, count: 64)
    /**
     on invocations with phase "began", an int id is allocated, which can be used later to refer to this touch point.
     on invocations with phase "ended", id is set to nil representing the touch point is no longer valid.
     */
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?) {
        if phase == UITouch.Phase.began {
            tid = nextId
            nextId += 1
//            Toast.showOver(msg: tid!.description)
        }
        guard let bigId = tid else {
            // sending other phases with empty id is no-op
            return
        }
        if phase == UITouch.Phase.ended || phase == UITouch.Phase.cancelled {
            tid = nil
        }
        touchQueue.async {
            if keyWindow == nil || keyView == nil {
                keyWindow = screen.keyWindow
                DispatchQueue.main.sync {
                    keyView = keyWindow?.hitTest(point, with: nil)
                }
            }
            var pointId: Int = 0
            if phase != UITouch.Phase.began {
                guard let id = idMap.firstIndex(of: bigId) else {
                    // sending other phases before began is no-op
                    return
                }
                pointId = id
            }
            let resultingId = PTFakeMetaTouch.fakeTouchId(pointId, at: point, with: phase, in: keyWindow, on: keyView)
            if resultingId < 0 {
                idMap[pointId] = nil
            } else {
                idMap[resultingId] = bigId
            }
        }
    }
}
