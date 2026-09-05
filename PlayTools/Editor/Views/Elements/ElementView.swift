//
//  EditorElement.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/26.
//

import Foundation
class Element: UIButton {
    weak var model: ControlElement?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    func commonInit() {
        backgroundColor = UIColor.gray.withAlphaComponent(0.8)
        addTarget(editor.view, action: #selector(editor.view.pressed(sender:)), for: .touchUpInside)
        let recognizer = UIPanGestureRecognizer(target: editor.view, action: #selector(editor.view.dragged(_:)))
        addGestureRecognizer(recognizer)
        isUserInteractionEnabled = true
        clipsToBounds = true
        titleLabel?.minimumScaleFactor = 0.01
        titleLabel?.numberOfLines = 2
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.textAlignment = .center
        configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        update()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func update() {
        layer.cornerRadius = 0.5 * bounds.size.width
    }

    func setCenterXY(newX: CGFloat, newY: CGFloat) {
        self.center = CGPoint(x: newX, y: newY)
    }

    func setSize(newSize: CGFloat) {
        let center = self.center
        setWidth(width: newSize)
        setHeight(height: newSize)
        self.center = center
        update()
    }

    func focus(_ focus: Bool) {
        if focus {
            layer.borderWidth = 3
            layer.borderColor = UIColor.systemPink.cgColor
            setNeedsDisplay()
        } else {
            layer.borderWidth = 0
            setNeedsDisplay()
        }
    }
}

class SwipeElement: Element {
    private let lineLayer = CAShapeLayer()
    private let startLayer = CAShapeLayer()
    private let endLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()

    override func commonInit() {
        super.commonInit()
        backgroundColor = .clear
        clipsToBounds = false
        layer.masksToBounds = false
        titleLabel?.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        titleLabel?.layer.cornerRadius = 6
        titleLabel?.clipsToBounds = true
        titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)

        lineLayer.fillColor = UIColor.clear.cgColor
        lineLayer.lineCap = .round
        lineLayer.lineWidth = 4
        startLayer.fillColor = UIColor.systemTeal.cgColor
        endLayer.fillColor = UIColor.systemPink.cgColor
        arrowLayer.fillColor = UIColor.systemPink.cgColor

        layer.insertSublayer(lineLayer, at: 0)
        layer.insertSublayer(startLayer, at: 0)
        layer.insertSublayer(endLayer, at: 0)
        layer.insertSublayer(arrowLayer, at: 0)
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    override func update() {
        layer.cornerRadius = 0
        updateSwipePath(isFocused: layer.borderWidth > 0)
    }

    override func focus(_ focus: Bool) {
        layer.borderWidth = 0
        updateSwipePath(isFocused: focus)
    }

    private func updateSwipePath(isFocused: Bool) {
        guard let swipeModel = model as? SwipeModel else {
            return
        }

        let start = CGPoint(x: bounds.midX, y: bounds.midY)
        let length = max(bounds.width, 32)
        let angle = swipeModel.data.angle
        let end = CGPoint(
            x: start.x + cos(angle) * length,
            y: start.y + sin(angle) * length
        )

        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        lineLayer.path = path.cgPath
        lineLayer.strokeColor = (isFocused ? UIColor.systemYellow : UIColor.systemPink).cgColor
        lineLayer.lineWidth = isFocused ? 6 : 4

        startLayer.path = UIBezierPath(
            ovalIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)
        ).cgPath
        endLayer.path = UIBezierPath(
            ovalIn: CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)
        ).cgPath

        let arrowLength: CGFloat = 14
        let arrowSpread: CGFloat = .pi / 7
        let left = CGPoint(
            x: end.x - cos(angle - arrowSpread) * arrowLength,
            y: end.y - sin(angle - arrowSpread) * arrowLength
        )
        let right = CGPoint(
            x: end.x - cos(angle + arrowSpread) * arrowLength,
            y: end.y - sin(angle + arrowSpread) * arrowLength
        )
        let arrowPath = UIBezierPath()
        arrowPath.move(to: end)
        arrowPath.addLine(to: left)
        arrowPath.addLine(to: right)
        arrowPath.close()
        arrowLayer.path = arrowPath.cgPath
    }
}

class RadialSelectorElement: Element {
    private let ringLayer = CAShapeLayer()
    private let activeRingLayer = CAShapeLayer()
    private var spokeLayers = [CAShapeLayer]()

    override func commonInit() {
        super.commonInit()
        backgroundColor = UIColor.black.withAlphaComponent(0.8)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.8).cgColor
        ringLayer.lineWidth = 3

        activeRingLayer.fillColor = UIColor.systemPink.withAlphaComponent(0.18).cgColor
        activeRingLayer.strokeColor = UIColor.systemPink.cgColor
        activeRingLayer.lineWidth = 3

        layer.insertSublayer(activeRingLayer, at: 0)
        layer.insertSublayer(ringLayer, at: 0)
        (0..<RadialSelectorModel.defaultSlots.count).forEach { _ in
            let spoke = CAShapeLayer()
            spoke.fillColor = UIColor.clear.cgColor
            spoke.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            spoke.lineWidth = 2
            layer.insertSublayer(spoke, at: 0)
            spokeLayers.append(spoke)
        }
        titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    override func update() {
        super.update()
        layer.cornerRadius = bounds.width / 2
        let inset = max(bounds.width * 0.12, 4)
        let ringRect = bounds.insetBy(dx: inset, dy: inset)
        let ringPath = UIBezierPath(ovalIn: ringRect)
        ringLayer.path = ringPath.cgPath
        activeRingLayer.path = ringPath.cgPath

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = ringRect.width / 2
        for (index, spoke) in spokeLayers.enumerated() {
            let angle = RadialSelectorModel.defaultSlots[index].angle
            let end = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let path = UIBezierPath()
            path.move(to: center)
            path.addLine(to: end)
            spoke.path = path.cgPath
        }
    }

    override func focus(_ focus: Bool) {
        layer.borderWidth = 0
        activeRingLayer.isHidden = !focus
        ringLayer.strokeColor = (focus ? UIColor.systemYellow : UIColor.systemTeal.withAlphaComponent(0.8)).cgColor
    }
}

class RadialSelectorSlotElement: Element {
    override func commonInit() {
        super.commonInit()
        backgroundColor = UIColor.black.withAlphaComponent(0.8)
        titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
    }

    override func update() {
        super.update()
        layer.cornerRadius = bounds.width / 2
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
