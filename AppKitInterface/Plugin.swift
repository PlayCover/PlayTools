//
//  Plugin.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 12/09/2022.
//

import Foundation

@objc(Plugin)
protocol Plugin: NSObjectProtocol {
    init()

    func sayHello()
}
