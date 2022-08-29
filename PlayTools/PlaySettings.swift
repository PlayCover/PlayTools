import Foundation
import UIKit
import os.log

let settings = PlaySettings.shared

@objc public final class PlaySettings: NSObject {
    @objc public static let shared = PlaySettings()

    private static let keywords = ["game", "unity", "metal", "netflix", "opengl", "minecraft", "mihoyo", "disney"]

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    let settingsUrl: URL
    var settingsData: AppSettingsData

    override init() {
        settingsUrl = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        do {
            let data = try Data(contentsOf: settingsUrl)
            settingsData = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
        } catch {
            settingsData = AppSettingsData()
            os_log("[PlayTools] PlaySettings decode failed.\n%@", type: .error, error as CVarArg)
        }
    }

    var isGame: Bool = {
        if let info = Bundle.main.infoDictionary?.description {
            for keyword in PlaySettings.keywords {
                if info.contains(keyword) && !info.contains("xbox") {
                    return true
                }
            }
        }
        return false
    }()

    lazy var discordActivity = settingsData.discordActivity

    lazy var keymapping = settingsData.keymapping

    lazy var mouseMapping = settingsData.mouseMapping

    lazy var notch = settingsData.notch

    lazy var sensitivity = settingsData.sensitivity / 100

    lazy var windowSizeHeight = CGFloat(settingsData.windowHeight)

    lazy var windowSizeWidth = CGFloat(settingsData.windowWidth)

    @objc lazy var adaptiveDisplay = settingsData.resolution == 0 ? false : true

    @objc lazy var deviceModel = settingsData.iosDeviceModel as NSString

    @objc lazy var oemID: NSString = {
        switch settingsData.iosDeviceModel {
        case "iPad6,7":
            return "J98aAP"
        case "iPad8,6":
            return "J320xAP"
        case "iPad13,8":
            return "J522AP"
        default:
            return "J320xAP"
        }
    }()

    @objc lazy var refreshRate = settingsData.refreshRate

}

struct AppSettingsData: Codable {
    var keymapping = true
    var mouseMapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var iosDeviceModel = "iPad8,6"
    var refreshRate = 60
    var windowWidth = 1920
    var windowHeight = 1080
    var resolution = 0
    var aspectRatio = 1
    var notch = false
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "2.0.0"
}
