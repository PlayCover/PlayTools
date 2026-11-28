import Foundation
import UIKit
import GameController
import Atomics

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    private var displayLink: CADisplayLink?
    private let appActive = ManagedAtomic(false)
    private var isAppActive: Bool {
        get { appActive.load(ordering: .acquiring) }
        set { appActive.store(newValue, ordering: .releasing) }
    }
    private var initialized = false

    var acceptsControllerInput: Bool { isAppActive }

    @objc func drainMainDispatchQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true
        if PlaySettings.shared.disableBuiltinMouse {
            simulateGCMouseDisconnect()
        }

        guard PlaySettings.shared.keymapping else {
            return
        }

        isAppActive = AKInterface.shared?.isApplicationActive
            ?? (UIApplication.shared.applicationState == .active)

        let centre = NotificationCenter.default
        let main = OperationQueue.main
        registerInputLifecycleObservers(centre: centre, main: main)
        updateDisplayLinkState()

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

    private func setAppActive(_ active: Bool) {
        // AppKit focus notifications are authoritative on Catalyst, where UIKit
        // can remain foreground-active even when another Mac app owns focus.
        let wasActive = isAppActive
        isAppActive = active && (AKInterface.shared?.isApplicationActive ?? true)
        if wasActive && !isAppActive {
            ActionDispatcher.invalidateActions()
        }
        updateDisplayLinkState()
    }

    private func updateDisplayLinkState() {
        let hasController = !GCController.controllers().isEmpty
        if !hasController || !isAppActive {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        if displayLink == nil {
            // Drain the main dispatch queue per frame while a GCController is active.
            let link = CADisplayLink(target: self, selector: #selector(drainMainDispatchQueue))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
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

    private func registerInputLifecycleObservers(centre: NotificationCenter, main: OperationQueue) {
        // Only run the CADisplayLink queue-drainer while keymapping is active,
        // at least one GCController is connected, and the app is foreground-active.
        for name in [
            NSNotification.Name.GCControllerDidConnect,
            NSNotification.Name.GCControllerDidDisconnect
        ] {
            centre.addObserver(forName: name, object: nil, queue: main) { [weak self] _ in
                self?.updateDisplayLinkState()
            }
        }
        for name in [UIApplication.didBecomeActiveNotification,
                     NSNotification.Name("NSApplicationDidBecomeActiveNotification")] {
            centre.addObserver(forName: name, object: nil, queue: main) { [weak self] _ in
                self?.setAppActive(true)
            }
        }
        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            NSNotification.Name("NSApplicationDidResignActiveNotification"),
            NSNotification.Name("NSApplicationDidHideNotification"),
            NSNotification.Name("NSApplicationWillTerminateNotification")
        ] {
            centre.addObserver(forName: name, object: nil, queue: main) { [weak self] _ in
                self?.setAppActive(false)
            }
        }
    }
}
