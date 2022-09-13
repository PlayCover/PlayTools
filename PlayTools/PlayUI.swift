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
    }

    func showLauncherWarning() {
        let alertController = UIAlertController(title: "PlayCover Launcher is not found!",
                                                message: "Please, install it from playcover.io site to use this app.",
                                                preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            // Dynamic.NSApplication.sharedApplication.terminate(self)
        })
        PlayInput.shared.root?.present(alertController, animated: true, completion: nil)
    }
}
