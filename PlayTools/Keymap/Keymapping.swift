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

    public var currentKeymapURL: URL {
        keymapConfig.keymapOrder[keymapIdx]
    }

    public var currentKeymapName: String {
        currentKeymapURL.deletingPathExtension().lastPathComponent
    }

    public var keymapCount: Int {
        keymapOrder.count
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

    private func getKeymap(path: URL) -> KeymappingData {
        do {
            let data = try Data(contentsOf: path)
            let map = try PropertyListDecoder().decode(KeymappingData.self, from: data)
            return map
        } catch {
            print("[PlayTools] Keymapping decode failed.\n%@")
        }

        return KeymappingData(bundleIdentifier: bundleIdentifier)
    }

    private func setKeymap(path: URL, map: KeymappingData) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(map)
            try data.write(to: path)

            if !keymapOrder.keys.contains(path) {
                keymapConfig.keymapOrder.append(path)
                keymapOrder[path] = getKeymap(path: path)
            }
        } catch {
            print("[PlayTools] Keymapping encode failed.\n%@")
        }
    }

    public func nextKeymap() {
        keymapIdx = (keymapIdx + 1) % keymapOrder.count
    }

    public func previousKeymap() {
        keymapIdx = (keymapIdx - 1 + keymapOrder.count) % keymapOrder.count
    }

    @discardableResult
    public func resetKeymap(path: URL) -> KeymappingData {
        setKeymap(path: path, map: KeymappingData(bundleIdentifier: bundleIdentifier))
        return getKeymap(path: path)
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")

        keymapConfig = KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL])

        return keymapConfig
    }

}

struct KeymappingData: Codable {
    var buttonModels: [Button] = []
    var draggableButtonModels: [Button] = []
    var joystickModel: [Joystick] = []
    var mouseAreaModel: [MouseArea] = []
    var swipeModels: [Swipe] = []
    var radialSelectorModels: [RadialSelector] = []
    var hudOpacity: CGFloat?
    var bundleIdentifier: String
    var version = "2.0.0"

    init(buttonModels: [Button] = [],
         draggableButtonModels: [Button] = [],
         joystickModel: [Joystick] = [],
         mouseAreaModel: [MouseArea] = [],
         swipeModels: [Swipe] = [],
         radialSelectorModels: [RadialSelector] = [],
         hudOpacity: CGFloat? = nil,
         bundleIdentifier: String,
         version: String = "2.0.0") {
        self.buttonModels = buttonModels
        self.draggableButtonModels = draggableButtonModels
        self.joystickModel = joystickModel
        self.mouseAreaModel = mouseAreaModel
        self.swipeModels = swipeModels
        self.radialSelectorModels = radialSelectorModels
        self.hudOpacity = hudOpacity
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            buttonModels: try container.decodeIfPresent([Button].self, forKey: .buttonModels) ?? [],
            draggableButtonModels: try container.decodeIfPresent([Button].self, forKey: .draggableButtonModels) ?? [],
            joystickModel: try container.decodeIfPresent([Joystick].self, forKey: .joystickModel) ?? [],
            mouseAreaModel: try container.decodeIfPresent([MouseArea].self, forKey: .mouseAreaModel) ?? [],
            swipeModels: try container.decodeIfPresent([Swipe].self, forKey: .swipeModels) ?? [],
            radialSelectorModels: try container.decodeIfPresent([RadialSelector].self, forKey: .radialSelectorModels) ?? [],
            hudOpacity: try container.decodeIfPresent(CGFloat.self, forKey: .hudOpacity),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            version: try container.decodeIfPresent(String.self, forKey: .version) ?? "2.0.0"
        )
    }
}

struct KeymapConfig: Codable {
    var defaultKm: URL
    var keymapOrder: [URL]
}
