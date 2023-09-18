//
//  ActionDispatcher.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// If the same key is mapped to multiple different tasks, distinguish by priority
public class ActionDispatchPriority {
    static public let DRAGGABLE = 0
    static public let DEFAULT = 1
    static public let CAMERA = 2
}

// This class reads keymap and thereby dispatch events

public class ActionDispatcher {
    static private let keymapVersion = "2.0."
    static private var actions = [Action]()
    static private let PRIORITY_COUNT = 3
    static private var buttonHandlers: [String: [(Bool) -> Void]] = [:],
                       directionPadHandlers: [[String: (CGFloat, CGFloat) -> Void]] = Array(
                        repeating: [:], count: PRIORITY_COUNT)

    static private func clear() {
        invalidateActions()
        actions = []
        buttonHandlers.removeAll(keepingCapacity: true)
        for priority in 0..<PRIORITY_COUNT {
            directionPadHandlers[priority].removeAll(keepingCapacity: true)
        }
    }

    // Backend interfaces

    // This should be called whenever keymap may change
    static public func build() {
        clear()

        actions.append(FakeMouseAction())

        // current keymap version is 2.0.x.
        // in future, keymap format will be upgraded.
        // PlayTools would maintain limited backwards compatibility.
        // Meanwhile, keymap format upgrade would be rare.
        if !keymap.keymapData.version.hasPrefix(keymapVersion) {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .seconds(5)) {
                    Toast.showHint(title: "Keymap format too new",
                       text: ["Current keymap version \(keymap.keymapData.version)" +
                              " is too new and cannot be recognized\n" +
                             "For protection of your data, keymap is not loaded\n" +
                             "Please upgrade PlayCover, " +
                              "or import an older version of keymap (requires \(keymapVersion)x"])
            }
            return
        }

        for button in keymap.keymapData.buttonModels {
            actions.append(ButtonAction(data: button))
        }

        for draggableButton in keymap.keymapData.draggableButtonModels {
            actions.append(DraggableButtonAction(data: draggableButton))
        }

        for mouse in keymap.keymapData.mouseAreaModel {
            actions.append(CameraAction(data: mouse))
        }

        for joystick in keymap.keymapData.joystickModel {
            // Left Thumbstick, Right Thumbstick, Mouse
            if joystick.keyName.contains(Character("u")) {
                actions.append(ContinuousJoystickAction(data: joystick))
            } else { // Keyboard
                actions.append(JoystickAction(data: joystick))
            }
        }
        // `cursorHideNecessary` is used to disable `option` toggle when there is no mouse mapping
        // but in the case this new feature disabled, `option` should always function.
        // this variable is set here to be checked for mouse mapping later.
        cursorHideNecessary =
        (
            getDispatchPriority(key: KeyCodeNames.leftMouseButton) ?? ActionDispatchPriority.DRAGGABLE
        )
            > ActionDispatchPriority.DRAGGABLE ||
        (
            getDispatchPriority(key: KeyCodeNames.mouseMove) ?? ActionDispatchPriority.DRAGGABLE
        )
            > ActionDispatchPriority.DRAGGABLE
    }

    static public func register(key: String, handler: @escaping (Bool) -> Void) {
        // this function is called when setting up `button` type of mapping
        if buttonHandlers[key] == nil {
            buttonHandlers[key] = []
        }
        buttonHandlers[key]!.append(handler)
    }

    static public func register(key: String,
                                handler: @escaping (CGFloat, CGFloat) -> Void,
                                priority: Int = ActionDispatchPriority.DEFAULT) {
        directionPadHandlers[priority][key] = handler
    }

    static public func unregister(key: String) {
        // Only draggable can be unregistered
        directionPadHandlers[ActionDispatchPriority.DRAGGABLE].removeValue(forKey: key)
    }

    // Frontend interfaces

    static public var cursorHideNecessary = true

    static public func invalidateActions() {
        for action in actions {
            // This is just a rescue feature, in case any key stuck pressed for any reason
            // Might be called on control mode state transition
            action.invalidate()
        }
    }

    static public func getDispatchPriority(key: String) -> Int? {
        for priority in 0..<PRIORITY_COUNT
            where directionPadHandlers[priority][key] != nil {
            return priority
        }

        if buttonHandlers[key] != nil {
            return ActionDispatchPriority.DEFAULT
        }
        return nil
    }

    static public func dispatch(key: String, pressed: Bool) -> Bool {
        guard let handlers = buttonHandlers[key] else {
            return false
        }
        var mapped = false
        for handler in handlers {
            PlayInput.touchQueue.async(qos: .userInteractive, execute: {
                handler(pressed)
            })
            mapped = true
        }
        // return value matters. A false value makes a beep sound
        return mapped
    }

    static public func dispatch(key: String, valueX: CGFloat, valueY: CGFloat) -> Bool {
        // WARNING: if you want to change this, beware of concurrency contention
        PlayInput.touchQueue.async(qos: .userInteractive, execute: {
            for priority in 0..<PRIORITY_COUNT
            where directionPadHandlers[priority][key] != nil {
                directionPadHandlers[priority][key]!(valueX, valueY)
                return
            }
        })
        return getDispatchPriority(key: key) != nil
    }
}
