import Foundation
import UIKit

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    func initialize() {
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
}
