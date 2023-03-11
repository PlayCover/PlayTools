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

    private static func keychainPath(_ attributes: NSDictionary) -> URL {
        let keychainFolder = getKeychainDirectory()
        // Generate a key path based on the key attributes
        let accountName = attributes[kSecAttrAccount as String] as? String ?? ""
        let serviceName = attributes[kSecAttrService as String] as? String ?? ""
        let classType = attributes[kSecClass as String] as? String ?? ""
        return keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")
    }

    private static func createGenpAttr(_ query: NSDictionary, _ keychainPath: URL) -> NSDictionary? {
        let currentTime = Date()
        let keychainDict = NSDictionary(contentsOf: keychainPath)

        let attributes = NSMutableDictionary()
        attributes[kSecAttrAccessControl as String] =
        SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                         kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         .or,
                                         nil)
        attributes[kSecAttrAccount as String] = query["acct"] ?? keychainDict?["acct"] ?? ""
        attributes[kSecAttrAccessGroup as String] = "*"
        attributes[kSecAttrCreationDate as String] = String(describing: currentTime)
            .replacingOccurrences(of: "UTC", with: "+0000")
        attributes[kSecAttrModificationDate as String] = String(describing: currentTime)
            .replacingOccurrences(of: "UTC", with: "+0000")
        attributes["musr"] = Data()
        attributes[kSecAttrPath as String] = keychainDict?["pdmn"] ?? "ak"
        attributes["sha1"] = Data()
        attributes[kSecAttrService as String] = query["svce"] ?? keychainDict?["svce"] ?? ""
        attributes[kSecAttrSynchronizable as String] = query["sync"] ?? keychainDict?["sync"] ?? 0
        attributes["tomb"] = query["tomb"] ?? keychainDict?["tomb"] ?? 0
        return attributes
    }

    private static func createKeysAttr(_ query: NSDictionary, _ keychainPath: URL) -> NSDictionary? {
        let currentTime = Date()
        let jan1st2001 = Date(timeIntervalSince1970: 978307200)
        let keychainDict = NSDictionary(contentsOf: keychainPath)

        let attributes = NSMutableDictionary()
        attributes["UUID"] = UUID().uuidString
        attributes[kSecAttrAccessControl as String] =
        SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                        .or,
                                        nil)
        attributes[kSecAttrAccessGroup as String] = "*"
        attributes["asen"] = query["asen"] ?? keychainDict?["asen"] ?? 0
        attributes[kSecAttrApplicationTag as String] =
        query["atag"] as? Data? ?? keychainDict?["atag"] as? Data? ?? Data()
        attributes[kSecAttrKeySizeInBits as String] = query["bsiz"] ?? keychainDict?["bsiz"] ?? 0
        attributes[kSecAttrCreationDate as String] =
        String(describing: currentTime).replacingOccurrences(of: "UTC", with: "+0000")
        attributes[kSecAttrCreator as String] = query["crtr"] ?? keychainDict?["crtr"] ?? 0
        attributes["decr"] = query["decr"] ?? keychainDict?["decr"] ?? 0
        attributes["drve"] = query["drve"] ?? keychainDict?["drve"] ?? 0
        attributes["edat"] = query["edat"] ?? keychainDict?["edat"] ??
        String(describing: jan1st2001).replacingOccurrences(of: "UTC", with: "+0000")
        attributes["encr"] = query["encr"] ?? keychainDict?["encr"] ?? 0
        attributes["esiz"] = query["esiz"] ?? keychainDict?["esiz"] ?? 0
        attributes["extr"] = query["extr"] ?? keychainDict?["extr"] ?? 0
        attributes["kcls"] = query["kcls"] ?? keychainDict?["kcls"] ?? 0
        attributes[kSecAttrLabel as String] = query["labl"] ?? keychainDict?["labl"] ?? ""
        attributes[kSecAttrModificationDate as String] =
        String(describing: currentTime).replacingOccurrences(of: "UTC", with: "+0000")
        attributes["modi"] = query["modi"] ?? keychainDict?["modi"] ?? 1
        attributes["musr"] = Data()
        attributes["next"] = query["next"] ?? keychainDict?["next"] ?? 0
        attributes[kSecAttrPath as String] = keychainDict?["pdmn"] ?? "dku"
        attributes["perm"] = query["perm"] ?? keychainDict?["perm"] ?? 1
        attributes["priv"] = query["priv"] ?? keychainDict?["priv"] ?? 1
        attributes["sdat"] = query["sdat"] ?? keychainDict?["sdat"] ?? String(describing: jan1st2001)
            .replacingOccurrences(of: "UTC", with: "+0000")
        attributes["sens"] = query["sens"] ?? keychainDict?["sens"] ?? 0
        attributes["sha1"] = query["sha1"] as? Data ?? keychainDict?["sha1"] as? Data? ?? Data()
        return attributes
    }

    static private func getAttributes(_ query: NSDictionary, _ keychainPath: URL) -> NSDictionary? {
        // First, check if the kind of key is genp or keys
        let classType = query[kSecClass as String] as? String ?? ""
        if classType == "genp" {
            return createGenpAttr(query, keychainPath)
        } else if classType == "keys" {
            return createKeysAttr(query, keychainPath)
        } else {
            return nil
        }
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
        let keychainPath = keychainPath(attributes)
        // Check if the keychain file already exists
        if FileManager.default.fileExists(atPath: keychainPath.path) {
            debugLogger("Keychain file already exists")
            return errSecDuplicateItem
        }
        // Write the dictionary to the keychain file
        do {
            try attributes.write(to: keychainPath)
            debugLogger("Wrote keychain file to \(keychainPath)")
        } catch {
            debugLogger("Failed to write keychain file")
            return errSecIO
        }
        // Place v_data in the result
        if let v_data = attributes["v_Data"] {
            result?.pointee = v_data as CFTypeRef
        }
        return errSecSuccess
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        // Get the path to the keychain file
        let keychainPath = keychainPath(query)
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
        let keychainPath = keychainPath(query)
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
        let keychainPath = keychainPath(query)
        // Check the `r_Attributes` key. If it is set to 1 in the query
        // DROP, NOT IMPLEMENTED
        let classType = query[kSecClass as String] as? String ?? ""
        if query["r_Attributes"] as? Int == 1 {
            let attributesDict = getAttributes(query, keychainPath)
            if attributesDict == nil {
                return errSecItemNotFound
            }
            // convert to CFDictonary
            let attributes = attributesDict! as CFDictionary
            result?.pointee = attributes as CFTypeRef
            return errSecSuccess
        }
        let keychainDict = NSDictionary(contentsOf: keychainPath)
        // If the keychain file doesn't exist, return errSecItemNotFound
        if keychainDict == nil {
            debugLogger("Keychain file not found at \(keychainPath)")
            return errSecItemNotFound
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
