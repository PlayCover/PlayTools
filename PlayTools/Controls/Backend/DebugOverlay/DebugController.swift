//
//  DebugController.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation

class DebugController {
    static let instance = DebugController()
    private init() {

    }

    private var debugView = DebugContainer.instance

    public func toggleDebugOverlay() {
        let window = screen.keyWindow
        let controller = window!.rootViewController
        let view = controller!.view
        // issue: always goes branch "Disabled"
        if debugView.superview == nil {
            view!.addSubview(debugView)
            view!.bringSubviewToFront(debugView)
            debugView.isHidden = false
            debugView.isUserInteractionEnabled = false
        } else {
            debugView.removeFromSuperview()
        }
    }
}
