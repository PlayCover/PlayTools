import GameController
import SwiftUI

let editor = EditorController.shared

class EditorController {

    static let shared = EditorController()

    let lock = NSLock()
    var editorEnabled: Bool { !(editorWindow?.isHidden ?? true)}

    var editorWindow: UIWindow?
    weak var previousWindow: UIWindow?

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        let controller = UIHostingController(rootView: KeymapEditorView())
        controller.view!.backgroundColor = .clear
        window.rootViewController = controller
        return window
    }

    public func toggleEditor() {
        lock.lock()
        if editorEnabled {
            editorWindow?.isHidden = true
            editorWindow?.windowScene = nil
            editorWindow?.rootViewController = nil
            editorWindow = nil
            previousWindow?.makeKeyAndVisible()
        } else {
            previousWindow = screen.keyWindow
            editorWindow = initWindow()
            editorWindow?.makeKeyAndVisible()
        }
        lock.unlock()
    }
}
