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
    private static let playChainDB = PlayKeychainDB.shared

    @objc public static func debugLogger(_ logContent: String) {
        if PlaySettings.shared.settingsData.playChainDebugging {
            NSLog("PC-DEBUG: \(logContent)")
        }
    }

    private static func flag(_ dictionary: NSDictionary, _ key: CFString) -> Bool {
        let value = dictionary[key as String]
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }
    // Emulates SecItemAdd, SecItemUpdate, SecItemDelete and SecItemCopyMatching
    // Store the entire dictionary as a plist
    // SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
    @objc static public func add(_ attributes: NSDictionary,
                                 result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard let keychainDict = playChainDB.insert(attributes) else {
            debugLogger("Failed to write keychain file")
            return errSecIO
        }
        debugLogger("Wrote keychain item to db")

        let wantsReturn =
            flag(attributes, kSecReturnAttributes) ||
            flag(attributes, kSecReturnData) ||
            flag(attributes, kSecReturnRef) ||
            flag(attributes, kSecReturnPersistentRef)

        guard wantsReturn, result != nil else {
            return errSecSuccess
        }

        // Place v_Data in the result
        guard let vData = attributes["v_Data"] as? CFTypeRef else {
            return errSecSuccess
        }

        if attributes["r_Attributes"] as? Int == 1 {
            // Create a dummy dictionary and return it
            let dummyDict = keychainDict
            if attributes["r_Data"] as? Int != 1 {
                dummyDict.removeObject(forKey: kSecValueData)
                dummyDict.removeObject(forKey: kSecValueRef)
                dummyDict.removeObject(forKey: kSecValuePersistentRef)
            }
            result?.pointee = Unmanaged.passRetained(dummyDict)
            return errSecSuccess
        }

        if flag(attributes, kSecReturnData) &&
            !flag(attributes, kSecReturnRef) &&
            !flag(attributes, kSecReturnPersistentRef) {
            result?.pointee = Unmanaged.passRetained(vData)
            return errSecSuccess
        }

        if attributes["class"] as? String == "keys" {
            if let keyDataValue = vData as? Data {
                // kSecAttrKeyType is stored as `type` in the dictionary
                // kSecAttrKeyClass is stored as `kcls` in the dictionary
                let keyAttributesDictionary = [
                    kSecAttrKeyType: attributes["type"] as? String
                        ?? (attributes[kSecAttrKeyType as String] as? String),
                    kSecAttrKeyClass: attributes["kcls"] as? String
                        ?? (attributes[kSecAttrKeyType as String] as? String)
                ]
                if let key = SecKeyCreateWithData(
                    keyDataValue as CFData,
                    keyAttributesDictionary as CFDictionary,
                    nil
                ) {
                    result?.pointee = Unmanaged.passRetained(key)
                    return errSecSuccess
                }
            }
            return errSecBadReq
        }
        result?.pointee = Unmanaged.passRetained(vData)
        return errSecSuccess
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        guard let keychainDict = playChainDB.query(query)?.first else {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }
        debugLogger("Select keychain item from db")
        // Reconstruct the dictionary (subscripting won't work as assignment is not allowed)
        let newKeychainDict = NSMutableDictionary()
        for (key, value) in keychainDict {
            newKeychainDict.setValue(value, forKey: key as! String) // swiftlint:disable:this force_cast
        }
        // Update the dictionary
        for (key, value) in attributesToUpdate {
            newKeychainDict.setValue(value, forKey: key as! String) // swiftlint:disable:this force_cast
        }
        guard playChainDB.update(newKeychainDict) else {
            debugLogger("Failed to update keychain item to db")
            return errSecIO
        }

        return errSecSuccess
    }

    // SecItemDelete(CFDictionaryRef query)
    @objc static public func delete(_ query: NSDictionary) -> OSStatus {
        guard playChainDB.query(query)?.first != nil else {
            debugLogger("Failed to find keychain item")
            return errSecItemNotFound
        }
        guard playChainDB.delete(query) else {
            debugLogger("Failed to delete keychain item")
            return errSecIO
        }
        debugLogger("Deleted keychain item in db")
        return errSecSuccess
    }

    // SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
    // swiftlint:disable:next function_body_length
    @objc static public func copyMatching(_ query: NSDictionary,
                                          result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard let keychainDicts = playChainDB.query(query),
              let keychainDict = keychainDicts.first else {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }

        let wantsAttributes = flag(query, kSecReturnAttributes)
        let wantsData = flag(query, kSecReturnData)
        let wantsRef = flag(query, kSecReturnRef)
        let wantsPersistentRef = flag(query, kSecReturnPersistentRef)

        if query[kSecMatchLimit as String] as? String ==  kSecMatchLimitAll as String {
            if wantsData && !wantsAttributes && !wantsRef && !wantsPersistentRef {
                let values = keychainDicts.compactMap({ $0[kSecValueData] })
                guard values.count == keychainDicts.count else {
                    return errSecItemNotFound
                }
                result?.pointee = Unmanaged.passRetained(values as CFTypeRef)
                return errSecSuccess
            }

            result?.pointee = Unmanaged.passRetained(keychainDicts.map({
                if !wantsData {
                    $0.removeObject(forKey: kSecValueData)
                }
                $0.removeObject(forKey: kSecValueRef)
                $0.removeObject(forKey: kSecValuePersistentRef)
                return $0
            }) as CFTypeRef)
            return errSecSuccess
        }
        // Check the `r_Attributes` key. If it is set to 1 in the query
        let classType = query[kSecClass as String] as? String ?? ""

        if wantsAttributes {
            // Create a dummy dictionary and return it
            let dummyDict = keychainDict
            if !wantsData {
                dummyDict.removeObject(forKey: kSecValueData)
                dummyDict.removeObject(forKey: kSecValueRef)
                dummyDict.removeObject(forKey: kSecValuePersistentRef)
            }
            result?.pointee = Unmanaged.passRetained(dummyDict)
            return errSecSuccess
        }

        // kSecReturnData asks for the stored bytes, even for kSecClassKey.
        if wantsData && !wantsRef && !wantsPersistentRef {
            guard let vData = keychainDict[kSecValueData] else {
                return errSecItemNotFound
            }
            result?.pointee = Unmanaged.passRetained(vData as CFTypeRef)
            return errSecSuccess
        }

        // A query without return flags is an existence check.
        if !wantsAttributes && !wantsData && !wantsRef && !wantsPersistentRef {
            return errSecSuccess
        }

        // Check for r_Ref
        if wantsRef {
            // Return the data on v_PersistentRef or v_Data if they exist
            var key: CFTypeRef?
            if let vData = keychainDict[kSecValueData] {
                NSLog("found v_Data")
                debugLogger("Read keychain item from db")
                key = vData as CFTypeRef
            }
            if let vPersistentRef = keychainDict[kSecValuePersistentRef] {
                NSLog("found persistent ref")
                debugLogger("Read keychain item from db")
                key = vPersistentRef as CFTypeRef
            }

            if key == nil {
                debugLogger("Keychain item not found in db")
                return errSecItemNotFound
            }

            let dummyKeyAttrs = [
                kSecAttrKeyType: keychainDict[kSecAttrKeyType] ?? kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: keychainDict[kSecAttrKeyClass] ?? kSecAttrKeyClassPublic
            ] as CFDictionary

            let secKey = SecKeyCreateWithData(key as! CFData, dummyKeyAttrs, nil) // swiftlint:disable:this force_cast
            result?.pointee = Unmanaged.passRetained(secKey!)
            return errSecSuccess
        }

        // Return v_Data if it exists
        if let vData = keychainDict[kSecValueData] {
            debugLogger("Read keychain file from db")
            // Check the class type, if it is a key we need to return the data
            // as SecKeyRef, otherwise we can return it as a CFTypeRef
            if classType == "keys" {
                // kSecAttrKeyType is stored as `type` in the dictionary
                // kSecAttrKeyClass is stored as `kcls` in the dictionary
                let keyAttributes = [
                    kSecAttrKeyType: keychainDict[kSecAttrKeyType] as! CFString, // swiftlint:disable:this force_cast
                    kSecAttrKeyClass: keychainDict[kSecAttrKeyClass] as! CFString // swiftlint:disable:this force_cast
                ]
                let keyData = vData as! Data // swiftlint:disable:this force_cast
                let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil)
                result?.pointee = Unmanaged.passRetained(key!)
                return errSecSuccess
            }
            result?.pointee = Unmanaged.passRetained(vData as CFTypeRef)
            return errSecSuccess
        }

        return errSecItemNotFound
    }

    @objc static public func keyCreateRandomKey(_ parameters: NSDictionary,
                                                error: UnsafeMutablePointer<Unmanaged<CFError>?>?)
    -> Unmanaged<SecKey>? {
        // Check if kSecAttrIsPermanent is set to 1 in kSecPrivateKeyAttrs.
        // If it is, set it to 0 before fowarding the call to SecKeyCreateRandomKey, 
        // and then add the key to the keychain db with the original attributes (with kSecAttrIsPermanent set to 1)
        var privateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        let isPermanent = privateKeyAttrs[kSecAttrIsPermanent as String] as? Bool ?? false
        if isPermanent {
            privateKeyAttrs[kSecAttrIsPermanent as String] = false
        }
        var parametersCopy = parameters as! [String: Any] // swiftlint:disable:this force_cast
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(parametersCopy as CFDictionary, &error) else {
            debugLogger("Failed to create random key: \(error!.takeRetainedValue())")
            return nil
        }
        if isPermanent {
            // Add the key to the keychain db with the original attributes
            var keychainDict = [String: Any]()
            keychainDict[kSecClass as String] = kSecClassKey
            keychainDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            keychainDict[kSecAttrKeyClass as String] = parameters[kSecAttrKeyClass as String]
            keychainDict["type"] = parameters[kSecAttrKeyType as String]
            keychainDict["kcls"] = parameters[kSecAttrKeyClass as String]
            keychainDict["v_Data"] = SecKeyCopyExternalRepresentation(key, nil) as? Data
            keychainDict["r_Attributes"] = 1
            guard playChainDB.insert(keychainDict as NSDictionary) != nil else {
                debugLogger("Failed to write keychain file")
                return nil
            }
        }
        return Unmanaged.passRetained(key)
    }

    // swiftlint:disable:next function_body_length
    @objc static public func keyGeneratePair(_ parameters: NSDictionary,
                                             publicKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?,
                                             privateKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?) -> OSStatus {
        // Same as above but we need to disable kSecAttrIsPermanent for both the public and private key.
        var isPermanent = parameters[kSecAttrIsPermanent as String] as? Bool ?? false
        var privateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        let isPrivatePermanent = privateKeyAttrs[kSecAttrIsPermanent as String] as? Bool ?? false
        if isPrivatePermanent {
            privateKeyAttrs[kSecAttrIsPermanent as String] = false
            isPermanent = true
        }
        var publicKeyAttrs = parameters[kSecPublicKeyAttrs as String] as? [String: Any] ?? [:]
        let isPublicPermanent = (publicKeyAttrs[kSecAttrIsPermanent as String] as? Bool) ?? false
        if isPublicPermanent {
            publicKeyAttrs[kSecAttrIsPermanent as String] = false
            isPermanent = true
        }
        var parametersCopy = parameters as! [String: Any] // swiftlint:disable:this force_cast
        parametersCopy.removeValue(forKey: kSecAttrIsPermanent as String)
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        parametersCopy[kSecPublicKeyAttrs as String] = publicKeyAttrs
        var newPublicKey: SecKey?
        var newPrivateKey: SecKey?
        guard SecKeyGeneratePair(parametersCopy as CFDictionary, &newPublicKey, &newPrivateKey) == 0 else {
            debugLogger("Failed to generate key pair.")
            return errSecMissingEntitlement
        }
        if let newPublicKey = newPublicKey {
            publicKey?.pointee = Unmanaged.passRetained(newPublicKey)
        }
        if let newPrivateKey = newPrivateKey {
            privateKey?.pointee = Unmanaged.passRetained(newPrivateKey)
        }
        if isPermanent {
            // Add the keys to the keychain db with the original attributes
            let publicKeyRef = newPublicKey
            let privateKeyRef = newPrivateKey
            var publicKeyDict = [String: Any]()
            publicKeyDict[kSecClass as String] = kSecClassKey
            publicKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            publicKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPublic
            publicKeyDict["type"] = parameters[kSecAttrKeyType as String]
            publicKeyDict["kcls"] = kSecAttrKeyClassPublic
            publicKeyDict["v_Data"] = SecKeyCopyExternalRepresentation(publicKeyRef!, nil) as? Data
            publicKeyDict["r_Attributes"] = 1
            guard playChainDB.insert(publicKeyDict as NSDictionary) != nil else {
                debugLogger("Failed to write public key to keychain db")
                return errSecMissingEntitlement
            }
            var privateKeyDict = [String: Any]()
            privateKeyDict[kSecClass as String] = kSecClassKey
            privateKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            privateKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
            privateKeyDict["type"] = parameters[kSecAttrKeyType as String]
            privateKeyDict["kcls"] = kSecAttrKeyClassPrivate
            privateKeyDict["v_Data"] = SecKeyCopyExternalRepresentation(privateKeyRef!, nil) as? Data
            privateKeyDict["r_Attributes"] = 1
            guard playChainDB.insert(privateKeyDict as NSDictionary) != nil else {
                debugLogger("Failed to write private key to keychain db")
                return errSecMissingEntitlement
            }
        }
        return errSecSuccess
    }
}
