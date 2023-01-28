import GameController
import SwiftUI

let editor = EditorController.shared

class EditorViewController: UIViewController {
    override func loadView() {
        view = EditorView()
    }
}

class EditorController {

    static let shared = EditorController()

    let lock = NSLock()

    var focusedControl: ControlModel?

    var editorWindow: UIWindow?
    weak var previousWindow: UIWindow?
    var controls: [ControlModel] = []
    var view: EditorView! {editorWindow?.rootViewController?.view as? EditorView}

    private func initWindow() -> UIWindow {
        let window = UIWindow(windowScene: screen.windowScene!)
        window.rootViewController = EditorViewController(nibName: nil, bundle: nil)
        return window
    }

    private func addControlToView(control: ControlModel) {
        controls.append(control)
        view.addSubview(control.button)
        updateFocus(button: control.button)
    }

    public func updateFocus(button: UIButton) {
        view.setNeedsFocusUpdate()
        view.updateFocusIfNeeded()
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
            KeymapHolder.shared.hide()
            saveButtons()
            editorWindow?.isHidden = true
            editorWindow?.windowScene = nil
            editorWindow?.rootViewController = nil
            // menu still holds this object until next responder hit test
            editorWindow = nil
            previousWindow?.makeKeyAndVisible()
            PlayInput.shared.toggleEditor(show: false)
            focusedControl = nil
            Toast.showOver(msg: "Keymapping saved")
        } else {
            PlayInput.shared.toggleEditor(show: true)
            previousWindow = screen.keyWindow
            editorWindow = initWindow()
            editorWindow?.makeKeyAndVisible()
            showButtons()
            Toast.showOver(msg: "Click to start keymmaping edit")
        }
//        Toast.showOver(msg: "\(UIApplication.shared.windows.count)")
        lock.unlock()
    }

    var editorMode: Bool { !(editorWindow?.isHidden ?? true)}

    public func setKey(_ code: Int) {
        if editorMode {
            focusedControl?.setKey(codes: [code])
        }
    }

    public func setKey(_ name: String) {
        if editorMode {
            if name != "Mouse" || focusedControl as? MouseAreaModel != nil
                || focusedControl as? JoystickModel != nil
                || focusedControl as? DraggableButtonModel != nil {
                focusedControl?.setKey(name: name)
            }
        }
    }

    public func removeControl() {
        controls = controls.filter { $0 !== focusedControl }
        focusedControl?.remove()
    }

    func showButtons() {
        for button in keymap.keymapData.draggableButtonModels {
            let ctrl = DraggableButtonModel(data: ControlData(
                keyCodes: [button.keyCode],
                keyName: button.keyName,
                size: button.transform.size,
                xCoord: button.transform.xCoord,
                yCoord: button.transform.yCoord))
            addControlToView(control: ctrl)
        }
        for joystick in keymap.keymapData.joystickModel {
            let ctrl = JoystickModel(data: ControlData(
                keyCodes: [joystick.upKeyCode, joystick.downKeyCode, joystick.leftKeyCode, joystick.rightKeyCode],
                keyName: joystick.keyName,
                size: joystick.transform.size,
                xCoord: joystick.transform.xCoord,
                yCoord: joystick.transform.yCoord))
            addControlToView(control: ctrl)
        }
        for mouse in keymap.keymapData.mouseAreaModel {
            let ctrl =
                MouseAreaModel(data: ControlData(
                    keyName: mouse.keyName,
                    size: mouse.transform.size,
                    xCoord: mouse.transform.xCoord,
                    yCoord: mouse.transform.yCoord))
            addControlToView(control: ctrl)
        }
        for button in keymap.keymapData.buttonModels {
            let ctrl = ButtonModel(data: ControlData(
                keyCodes: [button.keyCode],
                keyName: button.keyName,
                size: button.transform.size,
                xCoord: button.transform.xCoord,
                yCoord: button.transform.yCoord))
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
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    public func addJoystick(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: JoystickModel(data: ControlData(keyCodes: [GCKeyCode.keyW.rawValue,
                                                                                 GCKeyCode.keyS.rawValue,
                                                                                 GCKeyCode.keyA.rawValue,
                                                                                 GCKeyCode.keyD.rawValue],
                                                                      keyName: "Keyboard",
                                                                      size: 20,
                                                                      xCoord: center.x.relativeX,
                                                                      yCoord: center.y.relativeY)))
        }
    }

    private func addButton(keyCode: Int, point: CGPoint) {
        if editorMode {
            addControlToView(control: ButtonModel(data: ControlData(
                keyCodes: [keyCode],
                keyName: KeyCodeNames.keyCodes[keyCode] ?? "Btn",
                size: 5,
                xCoord: point.x.relativeX,
                yCoord: point.y.relativeY)))
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
            addControlToView(control: JoystickModel(data: ControlData(keyCodes: [GCKeyCode.keyW.rawValue,
                                                                                 GCKeyCode.keyS.rawValue,
                                                                                 GCKeyCode.keyA.rawValue,
                                                                                 GCKeyCode.keyD.rawValue],
                                                                      keyName: "Mouse",
                                                                      size: 20,
                                                                      xCoord: center.x.relativeX,
                                                                      yCoord: center.y.relativeY)))
        }
    }

    public func addMouseArea(_ center: CGPoint) {
        if editorMode {
            addControlToView(control: MouseAreaModel(data: ControlData(
                keyName: "Mouse",
                size: 25,
                xCoord: center.x.relativeX,
                yCoord: center.y.relativeY)))
        }
    }

    public func addDraggableButton(_ center: CGPoint, _ keyCode: Int) {
        if editorMode {
            addControlToView(control: DraggableButtonModel(data: ControlData(
                keyCodes: [keyCode],
                keyName: "Mouse",
                size: 15,
                xCoord: center.x,
                yCoord: center.y)))
        }
    }

    func updateEditorText(_ str: String) {
        view.label?.text = str
    }
}

extension UIResponder {
    public var parentViewController: UIViewController? {
        return next as? UIViewController ?? next?.parentViewController
    }
}

class EditorView: UIView {
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let btn = editor.focusedControl?.button {
            return [btn]
        }
        return [self]
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        for control in editor.controls {
            control.update()
        }
    }

    init() {
        super.init(frame: .zero)
        self.frame = screen.screenRect
        self.isUserInteractionEnabled = true
        let single = UITapGestureRecognizer(target: self, action: #selector(self.doubleClick(sender:)))
        single.numberOfTapsRequired = 1
        self.addGestureRecognizer(single)
    }

    @objc func doubleClick(sender: UITapGestureRecognizer) {
        for cntrl in editor.controls {
            cntrl.focus(false)
        }
        editor.focusedControl = nil
        KeymapHolder.shared.add(sender.location(in: self))
    }

    var label: UILabel?

    @objc func pressed(sender: UIButton!) {
        if let button = sender as? Element {
            if editor.focusedControl?.button == nil || editor.focusedControl?.button != button {
                editor.updateFocus(button: sender)
            }
        }
    }

    @objc func dragged(_ sender: UIPanGestureRecognizer) {
        if let ele = sender.view as? Element {
            if editor.focusedControl?.button == nil || editor.focusedControl?.button != ele {
                editor.updateFocus(button: ele)
            }
            let translation = sender.translation(in: self)
            editor.focusedControl?.move(deltaY: translation.y,
                                        deltaX: translation.x)
            sender.setTranslation(CGPoint.zero, in: self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
