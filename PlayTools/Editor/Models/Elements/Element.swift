import GameController

class ControlData {
    var keyCodes: [Int]
    var keyName: String
    var size: CGFloat
    var xCoord: CGFloat
    var yCoord: CGFloat
    var parent: ControlModel?

    init(keyCodes: [Int], keyName: String, size: CGFloat,
         xCoord: CGFloat, yCoord: CGFloat, parent: ControlModel? = nil) {
        self.keyCodes = keyCodes
        self.keyName = keyName
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.parent = parent
    }

    convenience init(keyCodes: [Int], parent: ControlModel) {
        self.init(keyCodes: keyCodes, keyName: KeyCodeNames.keyCodes[keyCodes[0]] ?? "Btn", parent: parent)
    }

    init(keyCodes: [Int], keyName: String, parent: ControlModel) {
        self.keyCodes = keyCodes
        // For now, not support binding controller key
        // Support for that is left for later to concern
        self.keyName = keyName
        self.size = parent.data.size  / 3
        self.xCoord = 0
        self.yCoord = 0
        self.parent = parent
    }

    init(keyName: String, size: CGFloat, xCoord: CGFloat, yCoord: CGFloat) {
        self.keyCodes = [0]
        self.keyName = keyName
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.parent = nil
    }
}

// Data structure definition should match those in
// https://github.com/PlayCover/PlayCover/blob/develop/PlayCover/Model/Keymapping.swift
struct KeyModelTransform: Codable {
    var size: CGFloat
    var xCoord: CGFloat
    var yCoord: CGFloat
}
// controller buttons are indexed with names
struct Button: Codable {
    var keyCode: Int
    var keyName: String
    var transform: KeyModelTransform
}

struct Joystick: Codable {
    var upKeyCode: Int
    var rightKeyCode: Int
    var downKeyCode: Int
    var leftKeyCode: Int
    var keyName: String = "Keyboard"
    var transform: KeyModelTransform
}

struct MouseArea: Codable {
    var keyName: String
    var transform: KeyModelTransform
    init(transform: KeyModelTransform) {
        self.transform = transform
        self.keyName = "Mouse"
    }
    init(keyName: String, transform: KeyModelTransform) {
        self.transform = transform
        self.keyName = keyName
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
