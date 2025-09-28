import Foundation
import UIKit
import GameController

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    @objc func drainMainDispatchQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }

    func initialize() {
        // drain the dispatch queue every frame for responding to GCController events
        let displaylink = CADisplayLink(target: self, selector: #selector(drainMainDispatchQueue))
        displaylink.add(to: .main, forMode: .common)

        if PlaySettings.shared.disableBuiltinMouse {
            simulateGCMouseDisconnect()
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if mode.cursorHidden() {
                AKInterface.shared!.warpCursor()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
            if mode.cursorHidden() || !ActionDispatcher.cursorHideNecessary {
                return
            }
            Toast.initialize()
        }
        mode.initialize()
    }

    private func simulateGCMouseDisconnect() {
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { nofitication in
            guard let mouse = nofitication.object as? GCMouse else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: mouse)
                mouse.mouseInput?.leftButton.pressedChangedHandler = nil
                mouse.mouseInput?.leftButton.valueChangedHandler = nil
                mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                mouse.mouseInput?.rightButton?.valueChangedHandler = nil
                mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                mouse.mouseInput?.middleButton?.valueChangedHandler = nil
                mouse.mouseInput?.auxiliaryButtons?.forEach { button in
                    button.pressedChangedHandler = nil
                    button.valueChangedHandler = nil
                }
                mouse.mouseInput?.scroll.valueChangedHandler = nil
                mouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }
}
