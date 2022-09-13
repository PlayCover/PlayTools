//
//  PlayViews.swift
//  PlayTools
//

import Foundation
import UIKit

let shared = PlayUI.shared

final class PlayUI {

    static let shared = PlayUI()

    private init() {}

    func showAlert(_ title: String, _ content: String) {
        let alertController = UIAlertController(title: title, message: content, preferredStyle: .alert)
        PlayInput.shared.root?.present(alertController, animated: true, completion: nil)
        loadPlugin()
    }

    func showLauncherWarning() {
        let alertController = UIAlertController(title: "PlayCover Launcher is not found!",
                                                message: "Please, install it from playcover.io site to use this app.",
                                                preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            Dynamic.NSApplication.sharedApplication.terminate(self)
        })
        PlayInput.shared.root?.present(alertController, animated: true, completion: nil)
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
}
