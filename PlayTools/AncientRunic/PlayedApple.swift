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
        // Get the keychain folder
        let keychainFolder = PlayCover.keychainFolder

        // Create the keychain folder if it doesn't exist
        if !FileManager.default.fileExists(atPath: keychainFolder!.path) {
            do {
                try FileManager.default.createDirectory(at: keychainFolder!,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                NSLog("BUZZINC: Failed to create keychain folder")
            }
        }

        return keychainFolder
    }

    // Emulates SecItemAdd, SecItemUpdate, SecItemDelete and SecItemCopyMatching
    // Store the entire dictionary as a plist

    // SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
    @objc static public func add(_ attributes: NSDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        // Get the keychain folder
        let keychainFolder = getKeychainDirectory()

        // Get the account name (optional, may not exist, non-fatal)
        // In cases where the account name doesn't exist, ignore it
        let accountName = attributes[kSecAttrAccount as String] as? String ?? ""

        // Get the service name (optional, may not exist, non-fatal)
        // In cases where the service name doesn't exist, ignore it
        let serviceName = attributes[kSecAttrService as String] as? String ?? ""

        // Get the class
        let classType = attributes[kSecClass as String] as? String ?? ""

        // Get the path to the keychain file
        let keychainPath = keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")

        // Check if the keychain file already exists
        if FileManager.default.fileExists(atPath: keychainPath.path) {
            NSLog("BUZZINC: Keychain file already exists")
            return errSecDuplicateItem
        }

        // Write the dictionary to the keychain file
        do {
            try attributes.write(to: keychainPath)
            NSLog("BUZZINC: Wrote keychain file to \(keychainPath)")
        } catch {
            NSLog("BUZZINC: Failed to write keychain file")
            return errSecIO
        }
        // Place v_data in the result
        if let v_data = attributes["v_data"] {
            result?.pointee = v_data as CFTypeRef
        }

        return errSecSuccess
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        // Get the keychain folder
        let keychainFolder = getKeychainDirectory()

        // Get the account name (optional, may not exist, non-fatal)
        // In cases where the account name doesn't exist, ignore it
        let accountName = query[kSecAttrAccount as String] as? String ?? ""

        // Get the service name (optional, may not exist, non-fatal)
        // In cases where the service name doesn't exist, ignore it
        let serviceName = query[kSecAttrService as String] as? String ?? ""

        // Get the class
        let classType = query[kSecClass as String] as? String ?? ""

        // Get the path to the keychain file
        let keychainPath = keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")

        // Read the dictionary from the keychain file
        let keychainDict = NSDictionary(contentsOf: keychainPath)
        NSLog("BUZZINC: Read keychain file from \(keychainPath)")

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
            NSLog("BUZZINC: Wrote keychain file to \(keychainPath)")
        } catch {
            NSLog("BUZZINC: Failed to write keychain file")
            return errSecIO
        }

        return errSecSuccess
    }

    // SecItemDelete(CFDictionaryRef query)
    @objc static public func delete(_ query: NSDictionary) -> OSStatus {
        // Get the keychain folder
        let keychainFolder = getKeychainDirectory()

        // Get the account name (optional, may not exist, non-fatal)
        // In cases where the account name doesn't exist, ignore it
        let accountName = query[kSecAttrAccount as String] as? String ?? ""

        // Get the service name (optional, may not exist, non-fatal)
        // In cases where the service name doesn't exist, ignore it
        let serviceName = query[kSecAttrService as String] as? String ?? ""

        // Get the class
        let classType = query[kSecClass as String] as? String ?? ""

        // Get the path to the keychain file
        let keychainPath = keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")

        // Delete the keychain file
        do {
            try FileManager.default.removeItem(at: keychainPath)
            NSLog("BUZZINC: Deleted keychain file at \(keychainPath)")
        } catch {
            NSLog("BUZZINC: Failed to delete keychain file")
            return errSecIO
        }
        return errSecSuccess
    }

    // SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
    @objc static public func copyMatching(_ query: NSDictionary, result: UnsafeMutablePointer<CFTypeRef?>?)
    -> OSStatus {
        // Get the keychain folder
        let keychainFolder = getKeychainDirectory()

        // Get the account name (optional, may not exist, non-fatal)
        // In cases where the account name doesn't exist, ignore it
        let accountName = query[kSecAttrAccount as String] as? String ?? ""

        // Get the service name (optional, may not exist, non-fatal)
        // In cases where the service name doesn't exist, ignore it
        let serviceName = query[kSecAttrService as String] as? String ?? ""

        // Get the class
        let classType = query[kSecClass as String] as? String ?? ""

        // Get the path to the keychain file
        let keychainPath = keychainFolder!
            .appendingPathComponent("\(serviceName)-\(accountName)-\(classType).plist")

        // Read the dictionary from the keychain file
        let keychainDict = NSDictionary(contentsOf: keychainPath)

        // Check the `r_Attributes` key. If it is set to 1 in the query
        // DROP, NOT IMPLEMENTED
        if query["r_Attributes"] as? Int == 1 {
            return errSecItemNotFound
        }

        // If the keychain file doesn't exist, return errSecItemNotFound
        if keychainDict == nil {
            NSLog("BUZZINC: Keychain file not found at \(keychainPath)")
            return errSecItemNotFound
        }

        // Return v_Data if it exists
        if let vData = keychainDict!["v_Data"] {
            NSLog("BUZZINC: Read keychain file from \(keychainPath)")
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

        return errSecSuccess
    }
}
