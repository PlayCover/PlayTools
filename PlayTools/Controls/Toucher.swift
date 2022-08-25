//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {

    static var keyWindow: UIWindow?

    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: Int) {
        if keyWindow == nil {
            keyWindow = UIApplication
                .shared
                .connectedScenes
                .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                .first { $0.isKeyWindow }
        }
        DispatchQueue.main.async {
            PTFakeMetaTouch.fakeTouchId(tid, at: point, with: phase, in: keyWindow)
        }
    }
}
