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
    private var dbVersion: Int = 2

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return nil
        }

        let selectWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")
        guard selectWhere.count > 0 else { return nil }
        let selectLimit = PlayKeychainDB.matchLimit(attributes)

        let selectQuery = "SELECT * FROM \(tableName) WHERE \(selectWhere) LIMIT \(selectLimit)"
        var stmt: OpaquePointer?

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, selectQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(selectQuery)")
                PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            while sqlite3_step(stmt) == SQLITE_ROW && dictArr.count < selectLimit {
                let newDict: NSMutableDictionary = [:]
                let columns = sqlite3_column_count(stmt)
                newDict[kSecClass] = tableName
                newDict[kSecAttrSynchronizable] = attributes[kSecAttrSynchronizable]
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

    func insert(_ attributes: NSDictionary) -> NSMutableDictionary? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return nil
        }

        var columnsQuery = primaryColumns.map({ "\($0)" })
        columnsQuery.append(contentsOf: secondaryColumns.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))

        let insertValues = columnsQuery.map({ attributes[$0] as CFTypeRef })

        let insertColumns = columnsQuery.joined(separator: ", ")
        let insertPlaceholders = Array(repeating: "?", count: insertValues.count).joined(separator: ", ")

        let insertQuery = "INSERT INTO \(tableName) (\(insertColumns)) VALUES (\(insertPlaceholders))"
        var stmt: OpaquePointer?

        let newDict: NSMutableDictionary = [:]
        newDict[kSecClassKey] = tableName
        for column in columnsQuery {
            newDict[column] = attributes[column]
        }

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, insertQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(insertQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                return false
            }

            for (index, value) in insertValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let erorrMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to insert into db: \(erorrMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return nil }

        return newDict
    }

    func update(_ attributes: NSDictionary) -> Bool {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return false
        }

        var columnsQuery = primaryColumns.map({ "\($0)" })
        columnsQuery.append(contentsOf: secondaryColumns.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))

        let updateValues = columnsQuery.map({ attributes[$0] as CFTypeRef })

        let updateColumns = columnsQuery.map({ return "\($0) = ?" }).joined(separator: ", ")
        let updateWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil }
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // \0 does not exists in db due to casting
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")

        let updateQuery = "UPDATE \(tableName) SET \(updateColumns) WHERE \(updateWhere)"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, updateQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(updateQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                return false
            }

            for (index, value) in updateValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to update into db: \(errorMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return false }

        return true
    }

    func delete(_ attributes: NSDictionary) -> Bool {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return false
        }

        let deleteWhere = primaryColumns.compactMap({
            guard let attr = attributes[$0] else { return nil } // use only requested ones
            if CFGetTypeID(attr as CFTypeRef) == CFDataGetTypeID(),
               let string = (attr as? Data).map({ return String(data: $0, encoding: .utf8) }) {
                return "\($0) LIKE '\(string!)'" // non null-termination in db
            }
            return "\($0) = '\(attr)'"
        }).joined(separator: " AND ")

        let deleteQuery = "DELETE FROM \(tableName) where \(deleteWhere)"
        var stmt: OpaquePointer?

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, deleteQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                PlayKeychain.debugLogger("Failed to delte items from db table: \(errorMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_OK
        }) else { return false }

        return true
    }

    private func structDB(_ sqlite3DB: OpaquePointer) -> Bool {
        for (key, value) in PlayedAppleDBConstants.primaries {
            var columns: [CFString] = value
            columns.append(contentsOf: PlayedAppleDBConstants.attributes[key]!)
            columns.append(contentsOf: PlayedAppleDBConstants.values)
            let columnsSetting = columns.map({ return "\($0) TEXT" }).joined(separator: ", ")
            let primaryKeysSetting = "PRIMARY KEY (\(value.map({ return "\($0)" }).joined(separator: ", ")))"
            let createTableQuery = "CREATE TABLE IF NOT EXISTS \(key) (\(columnsSetting), \(primaryKeysSetting));"
            guard sqlite3_exec(sqlite3DB, createTableQuery, nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(createTableQuery)")
                PlayKeychain.debugLogger("Failed to create db table: \(errorMessage)")
                return false
            }
        }

        if userVersion(sqlite3DB) < 2 && !removeDuplicatePasswordItems(sqlite3DB) {
            return false
        }

        sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion)", nil, nil, nil)

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
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "Shared"
        let keychainDB = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("PlayChain")
            .appendingPathComponent("\(bundleID).db")

        let alreadyCreated = FileManager.default.fileExists(atPath: keychainDB.path)

        guard sqlite3_open(keychainDB.path, &sqlite3DB) == SQLITE_OK,
              let sqlite3DB = sqlite3DB else {
            PlayKeychain.debugLogger("Failed to connect to DB")
            return nil
        }

        if !alreadyCreated || !structDB(sqlite3DB) {
            _ = disconnectFromDB(sqlite3DB)
            return nil
        }

        return sqlite3DB
    }

    private func disconnectFromDB(_ sqlite3DB: OpaquePointer?) -> Bool {
        guard sqlite3_close(sqlite3DB) == SQLITE_OK else {
            PlayKeychain.debugLogger("Failed to disconnect from DB")
            return false
        }

        return true
    }

    private func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let string = value as! String // swiftlint:disable:this force_cast
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            let data = value as! CFData // swiftlint:disable:this force_cast
            let ptr = CFDataGetBytePtr(data)
            let size = CFDataGetLength(data)
            result = sqlite3_bind_blob(stmt, index, ptr, Int32(size), sqliteTransient)
        case CFNullGetTypeID():
            result = sqlite3_bind_null(stmt, index)
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
        case SQLITE_NULL:
            return nil
        default:
            PlayKeychain.debugLogger("Cannot decode this data \(sqlite3_column_type(stmt, index))")
            return nil
        }
    }
}

