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
            getKeymap(name: currentKeymapName)
        }
        set {
            setKeymap(name: currentKeymapName, map: newValue)
        }
    }

    private let baseKeymapURL: URL
    private let configURL: URL
    private var keymapURLs: [String: URL]

    public var keymapConfig: KeymapConfig {
        get {
            do {
                let data = try Data(contentsOf: configURL)
                return try PropertyListDecoder().decode(KeymapConfig.self, from: data)
            } catch {
                print("[PlayTools] Failed to decode config url.\n%@")
                return resetConfig()
            }
        }
        set {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml

            do {
                let data = try encoder.encode(newValue)
                try data.write(to: configURL)
            } catch {
                print("[PlayTools] Keymapping encode failed.\n%@")
            }
        }
    }

    public var currentKeymapName: String {
        Array(keymapURLs.keys)[keymapIdx]
    }

    init() {
        baseKeymapURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleIdentifier)

        configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")
        keymapURLs = [:]

        keymapIdx = 0

        do {
            let data = try Data(contentsOf: configURL)
            keymapConfig = try PropertyListDecoder().decode(KeymapConfig.self, from: data)
        } catch {
            print("[PlayTools] Failed to decode config url.\n%@")
            keymapConfig = KeymapConfig(defaultKm: "default")
            resetConfig()
        }

        loadKeymapData()
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

        reloadKeymapCache()

        if let defaultKmIdx = keymapURLs.keys.firstIndex(of: keymapConfig.defaultKm) {
            keymapIdx = keymapURLs.distance(from: keymapURLs.startIndex, to: defaultKmIdx)
        }
    }

    public func reloadKeymapCache() {
        keymapURLs = [:]

        do {
            let directoryContents = try FileManager.default
                .contentsOfDirectory(at: baseKeymapURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

            if directoryContents.count > 0 {
                for keymap in directoryContents where keymap.pathExtension.contains("plist") {
                    keymapURLs[keymap.deletingPathExtension().lastPathComponent] = keymap
                }

                return
            }
        } catch {
            print("[PlayTools] Failed to get keymapping directory.\n%@")
        }

        setKeymap(name: "default", map: KeymappingData(bundleIdentifier: bundleIdentifier))
        reloadKeymapCache()
    }

    private func getKeymap(name: String) -> KeymappingData {
        if let keymapURL = keymapURLs[name] {
            do {
                let data = try Data(contentsOf: keymapURL)
                let map = try PropertyListDecoder().decode(KeymappingData.self, from: data)
                return map
            } catch {
                print("[PlayTools] Keymapping decode failed.\n%@")
            }
        } else {
            print("[PlayTools] Unable to find keymap with name \(name).\n%@")
        }

        return resetKeymap(name: name)
    }

    private func setKeymap(name: String, map: KeymappingData) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        if !keymapURLs.keys.contains(name) {
            let mapURL = baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")

            keymapURLs[name] = mapURL
        }

        if let keymapURL = keymapURLs[name] {
            do {
                let data = try encoder.encode(map)
                try data.write(to: keymapURL)
            } catch {
                print("[PlayTools] Keymapping encode failed.\n%@")
            }
        } else {
            print("[PlayTools] Unable to find keymap with name \(name).\n%@")
        }
    }

    public func nextKeymap() {
        keymapIdx = (keymapIdx + 1) % keymapURLs.count
    }

    public func previousKeymap() {
        keymapIdx = (keymapIdx - 1 + keymapURLs.count) % keymapURLs.count
    }

    @discardableResult
    public func resetKeymap(name: String) -> KeymappingData {
        setKeymap(name: name, map: KeymappingData(bundleIdentifier: bundleIdentifier))
        return getKeymap(name: name)
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let defaultKm = keymapURLs.keys.contains("default") ? "default" : keymapURLs.keys.first

        guard let defaultKm = defaultKm else {
            reloadKeymapCache()
            return resetConfig()
        }

        keymapConfig = KeymapConfig(defaultKm: defaultKm)

        return keymapConfig
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
    var defaultKm: String
}
