// Should match https://github.com/PlayCover/PlayCover/blob/develop/PlayCover/Model/KeyCodeNames.swift exactly
import GameController
class KeyCodeNames {
    public static let defaultCode = -10

    public static let leftMouseButton = "LMB"
    public static let rightMouseButton = "RMB"
    public static let middleMouseButton = "MMB"
    public static let mouseMove = "Mouse"

    // Internal used names, not stored to keymap
    public static let scrollWheelScale = "ScrollWheelScale"
    public static let scrollWheelDrag = "ScrollWheelDrag"
    public static let fakeMouse = "FakeMouse"

    private static let gcKeyCodeLiteral = [
    -4: "cA",
    -5: "cX",
    -6: "cB",
    -7: "cY",
    -8: "dU",
    -9: "dD",
//    -10: "dR",
    -10: "Controller",
    -11: "dL",
    -12: "L1",
    -13: "L2",
    -14: "R1",
    -15: "R2",
    -1: "LMB",
    -2: "RMB",
    -3: "MMB",
    41: "Esc",
    44: "Spc",
    225: "Lshft",
    57: "Caps",
    43: "Tab",
    227: "LCmd",
    226: "LOpt",
    224: "LCtrl",
    228: "RCtrl",
    231: "RCmd",
    230: "ROpt",
    40: "Enter",
    42: "Del",
    229: "Rshft",
    80: "Left",
    79: "Right",
    82: "Up",
    81: "Down",
    58: "F1",
    59: "F2",
    60: "F3",
    61: "F4",
    62: "F5",
    63: "F6",
    64: "F7",
    65: "F8",
    66: "F9",
    67: "F10",
    68: "F11",
    69: "F12",
    30: "1",
    31: "2",
    32: "3",
    33: "4",
    34: "5",
    35: "6",
    36: "7",
    37: "8",
    38: "9",
    39: "0",
    45: "-",
    46: "=",
    20: "Q",
    26: "W",
    8: "E",
    21: "R",
    23: "T",
    28: "Y",
    24: "U",
    12: "I",
    18: "O",
    19: "P",
    47: "[",
    48: "]",
    4: "A",
    22: "S",
    7: "D",
    9: "F",
    10: "G",
    11: "H",
    13: "J",
    14: "K",
    15: "L",
    51: ";",
    52: "'",
    49: "\\",
    29: "Z",
    53: "`",
    27: "X",
    6: "C",
    25: "V",
    5: "B",
    17: "N",
    16: "M",
    54: ",",
    55: ".",
    56: "/"
    ]
    public static let keyCodes: [Int: String] = {
        // Dictionary initializer must be literal, so moving to a function
        // Swift Lint said function was too long, so split into two parts
        var gcCode = gcKeyCodeLiteral
        gcCode[GCKeyCode.F17.rawValue] = "F17"
        gcCode[GCKeyCode.keypadPeriod.rawValue] = "Keypad ."
        gcCode[GCKeyCode.keypadAsterisk.rawValue] = "Keypad *"
        gcCode[GCKeyCode.keypadPlus.rawValue] = "Keypad +"
        gcCode[GCKeyCode.keypadNumLock.rawValue] = "NumLock"
        gcCode[GCKeyCode.keypadSlash.rawValue] = "Keypad /"
        gcCode[GCKeyCode.keypadEnter.rawValue] = "Keypad Enter"
        gcCode[GCKeyCode.keypadHyphen.rawValue] = "Keypad -"
        gcCode[GCKeyCode.F18.rawValue] = "F18"
        gcCode[GCKeyCode.F19.rawValue] = "F19"
        gcCode[GCKeyCode.keypadEqualSign.rawValue] = "Keypad ="
        gcCode[GCKeyCode.keypad0.rawValue] = "Keypad 0"
        gcCode[GCKeyCode.keypad1.rawValue] = "Keypad 1"
        gcCode[GCKeyCode.keypad2.rawValue] = "Keypad 2"
        gcCode[GCKeyCode.keypad3.rawValue] = "Keypad 3"
        gcCode[GCKeyCode.keypad4.rawValue] = "Keypad 4"
        gcCode[GCKeyCode.keypad5.rawValue] = "Keypad 5"
        gcCode[GCKeyCode.keypad6.rawValue] = "Keypad 6"
        gcCode[GCKeyCode.keypad7.rawValue] = "Keypad 7"
        gcCode[GCKeyCode.F20.rawValue] = "F20"
        gcCode[GCKeyCode.keypad8.rawValue] = "Keypad 8"
        gcCode[GCKeyCode.keypad9.rawValue] = "Keypad 9"
        gcCode[GCKeyCode.international3.rawValue] = "¥" // IntlYen
        gcCode[GCKeyCode.international1.rawValue] = "ろ" // IntlRo
        gcCode[GCKeyCode.nonUSBackslash.rawValue] = "§" // 100
        gcCode[GCKeyCode.nonUSPound.rawValue] = "Keypad ," // Doubt: IntlHash and keypad comma not same?
        gcCode[GCKeyCode.LANG2.rawValue] = "英数 한자" // Eisu(alphanumeric) Hanja
        gcCode[GCKeyCode.LANG1.rawValue] = "かな 한/영" // Kana Korean/English
        gcCode[GCKeyCode.F13.rawValue] = "F13"
        gcCode[GCKeyCode.F16.rawValue] = "F16"
        gcCode[GCKeyCode.F14.rawValue] = "F14"
        gcCode[GCKeyCode.application.rawValue] = "Ctx Menu"
        gcCode[GCKeyCode.F15.rawValue] = "F15"
        gcCode[GCKeyCode.insert.rawValue] = "Help"
        gcCode[GCKeyCode.home.rawValue] = "Home"
        gcCode[GCKeyCode.pageUp.rawValue] = "Page Up"
        gcCode[GCKeyCode.deleteForward.rawValue] = "Del Fwd"
        gcCode[GCKeyCode.end.rawValue] = "End"
        gcCode[GCKeyCode.pageDown.rawValue] = "Page Down"
        return gcCode
    }()
}
// Swift lint said the class was too long, so split into two parts
extension KeyCodeNames {
public static let virtualCodes: [UInt16: String] = [
    0: "A",
    11: "B",
    8: "C",
    2: "D",
    14: "E",
    3: "F",
    5: "G",
    4: "H",
    34: "I",
    38: "J",
    40: "K",
    37: "L",
    46: "M",
    45: "N",
    31: "O",
    35: "P",
    12: "Q",
    15: "R",
    1: "S",
    17: "T",
    32: "U",
    9: "V",
    13: "W",
    7: "X",
    16: "Y",
    6: "Z",
    18: "1",
    19: "2",
    20: "3",
    21: "4",
    23: "5",
    22: "6",
    26: "7",
    28: "8",
    25: "9",
    29: "0",
    36: "Enter",
    53: "Esc",
    51: "Del",
    48: "Tab",
    49: "Spc",
    27: "-",
    24: "=",
    33: "[",
    30: "]",
    42: "\\",
    41: ";",
    39: "'",
    50: "`",
    43: ",",
    47: ".",
    44: "/",
    57: "Caps",
    122: "F1",
    120: "F2",
    99: "F3",
    118: "F4",
    96: "F5",
    97: "F6",
    98: "F7",
    100: "F8",
    101: "F9",
    109: "F10",
    103: "F11",
    111: "F12",
    124: "Right",
    123: "Left",
    125: "Down",
    126: "Up",
    10: "§",
    56: "Lshft",
    58: "LOpt",
    55: "LCmd",
    60: "Rshft",
    61: "ROpt",
    54: "RCmd",
    59: "LCtrl",
    62: "RCtrl",
    64: "F17",
    65: "Keypad .",
    67: "Keypad *",
    69: "Keypad +",
    71: "NumLock",
    75: "Keypad /",
    76: "Keypad Enter",
    78: "Keypad -",
    79: "F18",
    80: "F19",
    81: "Keypad =",
    82: "Keypad 0",
    83: "Keypad 1",
    84: "Keypad 2",
    85: "Keypad 3",
    86: "Keypad 4",
    87: "Keypad 5",
    88: "Keypad 6",
    89: "Keypad 7",
    90: "F20",
    91: "Keypad 8",
    92: "Keypad 9",
    93: "¥",
    94: "ろ",
    95: "Keypad ,",
    102: "英数 한자",
    104: "かな 한/영", // Name should match exactly with `keyCodes`
    105: "F13",
    106: "F16",
    107: "F14",
    110: "Ctx Menu",
    113: "F15",
    114: "Help",
    115: "Home",
    116: "Page Up",
    117: "Del Fwd",
    119: "End",
    121: "Page Down"
]
    private static let mapVirtualToGcLiteral: [UInt16: Int] = [
    0: 4,
    1: 22,
    2: 7,
    3: 9,
    4: 11,
    5: 10,
    6: 29,
    7: 27,
    8: 6,
    9: 25,
    11: 5,
    12: 20,
    13: 26,
    14: 8,
    15: 21,
    16: 28,
    17: 23,
    18: 30,
    19: 31,
    20: 32,
    21: 33,
    22: 35,
    23: 34,
    24: 46,
    25: 38,
    26: 36,
    27: 45,
    28: 37,
    29: 39,
    30: 48,
    31: 18,
    32: 24,
    33: 47,
    34: 12,
    35: 19,
    36: 40,
    37: 15,
    38: 13,
    39: 52,
    40: 14,
    41: 51,
    42: 49,
    43: 54,
    44: 56,
    45: 17,
    46: 16,
    47: 55,
    48: 43,
    49: 44,
    50: 53,
    51: 42,
    53: 41,
    54: 231,
    55: 227,
    56: 225,
    57: 57,
    58: 226,
    59: 224,
    60: 229,
    61: 230,
    62: 228,
    96: 62,
    97: 63,
    98: 64,
    99: 60,
    100: 65,
    101: 66,
    103: 68,
    109: 67,
    111: 69,
    118: 61,
    120: 59,
    122: 58,
    123: 80,
    124: 79,
    125: 81,
    126: 82
]
    public static let mapNSEventVirtualCodeToGCKeyCodeRawValue: [UInt16: Int] = {
        var mapVirtualToGc = mapVirtualToGcLiteral
        mapVirtualToGc[10] = GCKeyCode.nonUSBackslash.rawValue
        mapVirtualToGc[64] = GCKeyCode.F17.rawValue
        mapVirtualToGc[65] = GCKeyCode.keypadPeriod.rawValue
        mapVirtualToGc[67] = GCKeyCode.keypadAsterisk.rawValue
        mapVirtualToGc[69] = GCKeyCode.keypadPlus.rawValue
        mapVirtualToGc[71] = GCKeyCode.keypadNumLock.rawValue
        mapVirtualToGc[75] = GCKeyCode.keypadSlash.rawValue
        mapVirtualToGc[76] = GCKeyCode.keypadEnter.rawValue
        mapVirtualToGc[78] = GCKeyCode.keypadHyphen.rawValue
        mapVirtualToGc[79] = GCKeyCode.F18.rawValue
        mapVirtualToGc[80] = GCKeyCode.F19.rawValue
        mapVirtualToGc[81] = GCKeyCode.keypadEqualSign.rawValue
        mapVirtualToGc[82] = GCKeyCode.keypad0.rawValue
        mapVirtualToGc[83] = GCKeyCode.keypad1.rawValue
        mapVirtualToGc[84] = GCKeyCode.keypad2.rawValue
        mapVirtualToGc[85] = GCKeyCode.keypad3.rawValue
        mapVirtualToGc[86] = GCKeyCode.keypad4.rawValue
        mapVirtualToGc[87] = GCKeyCode.keypad5.rawValue
        mapVirtualToGc[88] = GCKeyCode.keypad6.rawValue
        mapVirtualToGc[89] = GCKeyCode.keypad7.rawValue
        mapVirtualToGc[90] = GCKeyCode.F20.rawValue
        mapVirtualToGc[91] = GCKeyCode.keypad8.rawValue
        mapVirtualToGc[92] = GCKeyCode.keypad9.rawValue
        mapVirtualToGc[93] = GCKeyCode.international3.rawValue
        mapVirtualToGc[94] = GCKeyCode.international1.rawValue
        mapVirtualToGc[95] = GCKeyCode.nonUSPound.rawValue
        mapVirtualToGc[102] = GCKeyCode.LANG2.rawValue
        mapVirtualToGc[104] = GCKeyCode.LANG1.rawValue
        mapVirtualToGc[105] = GCKeyCode.F13.rawValue
        mapVirtualToGc[106] = GCKeyCode.F16.rawValue
        mapVirtualToGc[107] = GCKeyCode.F14.rawValue
        mapVirtualToGc[110] = GCKeyCode.application.rawValue
        mapVirtualToGc[113] = GCKeyCode.F15.rawValue
        mapVirtualToGc[114] = GCKeyCode.insert.rawValue
        mapVirtualToGc[115] = GCKeyCode.home.rawValue
        mapVirtualToGc[116] = GCKeyCode.pageUp.rawValue
        mapVirtualToGc[117] = GCKeyCode.deleteForward.rawValue
        mapVirtualToGc[119] = GCKeyCode.end.rawValue
        mapVirtualToGc[121] = GCKeyCode.pageDown.rawValue
        assert(keyCodes.count - 15 == virtualCodes.count)
        return mapVirtualToGc
    }()
}// Swift lint said the file was too long so removing the unused reverse mapping
