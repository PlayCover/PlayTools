import GameController
import SwiftUI

let editor = EditorController.shared

final class EditorController: NSObject {

    static let shared = EditorController()

    let lock = NSLock()

    var focusedControl: ControlModel?

    var editorWindow: UIWindow?
    weak var previousWindow: UIWindow?
    var controls: [ControlModel] = []

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        window.rootViewController = UIHostingController(rootView: KeymapEditor())
        return window
    }

    private func addControlToView(control: ControlModel) {
        controls.append(control)
        updateFocus(button: control.button)
    }

    public func updateFocus(button: UIButton) {
        for cntrl in controls {
            cntrl.focus(false)
        }

        if let mod = (button as? Element)?.model {
            mod.focus(true)
            focusedControl = mod
        }
    }

    public func switchMode() {
        lock.lock()
        if editorMode {
            //KeymapHolder.shared.hide()
            saveButtons()
            editorWindow?.isHidden = true
            editorWindow?.windowScene = nil
            editorWindow?.rootViewController = nil
            // menu still holds this object until next responder hit test
            editorWindow = nil
            previousWindow?.makeKeyAndVisible()
            mode.show(false)
            focusedControl = nil
            // Toast.showOver(msg: "Keymapping saved")
        } else {
            mode.show(true)
            previousWindow = screen.keyWindow
            editorWindow = initWindow()
            editorWindow?.makeKeyAndVisible()
            showButtons()
            // Toast.showOver(msg: "Click to start keymmaping edit")
        }
//        Toast.showOver(msg: "\(UIApplication.shared.windows.count)")
        lock.unlock()
    }

    var editorMode: Bool { !(editorWindow?.isHidden ?? true)}

    public func setKeyCode(_ key: Int) {
        if editorMode {
            focusedControl?.setKeyCodes(keys: [key])
        }
    }

    public func removeControl() {
        controls = controls.filter { $0 !== focusedControl }
        focusedControl?.remove()
    }

    func showButtons() {
        for button in keymap.keymapData.buttonModels {
            let ctrl = ButtonModel(data: ControlData(
                keyCodes: [button.keyCode],
                size: button.transform.size,
                xCoord: button.transform.xCoord,
                yCoord: button.transform.yCoord,
                parent: nil))
            addControlToView(control: ctrl)
        }
        for button in keymap.keymapData.draggableButtonModels {
            let ctrl = DraggableButtonModel(data: ControlData(
                keyCodes: [button.keyCode],
                size: button.transform.size,
                xCoord: button.transform.xCoord,
                yCoord: button.transform.yCoord,
                parent: nil))
            addControlToView(control: ctrl)
        }
        for mouse in keymap.keymapData.mouseAreaModel {
            let ctrl =
                MouseAreaModel(data: ControlData(
                    size: mouse.transform.size,
                    xCoord: mouse.transform.xCoord,
                    yCoord: mouse.transform.yCoord))
            addControlToView(control: ctrl)
        }
        for joystick in keymap.keymapData.joystickModel {
            let ctrl = JoystickModel(data: ControlData(
                keyCodes: [joystick.upKeyCode, joystick.downKeyCode, joystick.leftKeyCode, joystick.rightKeyCode],
                size: joystick.transform.size,
                xCoord: joystick.transform.xCoord,
                yCoord: joystick.transform.yCoord))
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
            case let model as ButtonModel:
                keymapData.buttonModels.append(model.save())
            default:
                break
            }
        }
        keymap.keymapData = keymapData
        controls = []
    }

    @objc public func addJoystick(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: JoystickModel(data: ControlData(keyCodes: [GCKeyCode.keyW.rawValue,
                                                                                 GCKeyCode.keyS.rawValue,
                                                                                 GCKeyCode.keyA.rawValue,
                                                                                 GCKeyCode.keyD.rawValue],
                                                                      size: 20,
                                                                      xCoord: center.x.relativeX,
                                                                      yCoord: center.y.relativeY)))
        }
    }

    @objc public func addButton(_ toPoint: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: ControlData(keyCodes: [-1],
                                                                    size: 5,
                                                                    xCoord: toPoint.x.relativeX,
                                                                    yCoord: toPoint.y.relativeY,
                                                                    parent: nil)))
        }
    }

    @objc public func addRMB(_ toPoint: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: ControlData(keyCodes: [-2],
                                                                 size: 5,
                                                                 xCoord: toPoint.x.relativeX,
                                                                 yCoord: toPoint.y.relativeY,
                                                                 parent: nil)))
        }
    }

    @objc public func addLMB(_ toPoint: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: ControlData(keyCodes: [-1],
                                                                 size: 5,
                                                                 xCoord: toPoint.x.relativeX,
                                                                 yCoord: toPoint.y.relativeY,
                                                                 parent: nil)))
        }
    }

    @objc public func addMMB(_ toPoint: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: ControlData(keyCodes: [-3],
                                                                 size: 5,
                                                                 xCoord: toPoint.x.relativeX,
                                                                 yCoord: toPoint.y.relativeY,
                                                                 parent: nil)))
        }
    }

    @objc public func addMouseArea(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: MouseAreaModel(data: ControlData(size: 25,
                                                                       xCoord: center.x.relativeX,
                                                                       yCoord: center.y.relativeY)))
        }
    }

    @objc public func addDraggableButton(_ center: CGPoint, _ keyCode: Int) {
        if editorMode {
            addControlToView(control: DraggableButtonModel(data: ControlData(keyCodes: [keyCode],
                                                                       size: 15,
                                                                       xCoord: center.x,
                                                                       yCoord: center.y)))
        }
    }
}

extension UIResponder {
    public var parentViewController: UIViewController? {
        return next as? UIViewController ?? next?.parentViewController
    }
}
