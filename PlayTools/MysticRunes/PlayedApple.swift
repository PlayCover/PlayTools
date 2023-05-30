//
//  PlayWeRuinedIt.swift
//  PlayTools
//
//  Created by Venti on 16/01/2023.
//

import Foundation
import Security

// Implementation for PlayKeychain
// World's Most Advanced Keychain Replacement Solution:tm:
// This is a joke, don't take it seriously

public class PlayKeychain: NSObject {
    static let shared = PlayKeychain()

    private static func getKeychainDirectory() -> URL? {
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        let keychainFolder = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("PlayChain")
            .appendingPathComponent(bundleID)

        // Create the keychain folder if it doesn't exist
        if !FileManager.default.fileExists(atPath: keychainFolder.path) {
            do {
                try FileManager.default.createDirectory(at: keychainFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                debugLogger("Failed to create keychain folder")
            }
        }

        return keychainFolder
    }

    private static func getKeychainPath(_ attributes: NSDictionary) -> URL {
        let keychainFolder = getKeychainDirectory()
        if attributes["r_Ref"] as? Int == 1 {
            attributes.setValue("keys", forKey: "class")
        }
        // Generate a key path based on the key attributes
        let accountName = attributes[kSecAttrAccount as String] as? String ?? ""
        let serviceName = attributes[kSecAttrService as String] as? String ?? ""
        let classType = attributes[kSecClass as String] as? String ?? ""
        return keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")
    }

    private static func findSimilarKeys(_ attributes: NSDictionary) -> URL? {
        // Things we can fuzz: accountName

        let keychainFolder = getKeychainDirectory()
        let serviceName = attributes[kSecAttrService as String] as? String ?? ""
        let classType = attributes[kSecClass as String] as? String ?? ""

        let everyKeys = try? FileManager.default.contentsOfDirectory(at: keychainFolder!,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)
        let searchRegex = try? NSRegularExpression(pattern: "\(serviceName)-.*-\(classType).plist",
                                                   options: .caseInsensitive)

        for key in everyKeys! where searchRegex!.matches(in: key.path,
                                                         options: [],
                                                         range: NSRange(location: 0, length: key.path.count)).count > 0 {
            return keychainFolder!.appendingPathComponent(key.lastPathComponent)
        }
        return nil
    }

    @objc public static func debugLogger(_ logContent: String) {
        if PlaySettings.shared.settingsData.playChainDebugging {
            NSLog("PC-DEBUG: \(logContent)")
        }
    }
    // Emulates SecItemAdd, SecItemUpdate, SecItemDelete and SecItemCopyMatching
    // Store the entire dictionary as a plist
    // SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
    @objc static public func add(_ attributes: NSDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let keychainPath = getKeychainPath(attributes)
        // Check if the keychain file already exists
        // if FileManager.default.fileExists(atPath: keychainPath.path) {
        //     debugLogger("Keychain file already exists")
        //     return errSecDuplicateItem
        // }
        // Write the dictionary to the keychain file
        do {
            try attributes.write(to: keychainPath)
            debugLogger("Wrote keychain file to \(keychainPath)")
        } catch {
            debugLogger("Failed to write keychain file")
            return errSecIO
        }
        // Place v_Data in the result
        if let v_data = attributes["v_Data"] {
            result?.pointee = v_data as CFTypeRef
        }
        return errSecSuccess
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        // Get the path to the keychain file
        let keychainPath = getKeychainPath(query)
        // Read the dictionary from the keychain file
        let keychainDict = NSDictionary(contentsOf: keychainPath)
        debugLogger("Read keychain file from \(keychainPath)")
        // Check if the file exist
        if keychainDict == nil {
            debugLogger("Keychain file not found at \(keychainPath)")
            return errSecItemNotFound
        }
        // Reconstruct the dictionary (subscripting won't work as assignment is not allowed)
        let newKeychainDict = NSMutableDictionary()
        for (key, value) in keychainDict! {
            newKeychainDict.setValue(value, forKey: key as! String) // swiftlint:disable:this force_cast
        }
        // Update the dictionary
        for (key, value) in attributesToUpdate {
            newKeychainDict.setValue(value, forKey: key as! String) // swiftlint:disable:this force_cast
        }
        // Write the dictionary to the keychain file
        do {
            try newKeychainDict.write(to: keychainPath)
            debugLogger("Wrote keychain file to \(keychainPath)")
        } catch {
            debugLogger("Failed to write keychain file")
            return errSecIO
        }

        return errSecSuccess
    }

    // SecItemDelete(CFDictionaryRef query)
    @objc static public func delete(_ query: NSDictionary) -> OSStatus {
        // Get the path to the keychain file
        let keychainPath = getKeychainPath(query)
        // Delete the keychain file
        do {
            try FileManager.default.removeItem(at: keychainPath)
            debugLogger("Deleted keychain file at \(keychainPath)")
        } catch {
            debugLogger("Failed to delete keychain file")
            return errSecIO
        }
        return errSecSuccess
    }

    // SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
    @objc static public func copyMatching(_ query: NSDictionary, result: UnsafeMutablePointer<CFTypeRef?>?)
    -> OSStatus {
        // Get the path to the keychain file
        var keychainPath = getKeychainPath(query)
        // If the keychain file doesn't exist, attempt to find a similar key
        if !FileManager.default.fileExists(atPath: keychainPath.path) {
            return errSecItemNotFound
            // if let similarKey = findSimilarKeys(query) {
            //     NSLog("Found similar key at \(similarKey)")
            //     keychainPath = similarKey
            // } else {
            //     debugLogger("Keychain file not found at \(keychainPath)")
            //     return errSecItemNotFound
            // }
        }

        // Read the dictionary from the keychain file
        let keychainDict = NSDictionary(contentsOf: keychainPath)
        // Check the `r_Attributes` key. If it is set to 1 in the query
        let classType = query[kSecClass as String] as? String ?? ""

        // If the keychain file doesn't exist, return errSecItemNotFound
        if keychainDict == nil {
            debugLogger("Keychain file not found at \(keychainPath)")
            return errSecItemNotFound
        }

        if query["r_Attributes"] as? Int == 1 {
            // if the keychainDict is nil, we need to return errSecItemNotFound
            if keychainDict == nil {
                debugLogger("Keychain file not found at \(keychainPath)")
                return errSecItemNotFound
            }

            // Create a dummy dictionary and return it
            let dummyDict = NSMutableDictionary()
            dummyDict.setValue(classType, forKey: "class")
            dummyDict.setValue(keychainDict![kSecAttrAccount as String], forKey: "acct")
            dummyDict.setValue(keychainDict![kSecAttrService as String], forKey: "svce")
            dummyDict.setValue(keychainDict![kSecAttrGeneric as String], forKey: "gena")
            result?.pointee = dummyDict
            return errSecSuccess
        }

        // Check for r_Ref 
        if query["r_Ref"] as? Int == 1 {
            // Return the data on v_PersistentRef or v_Data if they exist
            var key: CFTypeRef?
            if let vData = keychainDict!["v_Data"] {
                NSLog("found v_Data")
                debugLogger("Read keychain file from \(keychainPath)")
                key = vData as CFTypeRef
            }
            if let vPersistentRef = keychainDict!["v_PersistentRef"] {
                NSLog("found persistent ref")
                debugLogger("Read keychain file from \(keychainPath)")
                key = vPersistentRef as CFTypeRef
            }

            if key == nil {
                debugLogger("Keychain file not found at \(keychainPath)")
                return errSecItemNotFound
            }
            
            let dummyKeyAttrs = [
                kSecAttrKeyType: keychainDict?["type"] ?? kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: keychainDict!["kcls"] ?? kSecAttrKeyClassPublic
            ] as CFDictionary

            let secKey = SecKeyCreateWithData(key as! CFData, dummyKeyAttrs, nil) // swiftlint:disable:this force_cast
            result?.pointee = secKey
            return errSecSuccess
        }

        // Return v_Data if it exists
        if let vData = keychainDict!["v_Data"] {
            debugLogger("Read keychain file from \(keychainPath)")
            // Check the class type, if it is a key we need to return the data
            // as SecKeyRef, otherwise we can return it as a CFTypeRef
            if classType == "keys" {
                // kSecAttrKeyType is stored as `type` in the dictionary
                // kSecAttrKeyClass is stored as `kcls` in the dictionary
                let keyAttributes = [
                    kSecAttrKeyType: keychainDict!["type"] as! CFString, // swiftlint:disable:this force_cast
                    kSecAttrKeyClass: keychainDict!["kcls"] as! CFString // swiftlint:disable:this force_cast
                ]
                let keyData = vData as! Data // swiftlint:disable:this force_cast
                let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil)
                result?.pointee = key
                return errSecSuccess
            }
            result?.pointee = vData as CFTypeRef
            return errSecSuccess
        }

        return errSecItemNotFound
    }
}
