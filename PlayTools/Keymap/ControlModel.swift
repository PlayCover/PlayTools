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

class Element: UIButton {
    var model: ControlModel?
}

class ControlModel {

    var data: ControlData
    var button: Element

    func update() {}

    func focus(_ focus: Bool) {
        if focus {
            button.layer.borderWidth = 3
            button.layer.borderColor = UIColor.systemPink.cgColor
            button.setNeedsDisplay()
        } else {
            button.layer.borderWidth = 0
            button.setNeedsDisplay()
        }
    }

    func unfocusChildren() {}

    init(data: ControlData) {
        button = Element()
        self.data = data
        button.model = self
        button.backgroundColor = UIColor.gray.withAlphaComponent(0.8)
        button.addTarget(editor.view, action: #selector(editor.view.pressed(sender:)), for: .touchUpInside)
        let recognizer = UIPanGestureRecognizer(target: editor.view, action: #selector(editor.view.dragged(_:)))
        button.addGestureRecognizer(recognizer)
        button.isUserInteractionEnabled = true
    }

    func remove() {
        self.button.removeFromSuperview()
    }

    func move(deltaY: CGFloat, deltaX: CGFloat) {
        let newX = button.center.x + deltaX
        let newY = button.center.y + deltaY
        if newX > 0 && newX < screen.width {
            data.xCoord = newX.relativeX
        }
        if newY > 0 && newY < screen.height {
            data.yCoord = newY.relativeY
        }
        update()
    }

    func resize(down: Bool) {
        let mod = down ? 0.9 : 1/0.9
        data.size = (button.frame.width * CGFloat(mod)).relativeSize
        update()
    }

    func setKey(codes: [Int], name: String) {}

    func setKey(codes: [Int]) {
        self.setKey(codes: codes, name: KeyCodeNames.keyCodes[codes[0]] ?? "Btn")
    }

    func setKey(name: String) {
        self.setKey(codes: [KeyCodeNames.defaultCode], name: name)
    }
}

class ButtonModel: ControlModel {

    override init(data: ControlData) {
        super.init(data: data)
        update()
    }

    func save() -> Button {
        Button(
            keyCode: data.keyCodes[0], keyName: data.keyName,
            transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func update() {
        self.setKey(codes: data.keyCodes, name: data.keyName)
        button.setWidth(width: data.size.absoluteSize)
        button.setHeight(height: data.size.absoluteSize)
        button.setX(xCoord: data.xCoord.absoluteX)
        button.setY(yCoord: data.yCoord.absoluteY)
        button.layer.cornerRadius = 0.5 * button.bounds.size.width
        button.clipsToBounds = true
        button.titleLabel?.minimumScaleFactor = 0.01
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.textAlignment = .center
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
    }

    override func setKey(codes: [Int], name: String) {
        data.keyCodes = codes
        data.keyName = name
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }
}

class JoystickButtonModel: ControlModel {
    override init(data: ControlData) {
        super.init(data: data)
        self.setKey(codes: data.keyCodes)
        data.parent?.button.addSubview(button)
    }

    override func remove() {
        data.parent?.button.removeFromSuperview()
    }

    override func setKey(codes: [Int], name: String) {
        data.keyCodes = codes
        data.keyName = name
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }

    override func move(deltaY: CGFloat, deltaX: CGFloat) {
        data.parent?.button.model?.move(deltaY: deltaY, deltaX: deltaX)
    }

    override func resize(down: Bool) {
        if let parentButton = data.parent?.button {
            parentButton.model?.resize(down: down)
        }
    }

    override func focus(_ focus: Bool) {
        if focus {
            data.parent?.unfocusChildren()
        }
        super.focus(focus)
    }
}

class DraggableButtonModel: MouseAreaModel {
    var childButton: JoystickButtonModel?

    func save() -> Button {
        return Button(keyCode: childButton!.data.keyCodes[0], keyName: data.keyName,
                               transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func setKey(codes: [Int], name: String) {
        let code = codes[0]
        if code == KeyCodeNames.defaultCode {
            self.data.keyName = name
            button.setTitle(data.keyName, for: UIControl.State.normal)
        } else {
            childButton!.setKey(codes: codes)
        }
    }
    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            childButton?.focus(false)
        }
    }
    override func update() {
        super.update()
        self.button.titleEdgeInsets = UIEdgeInsets(top: data.size.absoluteSize / 2, left: 0, bottom: 0, right: 0)
        if childButton == nil {
            // temporarily, cannot map controller keys to draggable buttons
            // `data.keyName` is the key for the move area, not that of the button key.
            childButton = JoystickButtonModel(data: ControlData(
                keyCodes: [data.keyCodes[0]], parent: self))
        }
        let btn = childButton!.button
        let buttonSize = data.size.absoluteSize / 3
        let coord = (button.frame.width - buttonSize) / 2
        btn.frame = CGRect(x: coord, y: coord, width: buttonSize, height: buttonSize)
        btn.layer.cornerRadius = 0.5 * btn.bounds.size.width
    }
}

class JoystickModel: ControlModel {
    var joystickButtons = [JoystickButtonModel]()

    func save() -> Joystick {
        Joystick(
            upKeyCode: joystickButtons[0].data.keyCodes[0],
            rightKeyCode: joystickButtons[3].data.keyCodes[0],
            downKeyCode: joystickButtons[1].data.keyCodes[0],
            leftKeyCode: joystickButtons[2].data.keyCodes[0],
            keyName: self.data.keyName,
            transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override init(data: ControlData) {
        super.init(data: data)
        update()
    }

    override func update() {
        button.setWidth(width: data.size.absoluteSize)
        button.setHeight(height: data.size.absoluteSize)
        button.setX(xCoord: data.xCoord.absoluteX)
        button.setY(yCoord: data.yCoord.absoluteY)
        button.layer.cornerRadius = 0.3 * button.bounds.size.width
        button.clipsToBounds = true
        if data.keyCodes.count == 4 && joystickButtons.count == 0 {
            for keyCode in data.keyCodes {
                // joystick buttons cannot be mapped to controller keys.
                // Instead, map a real joystick to the joystick as a whole.
                joystickButtons.append(JoystickButtonModel(data: ControlData(
                    keyCodes: [keyCode], parent: self)))
            }
        }
        self.setKey(name: data.keyName)
        changeButtonsSize()
    }

    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            unfocusChildren()
        }
    }

    override func unfocusChildren() {
        for joystickButton in joystickButtons {
            joystickButton.focus(false)
        }
    }

    override func setKey(codes: [Int], name: String) {
        if codes[0] < 0 && name != "Keyboard" {
            if name.hasSuffix("tick") {
                self.data.keyName = name
            } else {
                self.data.keyName = "Mouse"
            }
            button.setTitle(data.keyName, for: UIControl.State.normal)
            for btn in joystickButtons {
                btn.button.isHidden = true
            }
        } else {
            self.data.keyName = "Keyboard"
            button.setTitle("", for: UIControl.State.normal)
            for btn in joystickButtons {
                btn.button.isHidden = false
            }
        }
    }

    func changeButtonsSize() {
        let btns = button.subviews
        let buttonSize = data.size.absoluteSize / 3
        let xCoord1 = (button.frame.width / 2) - buttonSize / 2
        let yCoord1 = buttonSize / 4.5
        let xCoord2 = (button.frame.width / 2) - buttonSize / 2
        let yCoord2 = button.frame.width - buttonSize - buttonSize / 4.5
        if btns.count == 4 {
            btns[0].frame = CGRect(x: xCoord1, y: yCoord1, width: buttonSize, height: buttonSize)
            btns[1].frame = CGRect(x: xCoord2, y: yCoord2, width: buttonSize, height: buttonSize)
            btns[2].frame = CGRect(x: yCoord1, y: xCoord1, width: buttonSize, height: buttonSize)
            btns[3].frame = CGRect(x: yCoord2, y: xCoord2, width: buttonSize, height: buttonSize)
            btns[0].layer.cornerRadius = 0.5 * btns[0].bounds.size.width
            btns[1].layer.cornerRadius = 0.5 * btns[1].bounds.size.width
            btns[2].layer.cornerRadius = 0.5 * btns[2].bounds.size.width
            btns[3].layer.cornerRadius = 0.5 * btns[3].bounds.size.width
        }
    }
}

class MouseAreaModel: ControlModel {
    func save() -> MouseArea {
        MouseArea(keyName: data.keyName,
                  transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func update() {
        button.setWidth(width: data.size.absoluteSize)
        button.setHeight(height: data.size.absoluteSize)
        button.setX(xCoord: data.xCoord.absoluteX)
        button.setY(yCoord: data.yCoord.absoluteY)
        button.layer.cornerRadius = 0.5 * button.bounds.size.width
        button.clipsToBounds = true
        setKey(name: data.keyName)
    }

    private func setDraggableButton(code: Int) {
        EditorController.shared.removeControl()
        EditorController.shared.addDraggableButton(CGPoint(x: data.xCoord, y: data.yCoord), code)
    }

    override func setKey(codes: [Int], name: String) {
        let code = codes[0]
        if code < 0 {
            if name.hasSuffix("tick") {
                self.data.keyName = name
            } else {
                self.data.keyName = "Mouse"
            }
        } else {
            self.setDraggableButton(code: code)
        }
        button.setTitle(data.keyName, for: UIControl.State.normal)
    }

    override init(data: ControlData) {
        super.init(data: data)
        update()
    }
}

extension UIView {
    func setX(xCoord: CGFloat) {
        self.center = CGPoint(x: xCoord, y: self.center.y)
    }

    func setY(yCoord: CGFloat) {
        self.center = CGPoint(x: self.center.x, y: yCoord)
    }

    func setWidth(width: CGFloat) {
        var frame: CGRect = self.frame
        frame.size.width = width
        self.frame = frame
    }

    func setHeight(height: CGFloat) {
        var frame: CGRect = self.frame
        frame.size.height = height
        self.frame = frame
    }
}
