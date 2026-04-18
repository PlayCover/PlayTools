//
//  Keymapping.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/08/29.
//

import Foundation

let keymap = Keymapping.shared

class Keymapping {
    static let shared = Keymapping()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""

    private var keymapIdx: Int
    public var currentKeymap: KeymappingData {
        get {
            getKeymap(path: currentKeymapURL)
        }
        set {
            setKeymap(path: currentKeymapURL, map: newValue)
        }
    }

    private let baseKeymapURL: URL
    private let configURL: URL
    private var keymapOrder: [URL: KeymappingData] = [:]

    public var keymapConfig: KeymapConfig {
        get {
            if let config = readConfig() {
                return config
            } else {
                print("[PlayTools] Failed to decode config url.\n%@")
                return resetConfig()
            }
        }
        set {
            if !writeConfig(newValue) {
                print("[PlayTools] Keymapping encode failed.\n%@")
            }
        }
    }

    public var currentKeymapURL: URL {
        keymapConfig.keymapOrder[keymapIdx]
    }

    public var currentKeymapName: String {
        currentKeymapURL.deletingPathExtension().lastPathComponent
    }

    init() {
        baseKeymapURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleIdentifier)

        configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        keymapIdx = 0

        loadKeymapData()
    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    private func readConfig() -> KeymapConfig? {
        do {
            let data = try Data(contentsOf: configURL)
            return try PropertyListDecoder().decode(KeymapConfig.self, from: data)
        } catch {
            return nil
        }
    }

    @discardableResult
    private func writeConfig(_ config: KeymapConfig) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(config)
            try data.write(to: configURL)
            return true
        } catch {
            return false
        }
    }

    private func defaultConfig() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")
        return KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL])
    }

    private func loadKeymapData() {
        if !FileManager.default.fileExists(atPath: baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: baseKeymapURL.path,
                    withIntermediateDirectories: true,
                    attributes: [:])
            } catch {
                print("[PlayTools] Failed to create Keymapping directory.\n%@")
            }
        }

        keymapOrder.removeAll()

        for keymap in keymapConfig.keymapOrder {
            keymapOrder[keymap] = getKeymap(path: keymap)
        }

        if let defaultKmIdx = keymapOrder.keys.firstIndex(of: keymapConfig.defaultKm) {
            keymapIdx = keymapOrder.distance(from: keymapOrder.startIndex, to: defaultKmIdx)
        } else {
            setKeymap(path: keymapConfig.defaultKm, map: KeymappingData(bundleIdentifier: bundleIdentifier))
            loadKeymapData()
        }
    }

    private func readKeymap(path: URL) -> KeymappingData? {
        do {
            let data = try Data(contentsOf: path)
            return try PropertyListDecoder().decode(KeymappingData.self, from: data)
        } catch {
            return nil
        }
    }

    private func getKeymap(path: URL) -> KeymappingData {
        if let map = readKeymap(path: path) {
            return map
        }

        print("[PlayTools] Keymapping decode failed.\n%@")

        return resetKeymap(path: path)
    }

    @discardableResult
    private func writeKeymap(path: URL, map: KeymappingData) -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(map)
            try data.write(to: path)
            return true
        } catch {
            return false
        }
    }

    private func setKeymap(path: URL, map: KeymappingData) {
        guard writeKeymap(path: path, map: map) else {
            print("[PlayTools] Keymapping encode failed.\n%@")
            return
        }

        if !keymapOrder.keys.contains(path) {
            var config = keymapConfig
            config.keymapOrder.append(path)
            keymapConfig = config
        }

        keymapOrder[path] = map
    }

    public func nextKeymap() {
        keymapIdx = (keymapIdx + 1) % keymapOrder.count
    }

    public func previousKeymap() {
        keymapIdx = (keymapIdx - 1 + keymapOrder.count) % keymapOrder.count
    }

    @discardableResult
    public func resetKeymap(path: URL) -> KeymappingData {
        let defaultMap = KeymappingData(bundleIdentifier: bundleIdentifier)
        setKeymap(path: path, map: defaultMap)
        return defaultMap
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let config = defaultConfig()
        _ = writeConfig(config)
        return config
    }

}

struct KeymappingData: Codable {
    var buttonModels: [Button] = []
    var draggableButtonModels: [Button] = []
    var joystickModel: [Joystick] = []
    var mouseAreaModel: [MouseArea] = []
    var bundleIdentifier: String
    var version = "2.0.0"
}

struct KeymapConfig: Codable {
    var defaultKm: URL
    var keymapOrder: [URL]
}
