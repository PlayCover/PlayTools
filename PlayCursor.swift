//
//  PlayCursor.swift
//  PlayTools
//  
//  Created by viatearz on 2025/2/4.
//

import AppKit

class PlayCursor {
    public static let shared = PlayCursor()
    var cursor: NSCursor?
    var isMouseOver: Bool = false

    func setupCustomCursor(imageUrl: URL, size: CGSize, hotSpot: CGPoint) {
        guard let image = NSImage(contentsOfFile: imageUrl.path)?.scale(to: size) else {
            return
        }

        self.cursor = NSCursor(image: image, hotSpot: hotSpot)
        NotificationCenter.default.addObserver(forName: .customCursorMouseEntered, object: nil, queue: .main) { _ in
            self.isMouseOver = true
            self.cursor?.set()
        }
        NotificationCenter.default.addObserver(forName: .customCursorMouseExited, object: nil, queue: .main) { _ in
            self.isMouseOver = false
            NSCursor.arrow.set()
        }
        NSWindow.swizzleMethods()
        NSCursor.swizzleMethods()
    }
}

extension NSImage {
    func scale(to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        let srcRect = NSRect(origin: .zero, size: self.size)
        let dstRect = NSRect(origin: .zero, size: size)
        self.draw(in: dstRect, from: srcRect, operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

extension NSObject {
    static func swizzleInstanceMethod(cls: AnyClass, origSelector: Selector, newSelector: Selector) {
        // If current class doesn't exist selector, then get super
        guard let originalMethod = class_getInstanceMethod(cls, origSelector) else { return }
        guard let swizzledMethod = class_getInstanceMethod(cls, newSelector) else { return }

        // Add selector if it doesn't exist, implement append with method
        if class_addMethod(cls,
                           origSelector,
                           method_getImplementation(swizzledMethod),
                           method_getTypeEncoding(swizzledMethod)) {
            // Replace class instance method, added if selector not exist
            // For class cluster, it always adds new selector here
            class_replaceMethod(cls,
                                newSelector,
                                method_getImplementation(originalMethod),
                                method_getTypeEncoding(originalMethod))
        } else {
            // SwizzleMethod maybe belongs to super
            if let newImplementation = class_replaceMethod(cls,
                                                           origSelector,
                                                           method_getImplementation(swizzledMethod),
                                                           method_getTypeEncoding(swizzledMethod)) {
                class_replaceMethod(cls,
                                    newSelector,
                                    newImplementation,
                                    method_getTypeEncoding(originalMethod))
            }
        }
    }
}

extension NSWindow {
    static func swizzleMethods() {
        guard let cls = objc_getClass("UINSWindow") as? AnyClass else {
            return
        }
        // Hook UINSWindow.setContentView()
        NSObject.swizzleInstanceMethod(cls: cls,
                                       origSelector: NSSelectorFromString("setContentView:"),
                                       newSelector: #selector(hook_setContentView(_:)))
        // Hook UINSWindow.becomeKey()
        NSObject.swizzleInstanceMethod(cls: cls,
                                       origSelector: #selector(becomeKey),
                                       newSelector: #selector(hook_becomeKey))
    }

    @objc private func hook_setContentView(_ view: NSView) {
        self.hook_setContentView(view)

        // Add a transparent full-screen view to monitor mouse enter and exit events
        view.addSubview(CustomCursorLayerView(frame: view.bounds))
    }

    @objc private func hook_becomeKey() {
        self.hook_becomeKey()

        // Ensure our custom cursor is displayed after switching applications
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if PlayCursor.shared.isMouseOver {
                PlayCursor.shared.cursor?.set()
            }
        }
   }
}

extension NSCursor {
    static func swizzleMethods() {
        // Hook NSCursor.set()
        NSObject.swizzleInstanceMethod(cls: NSCursor.self,
                                       origSelector: #selector(set),
                                       newSelector: #selector(hook_set))
    }

    @objc private func hook_set() {
        // Prevent other parts of the current application from displaying the arrow cursor
        if self == NSCursor.arrow && PlayCursor.shared.isMouseOver {
            PlayCursor.shared.cursor?.set()
            return
        }
        self.hook_set()
    }
}

extension Notification.Name {
    static let customCursorMouseEntered = Notification.Name("customCursorMouseEntered")
    static let customCursorMouseExited = Notification.Name("customCursorMouseExited")
}

class CustomCursorLayerView: NSView {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.initView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.initView()
    }

    private func initView() {
        self.autoresizingMask = [.width, .height]
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(rect: bounds,
                                             options: [.mouseEnteredAndExited, .activeAlways],
                                             owner: self,
                                             userInfo: nil)
        addTrackingArea(newTrackingArea)
        self.trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NotificationCenter.default.post(name: .customCursorMouseEntered, object: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NotificationCenter.default.post(name: .customCursorMouseExited, object: self)
    }
}
