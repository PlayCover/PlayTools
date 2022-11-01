/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Menu construction extensions for this sample.
 */

import UIKit

extension UIApplication {
    @objc
    func switchEditorMode(_ sender: AnyObject) {
        EditorController.shared.toggleEditor()
    }

    @objc
    func removeElement(_ sender: AnyObject) {
        print("Remove element")
        // EditorController.shared.removeControl()
    }

    @objc
    func upscaleElement(_ sender: AnyObject) {
        print("Upscale element")
        // EditorController.shared.focusedControl?.resize(down: false)
    }

    @objc
    func downscaleElement(_ sender: AnyObject) {
        print("Downscale element")
        // EditorController.shared.focusedControl?.resize(down: true)
    }
}

struct CommandsList {
    static let KeymappingToolbox = "keymapping"
}

var keymapping = ["Open/Close Keymapping Editor",
                  "Delete selected element",
                  "Upsize selected element",
                  "Downsize selected element"]
var keymappingSelectors = [#selector(UIApplication.switchEditorMode(_:)),
                           #selector(UIApplication.removeElement(_:)),
                           #selector(UIApplication.upscaleElement(_:)),
                           #selector(UIApplication.downscaleElement(_:))]

class MenuController {
    init(with builder: UIMenuBuilder) {
        if #available(iOS 15.0, *) {
            builder.insertSibling(MenuController.keymappingMenu(), afterMenu: .view)
        }
    }

    class func keymappingMenu() -> UIMenu {
        let keyCommands = [ "K", UIKeyCommand.inputDelete, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "R" ]

        let arrowKeyChildrenCommands = zip(keyCommands, keymapping).map { (command, btn) in
            UIKeyCommand(title: btn,
                         image: nil,
                         action: keymappingSelectors[keymapping.firstIndex(of: btn)!],
                         input: command,
                         modifierFlags: .command,
                         propertyList: [CommandsList.KeymappingToolbox: btn]
            )
        }

        let arrowKeysGroup = UIMenu(title: "",
                                    image: nil,
                                    identifier: .keymappingOptionsMenu,
                                    options: .displayInline,
                                    children: arrowKeyChildrenCommands)

        return UIMenu(title: NSLocalizedString("Keymapping", comment: ""),
                      image: nil,
                      identifier: .keymappingMenu,
                      options: [],
                      children: [arrowKeysGroup])
    }
}

extension UIMenu.Identifier {
    static var keymappingMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.editor") }
    static var keymappingOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("io.playcover.PlayTools.menus.keymapping") }
}
