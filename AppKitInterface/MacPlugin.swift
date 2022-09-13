//
//  MacPlugin.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 12/09/2022.
//

import AppKit

class MacPlugin: NSObject, Plugin {
    required override init() {
    }

    func sayHello() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Hello from AppKit!"
        alert.informativeText = "It Works!"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