extension PlayKeychainDB {
    /// kSecMatchLimit as SecItemCopyMatching reads it: kSecMatchLimitOne or no limit is 1,
    /// kSecMatchLimitAll is unlimited, and a number n is n (an array is returned when n > 1).
    static func matchLimit(_ attributes: NSDictionary) -> Int {
        switch attributes[kSecMatchLimit] {
        case let limit as String:
            return limit == kSecMatchLimitAll as String ? Int.max : 1
        case let limit as NSNumber:
            return max(limit.intValue, 1)
        default:
            return 1
        }
    }

    /// Whether a stored item already has the primary attributes of `attributes`. The table's PRIMARY KEY
    /// cannot catch this: items added without kSecAttrAccessGroup store NULL in agrp, and SQLite treats
    /// NULLs in a primary key as distinct.
    func hasDuplicate(of attributes: NSDictionary) -> Bool {
        let probe = NSMutableDictionary(dictionary: attributes)
        probe[kSecMatchLimit as String] = kSecMatchLimitAll as String
        guard let matches = query(probe), !matches.isEmpty else {
            return false
        }

        let tableName = attributes[kSecClass] as? String
        if tableName == kSecClassGenericPassword as String || tableName == kSecClassInternetPassword as String {
            return true
        }
        // Apple derives part of the primary key of keys, certificates and identities from the item
        // itself, which PlayChain does not store, so those only match when the data is the same too.
        guard let data = attributes[kSecValueData] as? Data else {
            return false
        }
        return matches.contains(where: { ($0[kSecValueData] as? Data) == data })
    }

    private func userVersion(_ sqlite3DB: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare(sqlite3DB, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return sqlite3_column_int(stmt, 0)
    }

    /// Version 1 databases can hold several rows per password item (see hasDuplicate(of:)). Keep the
    /// newest of each. Keys, certificates and identities are left alone: their stored primary columns
    /// are not unique.
    private func removeDuplicatePasswordItems(_ sqlite3DB: OpaquePointer) -> Bool {
        for tableName in [kSecClassGenericPassword, kSecClassInternetPassword] {
            let primaryKeys = PlayedAppleDBConstants.primaries[tableName]!.map({ "\($0)" }).joined(separator: ", ")
            let dedupeQuery = "DELETE FROM \(tableName) WHERE rowid NOT IN " +
                "(SELECT MAX(rowid) FROM \(tableName) GROUP BY \(primaryKeys))"
            guard sqlite3_exec(sqlite3DB, dedupeQuery, nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(dedupeQuery)")
                PlayKeychain.debugLogger("Failed to remove duplicate items from db table: \(errorMessage)")
                return false
            }
        }

        return true
    }
}
