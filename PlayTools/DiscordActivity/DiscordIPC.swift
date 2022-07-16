//
//  DiscordIPC.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/07/15.
//

import Foundation
import SwordRPC

class DiscordIPC {
    public static let shared = DiscordIPC()
  
    func initailize() {
        if PlaySettings.shared.discordActivity {
            let ipc: SwordRPC
            let custom = PlaySettings.shared.customActivity
            
            if custom.cliendID.isEmpty {
                ipc = SwordRPC(appId: "996108521680678993")
            } else {
                ipc = SwordRPC(appId: custom.cliendID)
            }
            let activity = createActivity(from: custom)
            ipc.connect()
            ipc.setPresence(activity)
        }
    }
    
    func createActivity(from custom: DiscordActivity) -> RichPresence {
        var activity = RichPresence()

        if custom.details.isEmpty {
            let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? (Bundle.main.infoDictionary?["CFBundleName"] as! String)
            activity.details = "Playing \(name)"
        } else {
            if custom.details.count == 1 { custom.details += " " }
            activity.details = custom.details
        }
        
        let poweredStr = "Powered by PlayCover"
        if custom.state.isEmpty {
            activity.state = poweredStr
        } else {
            if custom.state.count == 1 { custom.state += " " }
            activity.state = custom.state
            activity.assets.smallText = poweredStr
            activity.assets.largeText = poweredStr
        }
        
        let logo = "https://raw.githubusercontent.com/PlayCover/PlayCover/master/images/logo.png"
        if custom.image.isEmpty {
            let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as! String
            if let appImage = loadImage(bundleID: bundleID) {
                activity.assets.largeImage = appImage
                activity.assets.largeText = nil
                activity.assets.smallImage = logo
            } else {
                activity.assets.largeImage = logo
            }
        } else {
            activity.assets.largeImage = custom.image
            activity.assets.largeText = nil
            activity.assets.smallImage = logo
        }
        
        activity.timestamps.start = Date()

        return activity
    }
    
    // TODO : load App icon image from appstore
    func loadImage(bundleID: String) -> String? {
        return nil
    }
}
