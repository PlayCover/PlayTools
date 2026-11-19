//
//  TouchscreenMouseEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// Mouse events handler when cursor is free and keyboard mapping is on

public class TouchscreenMouseEventAdapter: MouseEventAdapter {

    static public func cursorPos() -> CGPoint? {
        guard let akInterface = AKInterface.shared else { return nil }
        var point = akInterface.mousePoint
        let winFrame = akInterface.windowFrame
        let rawContent = akInterface.contentLayoutRect
        let contentRect = (rawContent.width >= 1 && rawContent.height >= 1)
            ? rawContent
            : CGRect(origin: .zero, size: winFrame.size)

        if contentRect.width < 1 || contentRect.height < 1 || winFrame.width < 1 || winFrame.height < 1 {
            return nil
        }
        if screen.resizable && !screen.fullscreen && isOnResizeEdge(point, winFrame: winFrame) {
            return nil
        }
        if PlaySettings.shared.dynamicWindowMode {
            return dynamicCursorPos(point: point, winFrame: winFrame, contentRect: contentRect)
        }

        let rect = contentRect
        let viewRect: CGRect = screen.screenRect
        let widthRate = viewRect.width / rect.width
        var rate = viewRect.height / rect.height
        if widthRate > rate {
            rate = widthRate
        }
        point.x -= rect.minX
        point.y -= rect.minY
        if screen.fullscreen {
            point.y -= (rect.height - viewRect.height / rate) / 2
        }
        point.y = viewRect.height - point.y * rate
        if point.y < 0 {
            return nil
        }
        point.x = (point.x - (rect.width - viewRect.width / rate) / 2) * rate
        return point
    }

    private static func isOnResizeEdge(_ point: CGPoint, winFrame: CGRect) -> Bool {
        let margin = CGFloat(10)
        return point.x < margin || point.x > winFrame.width - margin
            || point.y < margin || point.y > winFrame.height - margin
    }

    private static func dynamicCursorPos(
        point: CGPoint,
        winFrame: CGRect,
        contentRect: CGRect
    ) -> CGPoint? {
        let targetRect = screen.primaryWindowBounds ?? screen.screenRect
        guard targetRect.width >= 1, targetRect.height >= 1 else { return nil }
        let useFullFrame = PlaySettings.shared.hideTitleBar
            && abs(targetRect.height - winFrame.height) < 2
        if useFullFrame && point.y > contentRect.maxY {
            return nil
        }
        let refRect = useFullFrame ? CGRect(origin: .zero, size: winFrame.size) : contentRect
        let localX = point.x - refRect.minX
        let localY = refRect.maxY - point.y
        guard localX >= 0, localX <= refRect.width, localY >= 0, localY <= refRect.height else {
            return nil
        }
        return screen.windowPoint(
            forNormalizedContentX: localX / refRect.width,
            y: localY / refRect.height
        )
    }

    public func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        _ = ActionDispatcher.dispatch(key: KeyCodeNames.scrollWheelDrag, valueX: deltaX, valueY: deltaY)
        // I dont know why but this is the logic before the refactor.
        // Might be a mistake but keeping it for now
        return false
    }

    public func handleMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.mouseMove) == .DRAGGABLE {
            // condition meets when draggable button pressed
            return ActionDispatcher.dispatch(key: KeyCodeNames.mouseMove, valueX: deltaX, valueY: -deltaY)
        } else if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeMouse) == .DRAGGABLE {
            // condition meets when mouse pressed and draggable button not pressed
            // fake mouse handler priority:
            // default direction pad: press handler
            // draggable direction pad: move handler
            // default button: lift handler
            // kinda hacky but.. IT WORKS!
            guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, valueX: pos.x, valueY: pos.y)

        }
        return false
    }

    public func handleLeftButton(pressed: Bool) -> Bool {
        // It is necessary to calculate pos before pushing to dispatch queue
        // Otherwise, we don't know whether to return false or true
        guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
        if pressed {
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, valueX: pos.x, valueY: pos.y)
        } else {
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, pressed: pressed)
        }
    }

    public func handleOtherButton(id: Int, pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: EditorMouseEventAdapter.getMouseButtonName(id),
                                  pressed: pressed)
    }

    public func cursorHidden() -> Bool {
        false
    }

}
