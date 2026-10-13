import UIKit

final class KeymapHUDWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        rootViewController = UIViewController()
        windowLevel = .statusBar + 1
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class KeymapHUDView: UIView {
    private let map: KeymappingData
    private let opacity: CGFloat

    init(map: KeymappingData) {
        self.map = map
        self.opacity = Self.normalizedOpacity(map.hudOpacity)
        super.init(frame: screen.screenRect)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        buildLabels()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func normalizedOpacity(_ value: CGFloat?) -> CGFloat {
        min(max(value ?? 0.4, 0.1), 1.0)
    }

    private func buildLabels() {
        map.buttonModels.forEach { addLabel(title: title(for: $0), transform: $0.transform) }
        map.draggableButtonModels.forEach {
            addLabel(title: title(for: $0), transform: $0.transform, style: .drag)
        }
        map.swipeModels.forEach {
            addLabel(title: swipeTitle(for: $0), transform: $0.transform, style: .swipe)
        }
        map.joystickModel.forEach {
            addLabel(title: joystickTitle(for: $0), transform: $0.transform, style: .area)
        }
        map.mouseAreaModel.forEach {
            addLabel(title: ButtonModel.displayName(for: $0.keyName), transform: $0.transform, style: .area)
        }
    }

    private enum LabelStyle {
        case button
        case drag
        case swipe
        case area

        var color: UIColor {
            switch self {
            case .button:
                return .darkGray
            case .drag:
                return .systemBlue
            case .swipe:
                return .systemPink
            case .area:
                return .black
            }
        }
    }

    private func addLabel(title: String, transform: KeyModelTransform, style: LabelStyle = .button) {
        let size = labelSize(for: title, transform: transform, style: style)
        let label = UILabel(frame: CGRect(origin: .zero, size: size))
        label.center = CGPoint(x: transform.xCoord.absoluteX, y: transform.yCoord.absoluteY)
        label.text = title
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: fontSize(for: style), weight: .bold)
        label.numberOfLines = 2
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.55
        label.backgroundColor = style.color.withAlphaComponent(opacity)
        label.layer.cornerRadius = cornerRadius(for: size, style: style)
        label.layer.borderWidth = 0
        label.clipsToBounds = true
        addSubview(label)
    }

    private func labelSize(for title: String, transform: KeyModelTransform, style: LabelStyle) -> CGSize {
        switch style {
        case .swipe:
            return CGSize(width: 78, height: 48)
        case .area:
            return CGSize(width: 86, height: 40)
        case .button, .drag:
            let baseSize = min(max(transform.size.absoluteSize, 52), 76)
            let width = title.contains("+") ? max(baseSize, 68) : baseSize
            return CGSize(width: width, height: baseSize)
        }
    }

    private func fontSize(for style: LabelStyle) -> CGFloat {
        switch style {
        case .area:
            return 16
        case .swipe:
            return 17
        case .button, .drag:
            return 16
        }
    }

    private func cornerRadius(for size: CGSize, style: LabelStyle) -> CGFloat {
        switch style {
        case .swipe:
            return 14
        case .area:
            return size.height / 2
        case .button, .drag:
            return min(size.width, size.height) / 2
        }
    }

    private func title(for button: Button) -> String {
        let keyName = ButtonModel.displayName(for: button.keyName)
        let holdPrefix = button.holdDuration == nil ? "" : "Hold "
        guard let modifierName = button.modifierKeyName, !modifierName.isEmpty else {
            return "\(holdPrefix)\(keyName)"
        }
        return "\(holdPrefix)\(ButtonModel.displayName(for: modifierName))+\n\(keyName)"
    }

    private func swipeTitle(for swipe: Swipe) -> String {
        let keyName = title(for: Button(keyCode: swipe.keyCode,
                                       keyName: swipe.keyName,
                                       modifierKeyCode: swipe.modifierKeyCode,
                                       modifierKeyName: swipe.modifierKeyName,
                                       holdDuration: swipe.holdDuration,
                                       transform: swipe.transform))
        return "\(directionArrow(for: swipe.angle))\n\(keyName)"
    }

    private func joystickTitle(for joystick: Joystick) -> String {
        switch joystick.keyName {
        case "Left Thumbstick":
            return "LS"
        case "Right Thumbstick":
            return "RS"
        case "Mouse":
            return "Mouse"
        default:
            return ButtonModel.displayName(for: joystick.keyName)
        }
    }

    private func directionArrow(for angle: CGFloat) -> String {
        let twoPi = CGFloat.pi * 2
        let normalized = angle.truncatingRemainder(dividingBy: twoPi) + (angle < 0 ? twoPi : 0)
        let directions: [(CGFloat, String)] = [
            (0, "→"),
            (CGFloat.pi / 2, "↓"),
            (CGFloat.pi, "←"),
            (CGFloat.pi * 3 / 2, "↑")
        ]
        return directions.min {
            angularDistance($0.0, normalized) < angularDistance($1.0, normalized)
        }?.1 ?? "↑"
    }

    private func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: twoPi)
        return min(distance, twoPi - distance)
    }
}
