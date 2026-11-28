//
//  PlayWeRuinedIt.swift
//  PlayTools
//
//  Created by Venti on 16/01/2023.
//

import Foundation
import Security

public class PlayKeychain: NSObject {
    static let shared = PlayKeychain()
    private static let playChainDB = PlayKeychainDB.shared
    private static let referencePrefix = Data("PTK1".utf8)
    private static let referenceIDLength = 16

    @objc public static func debugLogger(_ logContent: String) {
        if PlaySettings.shared.settingsData.playChainDebugging {
            NSLog("PC-DEBUG: \(logContent)")
        }
    }

    private static func flag(_ dictionary: NSDictionary, _ key: CFString) -> Bool {
        (dictionary[key] as? NSNumber)?.boolValue ?? false
    }

    private struct ReturnValues {
        let attributes: Bool
        let data: Bool
        let reference: Bool
        let persistentReference: Bool

        init(_ options: NSDictionary) {
            attributes = flag(options, kSecReturnAttributes)
            data = flag(options, kSecReturnData)
            reference = flag(options, kSecReturnRef)
            persistentReference = flag(options, kSecReturnPersistentRef)
        }

        var isEmpty: Bool { !attributes && !data && !reference && !persistentReference }

        func project(_ item: NSDictionary) -> CFTypeRef? {
            let result = attributes ? NSMutableDictionary(dictionary: item) : NSMutableDictionary()
            result.removeObject(forKey: PlayKeychainDB.itemIDColumn)
            result.removeObject(forKey: kSecValueData)
            result.removeObject(forKey: kSecValueRef)
            result.removeObject(forKey: kSecValuePersistentRef)
            if attributes { ensureAccessGroupIfApplicable(result) }

            var value: CFTypeRef?
            var count = 0
            if data {
                guard let bytes = item[kSecValueData] as? Data else { return nil }
                value = bytes as CFData
                result[kSecValueData] = bytes
                count += 1
            }
            if reference {
                guard let ref = itemReference(item) else { return nil }
                value = ref
                result[kSecValueRef] = ref
                count += 1
            }
            if persistentReference {
                guard let ref = persistentReferenceForItem(item) else { return nil }
                value = ref as CFData
                result[kSecValuePersistentRef] = ref
                count += 1
            }
            return attributes || count > 1 ? result : value
        }
    }

    @objc public static func add(_ attributes: NSDictionary,
                                 result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        result?.pointee = nil
        guard let item = prepareItem(attributes) else { return errSecParam }
        let requested = ReturnValues(attributes)
        let value: CFTypeRef?
        if result != nil && !requested.isEmpty {
            guard let projected = requested.project(item) else { return errSecParam }
            value = projected
        } else {
            value = nil
        }

        let status = playChainDB.insert([item]).status
        if status == errSecSuccess, let value {
            result?.pointee = Unmanaged.passRetained(value)
        }
        return status
    }

    @objc public static func copyMatching(_ query: NSDictionary,
                                          result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        result?.pointee = nil
        guard let resolved = resolveQuery(query), let limit = matchLimit(query[kSecMatchLimit]) else {
            return errSecParam
        }
        let requested = ReturnValues(query)
        let sqlLimit = requested.isEmpty || result == nil ? 1 : limit
        guard let items = playChainDB.query(resolved.attributes, itemID: resolved.itemID, limit: sqlLimit) else {
            return errSecIO
        }
        guard !items.isEmpty else { return errSecItemNotFound }
        guard !requested.isEmpty, let result else { return errSecSuccess }

        let values = items.compactMap { requested.project($0) }
        guard let first = values.first else { return errSecItemNotFound }
        let value = limit == 1 ? first : values as CFTypeRef
        result.pointee = Unmanaged.passRetained(value)
        return errSecSuccess
    }

    @objc public static func update(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        guard let resolved = resolveQuery(query) else { return errSecParam }
        return playChainDB.update(query: resolved.attributes, attributesToUpdate: attributesToUpdate,
                                  itemID: resolved.itemID).status
    }

    @objc public static func delete(_ query: NSDictionary) -> OSStatus {
        guard let resolved = resolveQuery(query) else { return errSecParam }
        return playChainDB.delete(resolved.attributes, itemID: resolved.itemID).status
    }

