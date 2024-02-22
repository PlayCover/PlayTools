//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import Foundation
import Security
import SQLite3

class PlayKeychainDB: NSObject {
    public static let shared = PlayKeychainDB()

    private var dbLock: DispatchSemaphore = .init(value: 1)
    // https://developer.apple.com/documentation/security/keychain_services/keychain_items/item_class_keys_and_values
    // Synchronizable does not matter.
    private let primaryAttributes = [
        kSecClassGenericPassword: [
            kSecAttrAccessGroup,
            kSecAttrAccount,
            kSecAttrService,
            // kSecAttrSynchronizable
        ],
        kSecClassInternetPassword: [
            kSecAttrAccessGroup,
            kSecAttrAccount,
            kSecAttrAuthenticationType,
            kSecAttrPath,
            kSecAttrPort,
            kSecAttrProtocol,
            kSecAttrSecurityDomain,
            kSecAttrServer,
            // kSecAttrSynchronizable
        ],
        kSecClassCertificate: [
            kSecAttrAccessGroup,
            kSecAttrCertificateType,
            kSecAttrIssuer,
            kSecAttrSerialNumber,
            // kSecAttrSynchronizable
        ],
        kSecClassKey: [
            kSecAttrAccessGroup,
            kSecAttrApplicationLabel,
            kSecAttrApplicationTag,
            kSecAttrEffectiveKeySize,
            kSecAttrKeyClass,
            kSecAttrKeySizeInBits,
            kSecAttrKeyType,
            // kSecAttrSynchronizable
        ],
        kSecClassIdentity: [
            kSecAttrAccessGroup,
            kSecAttrCertificateType,
            kSecAttrIssuer,
            kSecAttrSerialNumber,
            // kSecAttrSynchronizable
        ]
    ]
    private let secondaryAttributes = [
        kSecClassGenericPassword: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrCreator,
            kSecAttrType,
            kSecAttrLabel,
            kSecAttrIsInvisible,
            kSecAttrIsNegative,
            kSecAttrGeneric
        ],
        kSecClassInternetPassword: [
            kSecAttrAccessControl,
            kSecAttrAccessible,
            kSecAttrCreationDate,
            kSecAttrModificationDate,
            kSecAttrDescription,
            kSecAttrComment,
            kSecAttrCreator,
            kSecAttrType,
            kSecAttrLabel,
            kSecAttrIsInvisible,
            kSecAttrIsNegative,
            kSecAttrGeneric
        ],
        kSecClassCertificate: [
            kSecAttrCertificateEncoding,
            kSecAttrLabel,
            kSecAttrSubject,
            kSecAttrSubjectKeyID,
            kSecAttrPublicKeyHash
        ],
        kSecClassKey: [
            kSecAttrAccessible,
            kSecAttrLabel,
            kSecAttrIsPermanent,
            kSecAttrCanEncrypt,
            kSecAttrCanDecrypt,
            kSecAttrCanDerive,
            kSecAttrCanSign,
            kSecAttrCanVerify,
            kSecAttrCanWrap,
            kSecAttrCanUnwrap
        ],
        kSecClassIdentity: [
            kSecAttrCertificateEncoding,
            kSecAttrLabel,
            kSecAttrSubject,
            kSecAttrSubjectKeyID,
            kSecAttrPublicKeyHash
        ]
    ]
    private let valueContants = [
        kSecValueData,
        kSecValueRef,
        kSecValuePersistentRef
    ]

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        guard let table_name = attributes[kSecClass] as? String,
              let primaryColumns = primaryAttributes[table_name as CFString] else {
            return nil
        }

        let where_qeury = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")
        guard where_qeury.count > 0 else { return nil }
        let select_query = "SELECT * FROM \(table_name) WHERE \(where_qeury)"
        var stmt: OpaquePointer?

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, select_query, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(select_query)")
                PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            let max_count = (attributes[kSecMatchLimit] as? String == kSecMatchLimitOne as String ? 1 : Int.max)
            while sqlite3_step(stmt) == SQLITE_ROW && dictArr.count < max_count {
                let newDict: NSMutableDictionary = [:]
                let columns = sqlite3_column_count(stmt)
                newDict[kSecClass] = table_name
                for index in 0..<columns {
                    let name = String(cString: sqlite3_column_name(stmt, index))
                    if let value = decodeData(stmt: stmt, index: index) {
                        newDict[name] = value
                    }
                }
                dictArr.append(newDict)
            }

            return true
        }) else { return nil }

        return dictArr
    }

    func insert(_ attributes: NSDictionary) -> Bool {
        guard let table_name = attributes[kSecClass] as? String,
              let primaryColumns = primaryAttributes[table_name as CFString],
              let secondaryColumns = secondaryAttributes[table_name as CFString] else {
            return false
        }

        var columns_query = primaryColumns.map({
            return "\($0)"
        })
        columns_query.append(contentsOf: secondaryColumns.compactMap({
            return attributes[$0] != nil ? "\($0)" : nil
        }))
        columns_query.append(contentsOf: valueContants.compactMap({
            return attributes[$0] != nil ? "\($0)" : nil
        }))

        let values_query = columns_query.map({
            return attributes[$0] as CFTypeRef
        })
        let insert_query = "INSERT INTO \(table_name) (\(columns_query.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: values_query.count).joined(separator: ", ")))"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, insert_query, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(insert_query)")
                PlayKeychain.debugLogger("Failed to make query: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in values_query.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to insert into db: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return false }

        return true
    }

    func update(_ attributes: NSDictionary) -> Bool {
        guard let table_name = attributes[kSecClass] as? String,
              let primaryColumns = primaryAttributes[table_name as CFString],
              let secondaryColumns = secondaryAttributes[table_name as CFString] else {
            return false
        }

        var columns_query = primaryColumns.map({
            return "\($0)"
        })
        columns_query.append(contentsOf: secondaryColumns.compactMap({
            return attributes[$0] != nil ? "\($0)" : nil
        }))
        columns_query.append(contentsOf: valueContants.compactMap({
            return attributes[$0] != nil ? "\($0)" : nil
        }))

        let values_qeury = columns_query.map({
            return attributes[$0] as CFTypeRef
        })
        let where_qeury = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil }
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // \0 does not exists in db due to casting
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")
        let update_query = "UPDATE \(table_name) SET \(columns_query.map({ return "\($0) = ?" }).joined(separator: ", ")) WHERE \(where_qeury)"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, update_query, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(update_query)")
                PlayKeychain.debugLogger("Failed to make query: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in values_qeury.enumerated() {
                if !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                    PlayKeychain.debugLogger("Failed to update into db: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                    return false
                }
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return false }

        return true
    }

    func delete(_ attributes: NSDictionary) -> Bool {
        guard let table_name = attributes[kSecClass] as? String,
              let primaryColumns = primaryAttributes[table_name as CFString] else {
            return false
        }

        let where_qeury = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")
        let delete_query = "DELETE FROM \(table_name) where \(where_qeury)"
        var stmt: OpaquePointer?
        PlayKeychain.debugLogger(delete_query)

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, delete_query, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(delete_query)")
                PlayKeychain.debugLogger("Failed to delte items from db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_OK
        }) else { return false }

        return true
    }

    private func structDB(_ sqlite3DB: OpaquePointer) -> Bool {
        for (key, value) in primaryAttributes {
            var columns: [CFString] = value
            columns.append(contentsOf: secondaryAttributes[key]!)
            columns.append(contentsOf: valueContants)
            let columnsSetting = columns.map({ return "\($0) TEXT" }).joined(separator: ", ")
            let primaryKeysSetting = "PRIMARY KEY (\(value.map({ return "\($0)" }).joined(separator: ", ")))"
            let create_table_query = "CREATE TABLE IF NOT EXISTS \(key) (\(columnsSetting), \(primaryKeysSetting));"
            guard sqlite3_exec(sqlite3DB, create_table_query, nil, nil, nil) == SQLITE_OK else {
                PlayKeychain.debugLogger("Failed query \(create_table_query)")
                PlayKeychain.debugLogger("Failed to create db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }
        }

        return true
    }

    private func usingDB(_ callback: (OpaquePointer) -> Bool) -> Bool {
        dbLock.wait()
        defer { dbLock.signal() }

        guard let sqlite3DB = connectToDB() else { return false }
        let result = callback(sqlite3DB)
        guard disconnectFromDB(sqlite3DB) else { return false }
        return result
    }

    private func connectToDB() -> OpaquePointer? {
        var sqlite3DB: OpaquePointer?
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        let keychainDB = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("PlayChain")
            .appendingPathComponent("\(bundleID).db")
        let alreadyCreated = FileManager.default.fileExists(atPath: keychainDB.path)
        guard sqlite3_open(keychainDB.path, &sqlite3DB) == SQLITE_OK,
              let sqlite3DB = sqlite3DB else {
            return nil
        }
        guard alreadyCreated ? true : structDB(sqlite3DB) else {
            _ = disconnectFromDB(sqlite3DB)
            return nil
        }
        return sqlite3DB
    }

    private func disconnectFromDB(_ sqlite3DB: OpaquePointer?) -> Bool {
        guard sqlite3_close(sqlite3DB) == SQLITE_OK else { return false }
        return true
    }

    private func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqlite_transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let string = value as! String // swiftlint:disable:this force_cast
            result = sqlite3_bind_text(stmt, index, string, -1, sqlite_transient)
        case CFDataGetTypeID():
            let data = value as! CFData // swiftlint:disable:this force_cast
            let ptr = CFDataGetBytePtr(data)
            let size = CFDataGetLength(data)
            result = sqlite3_bind_blob(stmt, index, ptr, Int32(size), sqlite_transient)
        default:
            PlayKeychain.debugLogger("Cannot encode this data type: \(CFGetTypeID(value))")
            result = sqlite3_bind_null(stmt, index)
        }

        return result == SQLITE_OK
    }

    private func decodeData(stmt: OpaquePointer, index: Int32) -> CFTypeRef? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            return CFStringCreateWithCString(nil, ptr, kCFStringEncodingASCII)
        case SQLITE_BLOB:
            guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
            let size = sqlite3_column_bytes(stmt, index)
            return CFDataCreate(nil, ptr, CFIndex(size))
        default:
            return nil
        }
    }
}
