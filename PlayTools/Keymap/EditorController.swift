import GameController
import SwiftUI

let editor = EditorController.shared

final class EditorController: NSObject {

    static let shared = EditorController()
    let lock = NSLock()

    var editorMode: Bool { !(editorWindow?.isHidden ?? true)}
    var editorWindow: UIWindow?
    weak var previousWindow: UIWindow?

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        let controller = UIHostingController(rootView: KeymapEditorView())
        controller.view!.backgroundColor = .clear
        window.rootViewController = controller
        loadPlugin()
        return window
    }

    private func loadPlugin() {
        /// 1. Form the plugin's bundle URL
        let bundleFileName = "AppKitInterface.bundle"
        guard let bundleURL = Bundle.main.builtInPlugInsURL?
                                    .appendingPathComponent(bundleFileName) else { return }

        /// 2. Create a bundle instance with the plugin URL
        guard let bundle = Bundle(url: bundleURL) else { return }

        /// 3. Load the bundle and our plugin class
        let className = "AppKitInterface.MacPlugin"
        guard let pluginClass = bundle.classNamed(className) as? Plugin.Type else { return }

//        /// 3. Load the bundle and the principal class
//        guard let pluginClass = bundle.principalClass as? Plugin.Type else { return }

        /// 4. Create an instance of the plugin class
        let plugin = pluginClass.init()
        plugin.sayHello()
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
