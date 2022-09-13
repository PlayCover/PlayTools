//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit

class AKPlugin: NSObject, Plugin {
    required override init() {
    }

    func sayHello() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AppKit Plugin Loaded!"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
