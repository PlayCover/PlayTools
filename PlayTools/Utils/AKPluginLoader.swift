//
//  AKPluginLoader.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import Foundation

class AKInterface {
    public static var shared: Plugin?

    public static func initialize() {
        shared = loadPlugin()
    }

    private static func loadPlugin() -> Plugin? {
        let frameworkBundle = Bundle(for: AKInterface.self)
        let candidates: [URL?] = [
            frameworkBundle.builtInPlugInsURL?.appendingPathComponent("AKInterface.bundle"),
            frameworkBundle.bundleURL.appendingPathComponent("PlugIns/AKInterface.bundle"),
            frameworkBundle.bundleURL.appendingPathComponent("Versions/A/PlugIns/AKInterface.bundle"),
            Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("AKInterface")
                .appendingPathExtension("bundle")
        ]

        for candidate in candidates {
            guard let bundleURL = candidate,
                  FileManager.default.fileExists(atPath: bundleURL.path),
                  let bundle = Bundle(url: bundleURL),
                  let pluginClass = bundle.principalClass as? Plugin.Type else {
                continue
            }
            return pluginClass.init()
        }
        return nil
    }
}
