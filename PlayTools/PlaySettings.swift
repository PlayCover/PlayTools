import Foundation
import UIKit

let settings = PlaySettings.shared

extension Dictionary {

    func store(_ toURL: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
        try data.write(to: toURL, options: .atomic)
    }

    static func read( _ from: URL) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = FileManager.default.contents(atPath: from.path) {
            return try PropertyListSerialization
                    .propertyList(from: data,
                            options: .mutableContainersAndLeaves,
                            format: &format) as? Dictionary
        }
        return nil
    }

}

@objc public final class PlaySettings: NSObject {

    private static let fileExtension = "plist"

    @objc public static let shared = PlaySettings()

    private static let enableWindowAutoSize = "pc.enableWindowAutoSize"

    private static let gamingmodeKey = "pc.gamingMode"

    lazy var gamingMode: Bool = {
        if let key = settings[PlaySettings.gamingmodeKey] as? Bool {
            return key
        }
        return PlaySettings.isGame
    }()

    private static let notchKey = "pc.hasNotch"

    lazy var notch: Bool = {
        if let key = settings[PlaySettings.notchKey] as? Bool {
            return key
        }
        return false
    }()

    private static let layoutKey = "pc.layout"

    lazy var layout: [[CGFloat]] = [] {
        didSet {
            do {
                settings[PlaySettings.layoutKey] = layout
                allPrefs[Bundle.main.bundleIdentifier!] = settings
                try allPrefs.store(PlaySettings.settingsUrl)
            } catch {
                print("failed to save settings: \(error)")
            }
        }
    }

    public func setupLayout() {
        layout = settings[PlaySettings.layoutKey] as? [[CGFloat]] ?? []
    }

    private static let adaptiveDisplayKey = "pc.adaptiveDisplay"
    @objc public var adaptiveDisplay: Bool {
        if let key = settings[PlaySettings.adaptiveDisplayKey] as? Bool {
            return key
        }
        return PlaySettings.isGame
    }

    private static let keymappingKey = "pc.keymapping"
    @objc public var keymapping: Bool {
        if let key = settings[PlaySettings.keymappingKey] as? Bool {
            return key
        }
        return PlaySettings.isGame
    }

    private static let refreshRateKey = "pc.refreshRate"
    @objc lazy public var refreshRate: Int = {
        if let key = settings[PlaySettings.refreshRateKey] as? Int {
            return key
        }
        return 60
    }()

    private static let sensivityKey = "pc.sensivity"

    @objc lazy public var sensivity: Float = {
        if let key = settings[PlaySettings.sensivityKey] as? Float {
            return key / 100
        }
        return 0.5
    }()

    private static let gameWindowSizeHeight = "pc.gameWindowSizeHeight"
    @objc lazy public var windowSizeHeight: CGFloat = {
        if let key = settings[PlaySettings.gameWindowSizeHeight] as? CGFloat {
            return key
        }
        return 1080.0
    }()

    private static let gameWindowSizeWidth = "pc.gameWindowSizeWidth"
    @objc lazy public var windowSizeWidth: CGFloat = {
        if let key = settings[PlaySettings.gameWindowSizeWidth] as? CGFloat {
            return key
        }
        return 1920.0
    }()

    private static let ipadModelKey = "pc.ipadModel"
    @objc lazy public var GET_IPAD_MODEL: NSString = {
        if let key = settings[PlaySettings.ipadModelKey] as? NSString {
            return key
        }
        return "iPad8,6"
    }()

    @objc lazy public var GET_OEM_ID: NSString = {
        if let key = settings[PlaySettings.ipadModelKey] as? NSString {
            switch key {
            case "iPad6,7":
                return "J98aAP"
            case "iPad8,6":
                return "J320xAP"
            case "iPad13,8":
                return "J522AP"
            default:
                return "J320xAP"
            }
        }
        return "J320xAP"
    }()

    static var isGame: Bool {
        if let info = Bundle.main.infoDictionary?.description {
            for keyword in PlaySettings.keywords {
                if info.contains(keyword) && !info.contains("xbox") {
                    return true
                }
            }
        }
        return false
    }

    lazy var settings: [String: Any] = {
        if let prefs = allPrefs[Bundle.main.bundleIdentifier!] as? [String: Any] {
            return prefs
        }
        return [PlaySettings.adaptiveDisplayKey: PlaySettings.isGame, PlaySettings.keymappingKey: PlaySettings.isGame]
    }()

    lazy var allPrefs: [String: Any] = {
        do {
            if let all = try [String: Any].read(PlaySettings.settingsUrl) {
                return all
            }
        } catch {
            print("failed to load settings: \(error)")
        }
        return [:]
    }()

    public func clearLegacy() {
        UserDefaults.standard.removeObject(forKey: "layout")
        UserDefaults.standard.removeObject(forKey: "pclayout")
        UserDefaults.standard.removeObject(forKey: "playcover.macro")
        UserDefaults.standard.removeObject(forKey: PlaySettings.sensivityKey)
        UserDefaults.standard.removeObject(forKey: PlaySettings.refreshRateKey)
        UserDefaults.standard.removeObject(forKey: PlaySettings.keymappingKey)
        UserDefaults.standard.removeObject(forKey: PlaySettings.adaptiveDisplayKey)
        UserDefaults.standard.removeObject(forKey: PlaySettings.gameWindowSizeWidth)
        UserDefaults.standard.removeObject(forKey: PlaySettings.gameWindowSizeHeight)
        UserDefaults.standard.removeObject(forKey: PlaySettings.enableWindowAutoSize)
    }

    public static let settingsUrl = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Preferences/playcover.plist")

    private static var keywords = ["game", "unity", "metal", "netflix", "opengl", "minecraft", "mihoyo", "disney"]
}
