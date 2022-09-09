import GameController
import SwiftUI

let editor = EditorController.shared

final class EditorController: NSObject {

    static let shared = EditorController()
    var editorMode: Bool { !(editorWindow?.isHidden ?? true)}

    let lock = NSLock()

    var editorWindow: UIWindow?
    weak var previousWindow: UIWindow?

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        let controller = UIHostingController(rootView: KeymapEditorView())
        controller.view!.backgroundColor = .clear

        window.rootViewController = controller
        return window
    }

    public func switchMode() {
        lock.lock()
        if editorMode {
            editorWindow?.isHidden = true
            editorWindow?.windowScene = nil
            editorWindow?.rootViewController = nil

            // Menu still holds this object until next responder hit test
            editorWindow = nil
            previousWindow?.makeKeyAndVisible()
            mode.show(false)
        } else {
            mode.show(true)
            previousWindow = screen.keyWindow
            editorWindow = initWindow()
            editorWindow?.makeKeyAndVisible()
        }
        lock.unlock()
    }
}