    private static func matchLimit(_ value: Any?) -> Int? {
        guard let value else { return 1 }
        if let word = value as? String {
            if word == kSecMatchLimitOne as String { return 1 }
            if word == kSecMatchLimitAll as String { return -1 } // SQLite's unbounded LIMIT.
            return nil
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let limit = number.intValue
        return limit > 0 && number == NSNumber(value: limit) ? limit : nil
    }

    private static func prepareItem(_ attributes: NSDictionary) -> NSMutableDictionary? {
        guard let itemClass = attributes[kSecClass] as? String,
              PlayedAppleDBConstants.primaries[itemClass as CFString] != nil else { return nil }
        let normalized = normalizedAccessGroupDict(attributes)
        let table = itemClass as CFString
        let storageKeys = (PlayedAppleDBConstants.primaries[table] ?? [])
            + (PlayedAppleDBConstants.attributes[table] ?? [])
            + [kSecValueData, kSecValueRef, kSecAttrSynchronizable]
        let item = NSMutableDictionary()
        item[kSecClass] = itemClass
        for key in storageKeys {
            if let value = normalized[key] { item[key] = value }
        }
        var uuid = UUID().uuid
        // Opaque IDs are scoped to this database and survive changes to the item's attributes.
        item[PlayKeychainDB.itemIDColumn] = withUnsafeBytes(of: &uuid) { Data($0) }
        return item
    }

    private static func persistentReferenceForItem(_ item: NSDictionary) -> Data? {
        guard let itemClass = item[kSecClass] as? String,
              let itemID = item[PlayKeychainDB.itemIDColumn] as? Data,
              itemID.count == referenceIDLength else { return nil }
        return referencePrefix + Data(itemClass.utf8) + itemID
    }

    private static func resolveQuery(_ query: NSDictionary) -> (attributes: NSDictionary, itemID: Data?)? {
        guard let value = query[kSecValuePersistentRef] else {
            guard let itemClass = query[kSecClass] as? String,
                  PlayedAppleDBConstants.primaries[itemClass as CFString] != nil else { return nil }
            return (query, nil)
        }

        let classLength = 4 // All supported SecItem classes have four-character names.
        guard let reference = value as? Data,
              reference.count == referencePrefix.count + classLength + referenceIDLength,
              reference.starts(with: referencePrefix),
              let itemClass = String(data: reference.dropFirst(referencePrefix.count).prefix(classLength),
                                     encoding: .ascii),
              PlayedAppleDBConstants.primaries[itemClass as CFString] != nil else { return nil }
        if let givenClass = query[kSecClass], (givenClass as? String) != itemClass { return nil }

        let attributes = NSMutableDictionary(dictionary: query)
        attributes.removeObject(forKey: kSecValuePersistentRef)
        attributes[kSecClass] = itemClass
        return (attributes, Data(reference.suffix(referenceIDLength)))
    }

    private static func itemReference(_ item: NSDictionary) -> CFTypeRef? {
        guard let bytes = item[kSecValueData] as? Data,
              let itemClass = item[kSecClass] as? String else { return nil }
        if itemClass == kSecClassCertificate as String {
            return SecCertificateCreateWithData(nil, bytes as CFData)
        }
        guard itemClass == kSecClassKey as String,
              let keyType = item[kSecAttrKeyType] as? String,
              let keyClass = item[kSecAttrKeyClass] as? String else { return nil }
        let attributes = [kSecAttrKeyType: keyType, kSecAttrKeyClass: keyClass]
        return SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, nil)
    }
}

extension PlayKeychain {
    private struct KeyCreation {
        let privateKey: SecKey
        let publicKey: SecKey?
    }

    @objc public static func keyCreateRandomKey(_ parameters: NSDictionary,
                                                error: UnsafeMutablePointer<Unmanaged<CFError>?>?)
    -> Unmanaged<SecKey>? {
        var generationError: Unmanaged<CFError>?
        guard let keys = generateKeys(parameters, needsPublicKey: false, error: &generationError) else {
            if let generationError {
                if let error {
                    error.pointee = generationError
                } else {
                    generationError.release()
                }
            }
            return nil
        }
        return Unmanaged.passRetained(keys.privateKey)
    }

    @objc public static func keyGeneratePair(_ parameters: NSDictionary,
                                             publicKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?,
                                             privateKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?) -> OSStatus {
        publicKey?.pointee = nil
        privateKey?.pointee = nil
        var error: Unmanaged<CFError>?
        guard let keys = generateKeys(parameters, needsPublicKey: publicKey != nil, error: &error) else {
            guard let failure = error?.takeRetainedValue(),
                  CFErrorGetDomain(failure) == kCFErrorDomainOSStatus,
                  let status = OSStatus(exactly: CFErrorGetCode(failure)) else { return errSecInternalError }
            return status
        }
        if let key = keys.publicKey {
            publicKey?.pointee = Unmanaged.passRetained(key)
        }
        privateKey?.pointee = Unmanaged.passRetained(keys.privateKey)
        return errSecSuccess
    }

