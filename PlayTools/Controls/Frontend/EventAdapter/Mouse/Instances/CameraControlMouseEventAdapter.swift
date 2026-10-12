//
//  CameraControlMouseEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// Mouse events handler when cursor is locked and keyboard mapping is on

public class CameraControlMouseEventAdapter: MouseEventAdapter {
    public func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        // Priority 1: Keymapping. If enabled and triggered, consume the event.
        if PlaySettings.shared.enableScrollWheelMapping {
            let threshold: CGFloat = 0.5
            var handled = false
            if deltaY > threshold {
                handled = ActionDispatcher.dispatchClick(key: "ScrU")
            } else if deltaY < -threshold {
                handled = ActionDispatcher.dispatchClick(key: "ScrD")
            }
            
            // If mapping was triggered, return true to consume the event
            if handled {
                return true
            }
        }

        // Priority 2: Zoom/Scale logic.
        if PlaySettings.shared.enableScrollWheelZoom {
            _ = ActionDispatcher.dispatch(key: KeyCodeNames.scrollWheelScale, valueX: deltaX, valueY: deltaY)
            return true
        }
        
        return true
    }

    public func handleMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let sensy = CGFloat(PlaySettings.shared.sensitivity * 0.6)
        let cgDx = deltaX * sensy,
            cgDy = -deltaY * sensy
        return ActionDispatcher.dispatch(key: KeyCodeNames.mouseMove, valueX: cgDx, valueY: cgDy)
    }

    public func handleLeftButton(pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: KeyCodeNames.leftMouseButton, pressed: pressed)
    }

    public func handleOtherButton(id: Int, pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: EditorMouseEventAdapter.getMouseButtonName(id),
                                  pressed: pressed)
    }

    public func cursorHidden() -> Bool {
        true
    }

}
