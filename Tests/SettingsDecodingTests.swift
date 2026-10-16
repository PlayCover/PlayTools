import Foundation

private enum SettingsTestError: Error {
    case failed(String)
}

@main
struct SettingsDecodingTests {
    static func main() {
        let tests = [
            ("legacy settings preserve saved values", testLegacySettings),
            ("empty settings use defaults", testEmptySettings),
            ("current settings round-trip", testCurrentSettings),
            ("invalid values still fail decoding", testInvalidValue)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        if failures > 0 {
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SettingsTestError.failed(message)
        }
    }

    private static func decode(_ values: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml)
        throws -> AppSettingsData {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
        return try PropertyListDecoder().decode(AppSettingsData.self, from: data)
    }

    private static func dictionary(_ settings: AppSettingsData) throws -> NSDictionary {
        let data = try PropertyListEncoder().encode(settings)
        let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = values as? NSDictionary else {
            throw SettingsTestError.failed("Expected a settings dictionary")
        }
        return dictionary
    }

    private static func testLegacySettings() throws {
        let legacy: [String: Any] = [
            "resolution": 6,
            "keymapping": false,
            "windowWidth": 1600,
            "windowHeight": 900,
            "customScaler": 1.5,
            "playChain": true,
            "bundleIdentifier": "example.legacy"
        ]
        var expected = AppSettingsData()
        expected.resolution = 6
        expected.keymapping = false
        expected.windowWidth = 1600
        expected.windowHeight = 900
        expected.customScaler = 1.5
        expected.playChain = true

        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let decoded = try decode(legacy, format: format)
            try expect(dictionary(decoded) == dictionary(expected), "Saved values or defaults changed")
        }
    }

    private static func testEmptySettings() throws {
        let decoded = try decode([:])
        try expect(dictionary(decoded) == dictionary(AppSettingsData()), "Missing settings should use defaults")
    }

    private static func testCurrentSettings() throws {
        // Exercise non-default values for every field, including nested Discord settings.
        var saved = AppSettingsData()
        saved.keymapping = false
        saved.sensitivity = 25
        saved.disableTimeout = true
        saved.iosDeviceModel = "iPad16,6"
        saved.windowWidth = 2560
        saved.windowHeight = 1440
        saved.customScaler = 1.5
        saved.resolution = 6
        saved.aspectRatio = 2
        saved.displayRotation = 1
        saved.notch = true
        saved.bypass = true
        saved.discordActivity.enable = false
        saved.discordActivity.applicationID = "test"
        saved.discordActivity.details = "details"
        saved.discordActivity.state = "state"
        saved.discordActivity.image = "image"
        saved.version = "3.0.0"
        saved.playChain = true
        saved.playChainDebugging = true
        saved.inverseScreenValues = true
        saved.windowFixMethod = 1
        saved.rootWorkDir = false
        saved.noKMOnInput = true
        saved.enableScrollWheel = false
        saved.hideTitleBar = true
        saved.floatingWindow = true
        saved.checkMicPermissionSync = true
        saved.limitMotionUpdateFrequency = true
        saved.disableBuiltinMouse = true
        saved.resizableAspectRatioType = 1
        saved.resizableAspectRatioWidth = 16
        saved.resizableAspectRatioHeight = 9
        saved.blockSleepSpamming = true
        saved.ignoreUnityKeyboardInitializationError = true
        let data = try PropertyListEncoder().encode(saved)
        let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
        try expect(dictionary(decoded) == dictionary(saved), "Current settings did not round-trip")
    }

    private static func testInvalidValue() throws {
        guard var values = try dictionary(AppSettingsData()) as? [String: Any] else {
            throw SettingsTestError.failed("Expected a settings dictionary")
        }
        values["resolution"] = "resizable"
        do {
            _ = try decode(values)
        } catch DecodingError.typeMismatch(_, let context) {
            try expect(context.codingPath.last?.stringValue == "resolution", "Wrong field rejected")
            return
        }
        throw SettingsTestError.failed("An invalid resolution should fail decoding")
    }
}