    private static func generateKeys(_ parameters: NSDictionary, needsPublicKey: Bool,
                                     error: inout Unmanaged<CFError>?) -> KeyCreation? {
        guard let topLevel = parameters as? [String: Any],
              let privateOverrides = keyOverrides(topLevel, key: kSecPrivateKeyAttrs),
              let publicOverrides = keyOverrides(topLevel, key: kSecPublicKeyAttrs) else {
            error = keyError(errSecParam)
            return nil
        }

        let privateAttributes = topLevel.merging(privateOverrides) { _, override in override }
        let publicAttributes = topLevel.merging(publicOverrides) { _, override in override }
        let permanent: (keyPrivate: Bool, keyPublic: Bool) = (
            flag(privateAttributes as NSDictionary, kSecAttrIsPermanent),
            flag(publicAttributes as NSDictionary, kSecAttrIsPermanent)
        )

        // Generate ephemeral native keys. On macOS the legacy pair API may write to the
        // system keychain even when its permanence flags are false.
        var nativeParameters = topLevel
        let permanenceKey = kSecAttrIsPermanent as String
        nativeParameters[permanenceKey] = false
        nativeParameters[kSecPrivateKeyAttrs as String] = privateOverrides.merging([permanenceKey: false]) { _, off in
            off
        }
        nativeParameters[kSecPublicKeyAttrs as String] = publicOverrides.merging([permanenceKey: false]) { _, off in
            off
        }
        guard let privateKey = SecKeyCreateRandomKey(nativeParameters as CFDictionary, &error) else {
            if error == nil { error = keyError(errSecInternalError) }
            return nil
        }
        let publicKey = needsPublicKey || permanent.keyPublic ? SecKeyCopyPublicKey(privateKey) : nil
        if (needsPublicKey || permanent.keyPublic) && publicKey == nil {
            error = keyError(errSecInternalError)
            return nil
        }

        var entries: [NSDictionary] = []
        if permanent.keyPrivate {
            guard let item = generatedKeyItem(privateKey, attributes: privateAttributes,
                                              keyClass: kSecAttrKeyClassPrivate, error: &error) else { return nil }
            entries.append(item)
        }
        if let publicKey, permanent.keyPublic {
            guard let item = generatedKeyItem(publicKey, attributes: publicAttributes,
                                              keyClass: kSecAttrKeyClassPublic, error: &error) else { return nil }
            entries.append(item)
        }

        if !entries.isEmpty {
            let status = playChainDB.insert(entries).status
            guard status == errSecSuccess else {
                error = keyError(status)
                return nil
            }
        }
        return KeyCreation(privateKey: privateKey, publicKey: publicKey)
    }

    private static func keyOverrides(_ dictionary: [String: Any], key: CFString) -> [String: Any]? {
        guard let value = dictionary[key as String] else { return [:] }
        return value as? [String: Any]
    }

    private static func generatedKeyItem(_ key: SecKey, attributes: [String: Any], keyClass: CFString,
                                         error: inout Unmanaged<CFError>?) -> NSDictionary? {
        guard let bytes = SecKeyCopyExternalRepresentation(key, &error) else {
            if error == nil { error = keyError(errSecInternalError) }
            return nil
        }
        let native = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let keyTable = kSecClassKey
        let legalAttributes = (PlayedAppleDBConstants.primaries[keyTable] ?? [])
            + (PlayedAppleDBConstants.attributes[keyTable] ?? [])
        var item: [String: Any] = [
            kSecClass as String: keyTable,
            kSecAttrKeyClass as String: keyClass,
            kSecAttrIsPermanent as String: true,
            kSecValueData as String: bytes
        ]
        for attribute in legalAttributes where attribute != kSecAttrKeyClass && attribute != kSecAttrIsPermanent {
            let name = attribute as String
            item[name] = attributes[name] ?? native[name]
        }
        guard let prepared = prepareItem(item as NSDictionary) else {
            error = keyError(errSecParam)
            return nil
        }
        return prepared
    }

    private static func keyError(_ status: OSStatus) -> Unmanaged<CFError> {
        .passRetained(CFErrorCreate(nil, kCFErrorDomainOSStatus, CFIndex(status), nil))
    }
}
