import GameController

class ControlData {
    var keyCodes: [Int]
    var size: CGFloat
    var xCoord: CGFloat
    var yCoord: CGFloat
    var parent: ControlModel?

    init(keyCodes: [Int], size: CGFloat, xCoord: CGFloat, yCoord: CGFloat, parent: ControlModel?) {
        self.keyCodes = keyCodes
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.parent = parent
    }

    init(keyCodes: [Int], size: CGFloat, xCoord: CGFloat, yCoord: CGFloat, sensitivity: CGFloat) {
        self.keyCodes = keyCodes
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
    }

    init(keyCodes: [Int], parent: ControlModel) {
        self.keyCodes = keyCodes
        self.size = parent.data.size  / 3
        self.xCoord = 0
        self.yCoord = 0
        self.parent = parent
    }

    init(size: CGFloat, xCoord: CGFloat, yCoord: CGFloat) {
        self.keyCodes = [0]
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.parent = nil
    }

    init(keyCodes: [Int], size: CGFloat, xCoord: CGFloat, yCoord: CGFloat) {
        self.keyCodes = keyCodes
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

    func focus(_ focus: Bool) {}

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
        let mod = down ? 0.9 : 1.1
        data.size = (button.frame.width * CGFloat(mod)).relativeSize
        update()
    }

    func setKeyCodes(keys: [Int]) {}
}

class ButtonModel: ControlModel {

    override init(data: ControlData) {
        super.init(data: data)
        update()
    }

    func save() -> Button {
        Button(
            keyCode: data.keyCodes[0],
            transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func update() {
        self.setKeyCodes(keys: data.keyCodes)
        button.setWidth(width: data.size.absoluteSize)
        button.setHeight(height: data.size.absoluteSize)
        button.setX(xCoord: data.xCoord.absoluteX)
        button.setY(yCoord: data.yCoord.absoluteY)
        button.layer.cornerRadius = 0.5 * button.bounds.size.width
        button.clipsToBounds = true
        button.titleLabel?.minimumScaleFactor = 0.01
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.textAlignment = .center
        button.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
    }

    override func focus(_ focus: Bool) {
        if focus {
            button.layer.borderWidth = 3
            button.layer.borderColor = UIColor.systemPink.cgColor
            button.setNeedsDisplay()
        } else {
            button.layer.borderWidth = 0
            button.setNeedsDisplay()
        }
    }

    override func setKeyCodes(keys: [Int]) {
        data.keyCodes = keys
        if let title = KeyCodeNames.keyCodes[keys[0]] {
            button.setTitle(title, for: UIControl.State.normal)
        } else {
            button.setTitle("Btn", for: UIControl.State.normal)
        }
    }
}

class JoystickButtonModel: ControlModel {
    override init(data: ControlData) {
        super.init(data: data)
        self.setKeyCodes(keys: data.keyCodes)
        data.parent?.button.addSubview(button)
    }

    override func remove() {
        data.parent?.button.removeFromSuperview()
    }

    override func setKeyCodes(keys: [Int]) {
        data.keyCodes = keys
        if let title = KeyCodeNames.keyCodes[keys[0]] {
            button.setTitle(title, for: UIControl.State.normal)
        } else {
            button.setTitle("Btn", for: UIControl.State.normal)
        }
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
            button.layer.borderWidth = 3
            button.layer.borderColor = UIColor.systemPink.cgColor
            button.setNeedsDisplay()
        } else {
            button.layer.borderWidth = 0
            button.setNeedsDisplay()
        }
    }
}

class DraggableButtonModel: MouseAreaModel {
    var childButton: JoystickButtonModel?

    func save() -> Button {
        return Button(keyCode: childButton!.data.keyCodes[0],
                               transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func setKeyCodes(keys: [Int]) {
        childButton!.setKeyCodes(keys: keys)
    }
    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            childButton?.focus(false)
        }
    }
    override func update() {
        super.update()
        if childButton == nil {
            childButton = JoystickButtonModel(data: ControlData(keyCodes: [data.keyCodes[0]], parent: self))
        }
        let btn = button.subviews[0]
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
        button.layer.cornerRadius = 0.5 * button.bounds.size.width
        button.clipsToBounds = true
        if data.keyCodes.count == 4 && joystickButtons.count == 0 {
            for keyCode in data.keyCodes {
                joystickButtons.append(JoystickButtonModel(data: ControlData(keyCodes: [keyCode], parent: self)))
            }
        }
        changeButtonsSize()
    }

    override func focus(_ focus: Bool) {
        if focus {
            button.layer.borderWidth = 3
            button.layer.borderColor = UIColor.systemPink.cgColor
            button.setNeedsDisplay()
        } else {
            button.layer.borderWidth = 0
            button.setNeedsDisplay()
            unfocusChildren()
        }
    }

    override func unfocusChildren() {
        for joystickButton in joystickButtons {
            joystickButton.focus(false)
        }
    }

    override func setKeyCodes(keys: [Int]) {
        // I'm trying to be an easter egg
        Toast.showOver(msg: "U~w~U")
    }

    override func resize(down: Bool) {
        let mod = down ? 0.9 : 1.1
        data.size = (button.frame.width * CGFloat(mod)).relativeSize
        update()
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
        MouseArea(transform: KeyModelTransform(size: data.size, xCoord: data.xCoord, yCoord: data.yCoord))
    }

    override func focus(_ focus: Bool) {
        if focus {
            button.layer.borderWidth = 3
            button.layer.borderColor = UIColor.systemPink.cgColor
            button.setNeedsDisplay()
        } else {
            button.layer.borderWidth = 0
            button.setNeedsDisplay()
        }
    }

    override func update() {
        button.setWidth(width: data.size.absoluteSize)
        button.setHeight(height: data.size.absoluteSize)
        button.setX(xCoord: data.xCoord.absoluteX)
        button.setY(yCoord: data.yCoord.absoluteY)
        button.layer.cornerRadius = 0.5 * button.bounds.size.width
        button.clipsToBounds = true
    }

    override func setKeyCodes(keys: [Int]) {
        EditorController.shared.removeControl()
        EditorController.shared.addDraggableButton(CGPoint(x: data.xCoord, y: data.yCoord), keys[0])
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
