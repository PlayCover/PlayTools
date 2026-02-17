/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Menu construction extensions for this sample.
 */

import UIKit

class RotateViewController: UIViewController {
    static let orientationList: [UIInterfaceOrientation] = [
        .landscapeLeft, .portrait, .landscapeRight, .portraitUpsideDown]
    static var orientationTraverser = 0

    static func rotate(deviceOrientation: Int) {
        orientationTraverser = deviceOrientation
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        RotateViewController.orientationList[
            RotateViewController.orientationTraverser % RotateViewController.orientationList.count]
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var modalPresentationStyle: UIModalPresentationStyle { get {.fullScreen} set {} }
}

extension UIApplication {
    @objc
    func switchEditorMode(_ sender: AnyObject) {
        ModeAutomaton.onCmdK()
    }

    @objc
    func removeElement(_ sender: AnyObject) {
        EditorController.shared.removeControl()
    }

    @objc
    func upscaleElement(_ sender: AnyObject) {
        EditorController.shared.focusedControl?.resize(down: false)
    }

    @objc
    func downscaleElement(_ sender: AnyObject) {
        EditorController.shared.focusedControl?.resize(down: true)
    }

    // put a mark in the toucher log, so as to align with tester description
    @objc
    func markToucherLog(_ sender: AnyObject) {
        Toucher.writeLog(logMessage: "mark")
        Toast.showHint(title: "Log marked")
    }

    @objc
    func rotateView(_ sender: AnyObject) {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let rootViewController = window.rootViewController else { continue }
                if let dict = sender.propertyList as? [String: Any],
                   let index = dict["rotationIndex"] as? Int {
                    rootViewController.rotateView(sender, deviceOrientation: index)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2, execute: {
            Toast.showHint(title: "Rotated")
        })
    }

    @objc
    func toggleDebugOverlay(_ sender: AnyObject) {
        DebugController.instance.toggleDebugOverlay()
    }

    @objc
    func hideCursor(_ sender: AnyObject) {
        AKInterface.shared!.hideCursorMove()
    }

    @objc
    func nextKeymap(_ sender: AnyObject) {
        let isCmdK = mode == .editor

        if isCmdK {
            ModeAutomaton.onCmdK()
        }

        keymap.nextKeymap()
        Toast.showHint(title: "Switched to next keymap: \(keymap.currentKeymapName)")
        ActionDispatcher.build()

        if isCmdK {
            ModeAutomaton.onCmdK()
        }
    }

    @objc
    func previousKeymap(_ sender: AnyObject) {
        let isCmdK = mode == .editor

        if isCmdK {
            ModeAutomaton.onCmdK()
        }

        keymap.previousKeymap()
        Toast.showHint(title: "Switched to previous keymap: \(keymap.currentKeymapName)")
        ActionDispatcher.build()

        if isCmdK {
            ModeAutomaton.onCmdK()
        }
    }
}

extension UIViewController {
    @objc
    func rotateView(_ sender: AnyObject, deviceOrientation: Int) {
        RotateViewController.rotate(deviceOrientation: deviceOrientation)
        RotateViewController.orientationTraverser %= RotateViewController.orientationList.count
        let viewController = RotateViewController(nibName: nil, bundle: nil)
        self.present(viewController, animated: true)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1, execute: {
            self.dismiss(animated: true)
        })
    }
}

struct CommandsList {
    static let KeymappingToolbox = "keymapping"
}
// have to use a customized name, in case it conflicts with the game's localization file
var keymapping = [
    NSLocalizedString("menu.keymapping.toggleEditor", tableName: "Playtools",
                      value: "Open/Close Keymapping Editor", comment: ""),
    NSLocalizedString("menu.keymapping.deleteElement", tableName: "Playtools",
                      value: "Delete selected element", comment: ""),
    NSLocalizedString("menu.keymapping.upsizeElement", tableName: "Playtools",
                      value: "Upsize selected element", comment: ""),
    NSLocalizedString("menu.keymapping.downsizeElement", tableName: "Playtools",
                      value: "Downsize selected element", comment: ""),
    NSLocalizedString("menu.keymapping.toggleDebug", tableName: "Playtools",
                      value: "Toggle Debug Overlay", comment: ""),
    NSLocalizedString("menu.keymapping.hide.pointer", tableName: "Playtools",
                      value: "Hide Mouse Pointer", comment: ""),
    NSLocalizedString("menu.keymapping.previousKeymap", tableName: "Playtools",
                      value: "Previous Keymap", comment: ""),
    NSLocalizedString("menu.keymapping.nextKeymap", tableName: "Playtools",
                      value: "Next Keymap", comment: "")
  ]
var iconsSelctor = [
    UIImage(systemName: "pencil"),
    UIImage(systemName: "trash.fill"),
    UIImage(systemName: "square.resize.up"),
    UIImage(systemName: "square.resize.down"),
    UIImage(systemName: "rectangle.landscape.rotate"),
    UIImage(systemName: "wrench.and.screwdriver"),
    UIImage(systemName: "pointer.arrow.slash"),
    UIImage(systemName: "arrow.down.square"),
    UIImage(systemName: "arrow.up.square")
  ]
