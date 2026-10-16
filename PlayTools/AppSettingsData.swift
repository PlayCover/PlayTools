import Foundation

struct AppSettingsData: Codable {
    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var iosDeviceModel = "iPad13,8"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 2
    var aspectRatio = 1
    var displayRotation = 0
    var notch = false
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "2.0.0"
    var playChain = false
    var playChainDebugging = false
    var inverseScreenValues = false
    var windowFixMethod = 0
    var rootWorkDir = true
    var noKMOnInput = false
    var enableScrollWheel = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false

    init() {}

    // Older settings files omit newer keys. Keep their saved values and default only missing fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keymapping = try container.decodeIfPresent(Bool.self, forKey: .keymapping) ?? keymapping
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? sensitivity
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? disableTimeout
        iosDeviceModel = try container.decodeIfPresent(String.self, forKey: .iosDeviceModel) ?? iosDeviceModel
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? windowWidth
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? windowHeight
        customScaler = try container.decodeIfPresent(Double.self, forKey: .customScaler) ?? customScaler
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? resolution
        aspectRatio = try container.decodeIfPresent(Int.self, forKey: .aspectRatio) ?? aspectRatio
        displayRotation = try container.decodeIfPresent(Int.self, forKey: .displayRotation) ?? displayRotation
        notch = try container.decodeIfPresent(Bool.self, forKey: .notch) ?? notch
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? bypass
        discordActivity = try container.decodeIfPresent(DiscordActivity.self,
                                                       forKey: .discordActivity) ?? discordActivity
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? version
        playChain = try container.decodeIfPresent(Bool.self, forKey: .playChain) ?? playChain
        playChainDebugging = try container.decodeIfPresent(Bool.self, forKey: .playChainDebugging) ?? playChainDebugging
        inverseScreenValues = try container.decodeIfPresent(Bool.self,
                                                           forKey: .inverseScreenValues) ?? inverseScreenValues
        windowFixMethod = try container.decodeIfPresent(Int.self, forKey: .windowFixMethod) ?? windowFixMethod
        rootWorkDir = try container.decodeIfPresent(Bool.self, forKey: .rootWorkDir) ?? rootWorkDir
        noKMOnInput = try container.decodeIfPresent(Bool.self, forKey: .noKMOnInput) ?? noKMOnInput
        enableScrollWheel = try container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel) ?? enableScrollWheel
        hideTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? hideTitleBar
        floatingWindow = try container.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? floatingWindow
        checkMicPermissionSync = try container.decodeIfPresent(Bool.self,
                                                              forKey: .checkMicPermissionSync) ?? checkMicPermissionSync
        limitMotionUpdateFrequency = try container.decodeIfPresent(Bool.self,
                                                                  forKey: .limitMotionUpdateFrequency)
            ?? limitMotionUpdateFrequency
        disableBuiltinMouse = try container.decodeIfPresent(Bool.self,
                                                           forKey: .disableBuiltinMouse) ?? disableBuiltinMouse
        resizableAspectRatioType = try container.decodeIfPresent(Int.self,
                                                                forKey: .resizableAspectRatioType)
            ?? resizableAspectRatioType
        resizableAspectRatioWidth = try container.decodeIfPresent(Int.self,
                                                                 forKey: .resizableAspectRatioWidth)
            ?? resizableAspectRatioWidth
        resizableAspectRatioHeight = try container.decodeIfPresent(Int.self,
                                                                  forKey: .resizableAspectRatioHeight)
            ?? resizableAspectRatioHeight
        blockSleepSpamming = try container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming) ?? blockSleepSpamming
        ignoreUnityKeyboardInitializationError = try container.decodeIfPresent(
            Bool.self, forKey: .ignoreUnityKeyboardInitializationError
        ) ?? ignoreUnityKeyboardInitializationError
    }
}
