import GameController
import SwiftUI

let editor = EditorController.shared

// swiftlint:disable type_body_length
class EditorController {

    static let shared = EditorController()

    private enum KeyCaptureMode {
        case primary
        case modifier
    }

    let lock = NSLock()

    var focusedControl: ControlElement?
    private var keyCaptureMode = KeyCaptureMode.primary

    var editorWindow: UIWindow?
    private var hudWindow: KeymapHUDWindow?
    weak var previousWindow: UIWindow?
    var controls: [ControlElement] = []
    var view: EditorView! {editorWindow?.rootViewController?.view as? EditorView}

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        window.rootViewController = EditorViewController(nibName: nil, bundle: nil)
        return window
    }

    private func addControlToView(control: ControlElement) {
        controls.append(control)
        view.addSubview(control.button)
        if let radialSelector = control as? RadialSelectorModel {
            radialSelector.slotControls.forEach { view.addSubview($0.button) }
        }
        updateFocus(button: control.button)
    }

    public func updateFocus(button: Element) {
        view.setNeedsFocusUpdate()
        view.updateFocusIfNeeded()
        for cntrl in controls {
            cntrl.focus(false)
        }

        if let mod = button.model {
            mod.focus(true)
            focusedControl = mod
            keyCaptureMode = .primary
        }
    }

    public func switchMode() {
        lock.lock()
        if editorMode {
            EditorCircleMenu.shared.hide()
            saveButtons()
            editorWindow?.isHidden = true
            editorWindow?.windowScene = nil
            editorWindow?.rootViewController = nil
            // menu still holds this object until next responder hit test
            editorWindow = nil
            previousWindow?.makeKeyAndVisible()
            focusedControl = nil
            keyCaptureMode = .primary
            Toast.showHint(title: NSLocalizedString("hint.keymapSaved",
                                                    tableName: "Playtools", value: "Keymap Saved", comment: ""))
        } else {
            previousWindow = screen.keyWindow
            editorWindow = initWindow()
            editorWindow?.makeKeyAndVisible()
            showButtons()
            Toast.showHint(title: NSLocalizedString("hint.keymappingEditor.title",
                                                    tableName: "Playtools", value: "Keymapping Editor", comment: ""),
                           text: [NSLocalizedString("hint.keymappingEditor.content",
                                                    tableName: "Playtools",
                                value: "Click a button to edit its position or key bind\n"
                                        + "Click an empty area to open input menu", comment: "")],
                           notification: NSNotification.Name.playtoolsCursorWillHide)
        }
//        Toast.showOver(msg: "\(UIApplication.shared.windows.count)")
        lock.unlock()
    }

    var editorMode: Bool { !(editorWindow?.isHidden ?? true)}
    var hudVisible: Bool { !(hudWindow?.isHidden ?? true)}

    public func toggleHUD() {
        if hudVisible {
            hideHUD()
        } else {
            showHUD()
        }
    }

    public func refreshHUD() {
        guard hudVisible else {
            return
        }
        hudWindow?.rootViewController?.view = KeymapHUDView(map: keymap.currentKeymap)
    }

    private func showHUD() {
        guard let windowScene = screen.windowScene else {
            return
        }
        let window = KeymapHUDWindow(windowScene: windowScene)
        window.rootViewController?.view = KeymapHUDView(map: keymap.currentKeymap)
        window.isHidden = false
        hudWindow = window
        Toast.showHint(title: NSLocalizedString("hint.keymappingHUD.shown",
                                                tableName: "Playtools",
                                                value: "Keymap HUD shown",
                                                comment: ""))
    }

    private func hideHUD() {
        hudWindow?.isHidden = true
        hudWindow?.windowScene = nil
        hudWindow?.rootViewController = nil
        hudWindow = nil
        Toast.showHint(title: NSLocalizedString("hint.keymappingHUD.hidden",
                                                tableName: "Playtools",
                                                value: "Keymap HUD hidden",
                                                comment: ""))
    }

    public func setKey(_ code: Int) {
        if editorMode {
            if keyCaptureMode == .modifier {
                focusedControl?.setModifierKey(code: code)
                finishModifierCapture()
            } else {
                focusedControl?.setKey(code: code)
            }
        }
    }

    public func setKey(_ name: String) {
        if editorMode {
            if keyCaptureMode == .modifier {
                focusedControl?.setModifierKey(name: name)
                finishModifierCapture()
                return
            }
            if name != "Mouse" || focusedControl is MouseAreaModel
                || focusedControl is JoystickModel
                || focusedControl is DraggableButtonModel
                || focusedControl is RadialSelectorModel
                || focusedControl is RadialSelectorSlotControl {
                focusedControl?.setKey(name: name)
            }
        }
    }

    public func captureModifierKey() {
        guard editorMode,
              focusedControl is ButtonModel
                || focusedControl is SwipeModel
                || focusedControl is RadialSelectorModel
                || focusedControl is RadialSelectorSlotControl else {
            Toast.showHint(
                title: NSLocalizedString("hint.keymappingEditor.selectButton.title",
                                         tableName: "Playtools",
                                         value: "Select a button first",
                                         comment: ""),
                text: [NSLocalizedString("hint.keymappingEditor.selectButton.captureModifier.content",
                                         tableName: "Playtools",
                                         value: "Select a button or swipe mapping, then press ⌘M "
                                            + "to set its modifier key.",
                                         comment: "")]
            )
            return
        }
        keyCaptureMode = .modifier
        Toast.showHint(
            title: NSLocalizedString("hint.keymappingEditor.captureModifier.title",
                                     tableName: "Playtools",
                                     value: "Press modifier key",
                                     comment: ""),
            text: [NSLocalizedString("hint.keymappingEditor.captureModifier.content",
                                     tableName: "Playtools",
                                     value: "The next keyboard, mouse, or controller button will become the modifier.",
                                     comment: "")]
        )
    }

    public func clearModifierKey() {
        guard editorMode,
              focusedControl is ButtonModel
                || focusedControl is DraggableButtonModel
                || focusedControl is SwipeModel
                || focusedControl is RadialSelectorModel
                || focusedControl is RadialSelectorSlotControl else {
            Toast.showHint(
                title: NSLocalizedString("hint.keymappingEditor.selectButton.title",
                                         tableName: "Playtools",
                                         value: "Select a button first",
                                         comment: ""),
                text: [NSLocalizedString("hint.keymappingEditor.selectButton.clearModifier.content",
                                         tableName: "Playtools",
                                         value: "Select a button or swipe mapping, then press ⌘⇧M "
                                            + "to clear its modifier key.",
                                         comment: "")]
            )
            return
        }
        focusedControl?.clearModifierKey()
        keyCaptureMode = .primary
        Toast.showHint(title: NSLocalizedString("hint.keymappingEditor.modifierCleared.title",
                                                tableName: "Playtools",
                                                value: "Modifier cleared",
                                                comment: ""))
    }

    public func toggleHoldTrigger() {
        guard editorMode,
              focusedControl is ButtonModel
                || focusedControl is DraggableButtonModel
                || focusedControl is SwipeModel
                || focusedControl is RadialSelectorModel
                || focusedControl is RadialSelectorSlotControl else {
            Toast.showHint(title: NSLocalizedString("hint.keymappingEditor.selectHoldTrigger.title",
                                                    tableName: "Playtools",
                                                    value: "Select a button, swipe, or radial selector first",
                                                    comment: ""))
            return
        }
        focusedControl?.toggleHoldTrigger()
        keyCaptureMode = .primary
        Toast.showHint(title: NSLocalizedString("hint.keymappingEditor.holdTriggerToggled.title",
                                                tableName: "Playtools",
                                                value: "Long-press trigger toggled",
                                                comment: ""))
    }

    private func finishModifierCapture() {
        keyCaptureMode = .primary
        Toast.showHint(
            title: NSLocalizedString("hint.keymappingEditor.modifierSet.title",
                                     tableName: "Playtools",
                                     value: "Modifier set",
                                     comment: ""),
            text: [NSLocalizedString("hint.keymappingEditor.modifierSet.content",
                                     tableName: "Playtools",
                                     value: "Press another key to change the button's main binding.",
                                     comment: "")]
        )
    }

    public func removeControl() {
        keyCaptureMode = .primary
        if let radialSlot = focusedControl as? RadialSelectorSlotControl {
            controls = controls.filter { $0 !== radialSlot.parent }
            radialSlot.parent.remove()
            focusedControl = nil
            return
        }
        controls = controls.filter { $0 !== focusedControl }
        focusedControl?.remove()
    }

    public func cycleSwipeDirection() {
        guard editorMode, focusedControl is SwipeModel else {
            Toast.showHint(
                title: NSLocalizedString("hint.keymappingEditor.selectSwipe.title",
                                         tableName: "Playtools",
                                         value: "Select a swipe first",
                                         comment: ""),
                text: [NSLocalizedString("hint.keymappingEditor.selectSwipe.cycleDirection.content",
                                         tableName: "Playtools",
                                         value: "Select a swipe mapping, then press ⌘R to change its direction.",
                                         comment: "")]
            )
            return
        }
        focusedControl?.cycleDirection()
    }

    func showButtons() {
        for button in keymap.currentKeymap.draggableButtonModels {
            let ctrl = DraggableButtonModel(data: button)
            addControlToView(control: ctrl)
        }
        for joystick in keymap.currentKeymap.joystickModel {
            let ctrl = JoystickModel(data: joystick)
            addControlToView(control: ctrl)
        }
        for mouse in keymap.currentKeymap.mouseAreaModel {
            let ctrl =
                MouseAreaModel(data: mouse)
            addControlToView(control: ctrl)
        }
        for swipe in keymap.currentKeymap.swipeModels {
            let ctrl = SwipeModel(data: swipe)
            addControlToView(control: ctrl)
        }
        for radialSelector in keymap.currentKeymap.radialSelectorModels {
            let ctrl = RadialSelectorModel(data: radialSelector)
            addControlToView(control: ctrl)
        }
        for button in keymap.currentKeymap.buttonModels {
            let ctrl = ButtonModel(data: button)
            addControlToView(control: ctrl)
        }
    }

    func saveButtons() {
        var keymapData = KeymappingData(bundleIdentifier: keymap.bundleIdentifier)
        controls.forEach {
            switch $0 {
            case let model as JoystickModel:
                keymapData.joystickModel.append(model.save())
            // subclasses must be checked first
            case let model as DraggableButtonModel:
                keymapData.draggableButtonModels.append(model.save())
            case let model as MouseAreaModel:
                keymapData.mouseAreaModel.append(model.save())
            case let model as SwipeModel:
                keymapData.swipeModels.append(model.save())
            case let model as RadialSelectorModel:
                keymapData.radialSelectorModels.append(model.save())
            case let model as ButtonModel:
                keymapData.buttonModels.append(model.save())
            default:
                break
            }
        }
        keymap.currentKeymap = keymapData
        controls = []
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    public func addJoystick(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: JoystickModel(data: Joystick(
                upKeyCode: GCKeyCode.keyW.rawValue,
                rightKeyCode: GCKeyCode.keyD.rawValue,
                downKeyCode: GCKeyCode.keyS.rawValue,
                leftKeyCode: GCKeyCode.keyA.rawValue,
                keyName: "Keyboard",
                transform: KeyModelTransform(
                    size: 20, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                ),
                mode: .FIXED
            )))
        }
    }

    private func addButton(keyCode: Int, point: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: Button(
                keyCode: keyCode,
                keyName: KeyCodeNames.keyCodes[keyCode] ?? "Btn",
                transform: KeyModelTransform(
                    size: 5, xCoord: point.x.relativeX, yCoord: point.y.relativeY
                )
            )))
        }
    }

    public func addButton(_ toPoint: CGPoint) {
        self.addLMB(toPoint)
    }

    public func addLMB(_ toPoint: CGPoint) {
        self.addButton(keyCode: -1, point: toPoint)
    }

    public func addMouseJoystick(_ center: CGPoint) {
        if editorMode {
            addControlToView(
                control: JoystickModel(
                    data: Joystick(
                        upKeyCode: GCKeyCode.keyW.rawValue,
                        rightKeyCode: GCKeyCode.keyD.rawValue,
                        downKeyCode: GCKeyCode.keyS.rawValue,
                        leftKeyCode: GCKeyCode.keyA.rawValue,
                        keyName: "Mouse",
                        transform: KeyModelTransform(
                            size: 20, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                        ),
                        mode: .FIXED
                    )
                )
            )
        }
    }

    public func addMouseArea(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: MouseAreaModel(data: MouseArea(
                keyName: "Mouse",
                transform: KeyModelTransform(
                    size: 25, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                )
            )))
        }
    }

    public func addSwipe(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: SwipeModel(data: Swipe(
                keyCode: -1,
                keyName: KeyCodeNames.leftMouseButton,
                transform: KeyModelTransform(
                    size: 12, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                ),
                angle: CGFloat.pi * 3 / 2
            )))
        }
    }

    public func addRadialSelector(_ center: CGPoint) {
        if editorMode {
            let size = CGFloat(12)
            addControlToView(control: RadialSelectorModel(data: RadialSelector(
                keyCode: KeyCodeNames.defaultCode,
                keyName: "Right Thumbstick",
                modifierKeyCode: -12,
                modifierKeyName: "Left Shoulder",
                transform: KeyModelTransform(
                    size: size, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                ),
                activationThreshold: 0.35,
                slots: RadialSelectorModel.makeDefaultSlots(center: center, size: size.absoluteSize)
            )))
        }
    }

    public func addDraggableButton(_ center: CGPoint, _ keyCode: Int) {
        if editorMode {
            addControlToView(control: DraggableButtonModel(data: Button(
                keyCode: keyCode,
                keyName: "Mouse",
                transform: KeyModelTransform(
                    size: 15, xCoord: center.x.relativeX, yCoord: center.y.relativeY
                )
            )))
        }
    }

    func updateEditorText(_ str: String) {
        view.label?.text = str
    }
}
// swiftlint:enable type_body_length
