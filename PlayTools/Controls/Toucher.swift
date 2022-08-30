//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {

    static var keyWindow: UIWindow?
    static var touchQueue = DispatchQueue.init(label: "playcover.toucher", qos: .userInteractive)

    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: Int) {
        touchQueue.async {
            if keyWindow == nil {
                keyWindow = UIApplication
                    .shared
                    .connectedScenes
                    .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                    .first { $0.isKeyWindow }
            }
            PTFakeMetaTouch.fakeTouchId(tid, at: point, with: phase, in: keyWindow)
        }
    }
}