var keymappingSelectors = [#selector(UIApplication.switchEditorMode(_:)),
                           #selector(UIApplication.removeElement(_:)),
                           #selector(UIApplication.upscaleElement(_:)),
                           #selector(UIApplication.downscaleElement(_:)),
                           #selector(UIApplication.rotateView(_:)),
                           #selector(UIApplication.toggleDebugOverlay(_:)),
                           #selector(UIApplication.hideCursor(_:)),
                           #selector(UIApplication.previousKeymap(_:)),
                           #selector(UIApplication.nextKeymap(_:))
    ]

class MenuController {
    init(with builder: UIMenuBuilder) {
    #if canImport(UIKit.UIMainMenuSystem)
        if #available(iOS 26.0, *) {
            // Delay to avoid error
            // Cannot set a main menu system configuration while the main menu system is building.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let configuration = UIMainMenuSystem.Configuration()
                configuration.sidebarPreference = .included
                UIMainMenuSystem.shared.setBuildConfiguration(configuration) { builder in
                    self.setupMenu(with: builder)
                }
            }
        } else {
            setupMenu(with: builder)
        }
    #else
        setupMenu(with: builder)
    #endif
    }

    func setupMenu(with builder: UIMenuBuilder) {
        if Toucher.logEnabled {
            builder.insertSibling(MenuController.debuggingMenu(), afterMenu: .view)
        }
        builder.insertSibling(MenuController.keymappingMenu(), afterMenu: .view)
    }

    static func debuggingMenu() -> UIMenu {
        let menuTitle = [
            "Put a mark in toucher log"
        ]
        let keyCommands = ["L"]
        let selectors = [
            #selector(UIApplication.markToucherLog)
        ]
        let arrowKeyChildrenCommands = zip(keyCommands, menuTitle).map { (command, btn) in
            UIKeyCommand(title: btn,
                 image: nil,
                 action: selectors[menuTitle.firstIndex(of: btn)!],
                 input: command,
                 modifierFlags: .command,
                 propertyList: [CommandsList.KeymappingToolbox: btn]
            )
        }
        return UIMenu(title: "Debug",
                      image: nil,
                      identifier: .debuggingMenu,
                      options: [],
                      children: [
                        UIMenu(title: "",
                               image: nil,
                               identifier: .debuggingOptionsMenu,
                               options: .displayInline,
                               children: arrowKeyChildrenCommands)])
    }

    class func keymappingMenu() -> UIMenu {
        let keyCommands = [
            "K",                            // Toggle keymap editor
            UIKeyCommand.inputDelete,       // Remove keymap element
            UIKeyCommand.inputUpArrow,      // Increase keymap element size
            UIKeyCommand.inputDownArrow,    // Decrease keymap element size
            "D",                            // Toggle debug overlay
            ".",                            // Hide cursor until move
            "[",                            // Previous keymap
            "]"                             // Next keymap
        ]
        let arrowKeyChildrenCommands = zip(zip(keyCommands, keymapping), iconsSelctor).map { (arg0, image) in
            let (command, btn) = arg0
            return UIKeyCommand(title: btn,
                         image: image,
                         action: keymappingSelectors[keymapping.firstIndex(of: btn)!],
                         input: command,
                         modifierFlags: .command,
                         propertyList: [CommandsList.KeymappingToolbox: btn]
            )
        }

        let rotationTitles = [
            "Landscape Left (0°)",
            "Portrait (90°)",
            "Landscape Right (180°)",
            "Portrait Upside Down (270°)"
        ]
        let rotationInputs = ["1", "2", "3", "4"]

        // Every rotation item calls the *same selector*, passing its index in propertyList
        let rotationMenuItems = rotationTitles.enumerated().map { (index, title) in
            UIKeyCommand(
                title: title,
                image: nil,
                action: #selector(UIApplication.rotateView(_:)),
                input: rotationInputs[index],
                modifierFlags: [.command, .shift], // ⌘⇧1–4
                propertyList: ["rotationIndex": index]
            )
        }

        let rotationMenu = UIMenu(
            title: NSLocalizedString("menu.keymapping.rotateDisplay", tableName: "Playtools",
                              value: "Rotate display area", comment: ""),
            image: nil,
            identifier: .rotationOptionsMenu,
            options: [],
            children: rotationMenuItems
        )

        // Combine all menus
        let arrowKeysGroup = UIMenu(
            title: "",
            image: nil,
            identifier: .keymappingOptionsMenu,
            options: .displayInline,
            children: arrowKeyChildrenCommands + [rotationMenu]
        )

        return UIMenu(title: NSLocalizedString("menu.keymapping", tableName: "Playtools",
                                               value: "Keymapping", comment: ""),
                      image: nil,
                      identifier: .keymappingMenu,
                      options: [],
                      children: [arrowKeysGroup])
    }
}

extension UIMenu.Identifier {
    static var keymappingMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.editor") }
    static var keymappingOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.keymapping") }
    static var debuggingMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.debug") }
    static var debuggingOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.debugging") }
    static var rotationOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.rotation") }
}
