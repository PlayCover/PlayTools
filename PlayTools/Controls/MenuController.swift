/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Menu construction extensions for this sample.
 */

import UIKit

extension UIViewController {
    
    
    
    @objc
    func switchEditorMode(_ sender: AnyObject) {
        EditorController.shared.switchMode()
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
    
}

struct CommandsList {
    static let KeymappingToolbox = "keymapping"
}

var keymapping = ["Open/Close Keymapping Editor", "Delete selected element", "Upsize selected element", "Downsize selected element"]
var keymappingSelectors = [#selector(UIViewController.switchEditorMode(_:)), #selector(UIViewController.removeElement(_:)), #selector(UIViewController.upscaleElement(_:)), #selector(UIViewController.downscaleElement(_:))]

class MenuController {
    
    init(with builder: UIMenuBuilder) {
        if #available(iOS 15.0, *) {
            builder.insertSibling(MenuController.keymappingMenu(), afterMenu: .view)
        } else {
            
        }
    }
    
    @available(iOS 15.0, *)
    class func keymappingMenu() -> UIMenu {
        let keyCommands = [ "K", UIKeyCommand.inputDelete , UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow ]
        
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
