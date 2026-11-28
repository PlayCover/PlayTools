// swiftlint:disable file_length
//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import Foundation
import Security
import SQLite3
import UIKit

enum PlayKeychainMutationOutcome {
    case succeeded(Int)
    case duplicate
    case invalidQuery
    case ioError

    var status: OSStatus {
        switch self {
        case .succeeded(let count): return count > 0 ? errSecSuccess : errSecItemNotFound
        case .duplicate: return errSecDuplicateItem
        case .invalidQuery: return errSecParam
        case .ioError: return errSecIO
        }
    }
}

class PlayKeychainDB: NSObject {
    public static let shared = PlayKeychainDB()

    private var dbLock: DispatchSemaphore = .init(value: 1)
    private let dbVersion = 2
    static let itemIDColumn = "pt_item_id"
    private var isSchemaVerified: Bool = false
    private var didEnsureDirectory: Bool = false
    private var persistentDB: OpaquePointer?
    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.closePersistentConnection()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        closePersistentConnection()
    }

    func query(_ attributes: NSDictionary, itemID: Data?, limit: Int) -> [NSMutableDictionary]? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return nil
        }

        let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] ?? []
        let queryColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        let (whereClause, whereBindings) = buildWhereClause(
            columns: queryColumns,
            attributes: attributes,
            itemID: itemID
        )
        // An unsupported search key may not turn into a class-wide lookup.
        if whereClause.isEmpty && !Self.canConstrain(attributes, with: [], lookup: true) { return [] }
        let predicate = whereClause.isEmpty ? "" : " WHERE \(whereClause)"
        let selectQuery = "SELECT * FROM \(tableName)\(predicate) LIMIT \(limit)"
        var stmt: OpaquePointer?

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            dictArr.removeAll()
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, selectQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(selectQuery)")
                PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in whereBindings.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to bind query parameter: \(errorMessage)")
                return false
            }

            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                let newDict: NSMutableDictionary = [:]
                let columns = sqlite3_column_count(stmt)
                newDict[kSecClass] = tableName
                newDict[kSecAttrSynchronizable] = attributes[kSecAttrSynchronizable]
                for index in 0..<columns {
                    let name = String(cString: sqlite3_column_name(stmt, index))
                    if let value = decodeData(stmt: stmt, index: index) {
                        newDict[name] = decodedAttribute(value, column: name, tableName: tableName)
                    }
                }
                dictArr.append(newDict)
                step = sqlite3_step(stmt)
            }

            return step == SQLITE_DONE
        }) else { return nil }

        return dictArr
    }

    // A batch is needed when both members of a generated key pair are permanent.
    func insert(_ items: [NSDictionary]) -> PlayKeychainMutationOutcome {
        var outcome: PlayKeychainMutationOutcome = .ioError
        let completed = usingDB { sqliteDB in
            guard sqlite3_exec(sqliteDB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                outcome = .ioError
                return false
            }
            var committed = false
            defer {
                if !committed { sqlite3_exec(sqliteDB, "ROLLBACK", nil, nil, nil) }
            }

            for item in items {
                outcome = insert(item, using: sqliteDB)
                switch outcome {
                case .succeeded: break
                case .ioError: return false
                case .duplicate, .invalidQuery: return true
                }
            }

            guard sqlite3_exec(sqliteDB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                outcome = .ioError
                return false
            }
            committed = true
            outcome = .succeeded(items.count)
            return true
        }
        return completed ? outcome : .ioError
    }

    private func insert(_ attributes: NSDictionary, using sqliteDB: OpaquePointer) -> PlayKeychainMutationOutcome {
        guard let tableName = attributes[kSecClass] as? String,
              let primary = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondary = PlayedAppleDBConstants.attributes[tableName as CFString],
              let itemID = attributes[Self.itemIDColumn] as? Data else { return .invalidQuery }

        let optional = secondary + PlayedAppleDBConstants.values
        let columns = primary.map { $0 as String }
            + optional.filter { attributes[$0] != nil }.map { $0 as String }
            + [Self.itemIDColumn]
        let values = columns.map { attributes[$0].map { $0 as CFTypeRef } ?? NSNull() }
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")

        // A composite SQLite primary key treats NULLs as distinct. The explicit check preserves
        // Keychain duplicate semantics for omitted attributes and rows written by older versions.
        let primaryValues = primary.map { attributes[$0].map { $0 as CFTypeRef } ?? NSNull() }
        let predicates = primary.map { column -> String in
            let name = column as String
            let allowLegacyNull = column == kSecAttrAccessGroup
                ? (attributes[column] as? String) == PlayKeychain.defaultAccessGroup
                : attributes[column] == nil
            return allowLegacyNull ? "(\(name) IS ? OR \(name) IS NULL)" : "\(name) IS ?"
        }.joined(separator: " AND ")
        let sql = """
            INSERT INTO \(tableName) (\(columns.joined(separator: ", ")))
            SELECT \(placeholders) WHERE NOT EXISTS (SELECT 1 FROM \(tableName) WHERE \(predicates))
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard !itemID.isEmpty, sqlite3_prepare_v2(sqliteDB, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return .ioError }
        for (index, value) in (values + primaryValues).enumerated() {
            guard encodeData(stmt: statement, index: Int32(index + 1), value: value) else { return .ioError }
        }

        let step = sqlite3_step(statement)
        if step == SQLITE_CONSTRAINT || (step == SQLITE_DONE && sqlite3_changes(sqliteDB) == 0) {
            return .duplicate
        }
        return step == SQLITE_DONE ? .succeeded(1) : .ioError
    }

    /// Applies a partial update: `query` only builds the WHERE clause, and
    /// `attributesToUpdate` only builds the SET clause. Returns the affected row count so the
    /// caller can report `errSecItemNotFound` instead of a false success.
    func update(query: NSDictionary, attributesToUpdate: NSDictionary, itemID: Data?)
    -> PlayKeychainMutationOutcome {
        guard let tableName = query[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return .invalidQuery
        }

        let allColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        guard Self.canConstrain(query, with: allColumns) else { return .invalidQuery }
        var setClauses: [String] = []
        var setValues: [CFTypeRef] = []
        for column in allColumns where column != kSecValuePersistentRef {
            guard let value = attributesToUpdate[column] else { continue }
            setClauses.append("\(column) = ?")
            setValues.append(value as CFTypeRef)
        }
        guard !setClauses.isEmpty else { return .invalidQuery }

        let (whereClause, whereBindings) = buildWhereClause(columns: allColumns, attributes: query, itemID: itemID)
        guard !whereClause.isEmpty else { return .invalidQuery }
        let updateQuery = "UPDATE \(tableName) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClause)"
        return executeUpdate(query: updateQuery, setValues: setValues, whereBindings: whereBindings)
    }

    private func executeUpdate(
        query updateQuery: String,
        setValues: [CFTypeRef],
        whereBindings: [CFTypeRef]
    ) -> PlayKeychainMutationOutcome {
        var stmt: OpaquePointer?
        var outcome: PlayKeychainMutationOutcome = .ioError
        let completed = usingDB { sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, updateQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(updateQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }
            for (index, value) in (setValues + whereBindings).enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to bind update parameter")
                return false
            }
            let step = sqlite3_step(stmt)
            switch step {
            case SQLITE_CONSTRAINT: outcome = .duplicate
            case SQLITE_DONE: outcome = .succeeded(Int(sqlite3_changes(sqlite3DB)))
            default: return false
            }
            return true
        }
        return completed ? outcome : .ioError
    }
}

private extension PlayKeychainDB {
    /// Options that only describe *how* to talk to the keychain and carry no matching
    /// semantics. Apple ignores them for delete, so they must not turn a valid call into
    /// `errSecParam` (many third-party wrappers always pass them).
    private static let benignMutationKeys: Set<String> = [
        kSecUseDataProtectionKeychain as String,
        kSecUseAuthenticationUI as String,
        kSecUseAuthenticationContext as String,
        kSecUseOperationPrompt as String
    ]

    /// `kSecAttrSynchronizable` is benign only when it does not narrow the result:
    /// `kSecAttrSynchronizableAny` or `false`. `true` would restrict the delete to synced
    /// items, which this backend cannot honour, so it stays unsupported.
    private static func isBenignSynchronizable(_ value: Any?) -> Bool {
        if let string = value as? String, string == kSecAttrSynchronizableAny as String {
            return true
        }
        if let number = value as? NSNumber, number.boolValue == false {
            return true
        }
        if let bool = value as? Bool, bool == false {
            return true
        }
        return false
    }

    /// Reject a query with qualifiers this backend cannot evaluate before running a mutation.
    /// In particular, a class-only query may match every row, but an unsupported targeted query must not.
    private static let lookupOptions = Set([
        kSecMatchLimit, kSecReturnAttributes, kSecReturnData, kSecReturnRef, kSecReturnPersistentRef
    ].map { $0 as String })

    private static func canConstrain(_ attributes: NSDictionary, with columns: [CFString],
                                     lookup: Bool = false) -> Bool {
        let supported = Set(columns.map { $0 as String }).union([kSecClass as String])
        return attributes.allKeys.allSatisfy { key in
            guard let name = key as? String else { return false }
            if supported.contains(name) || benignMutationKeys.contains(name) ||
                (lookup && lookupOptions.contains(name)) { return true }
            return name == kSecAttrSynchronizable as String && isBenignSynchronizable(attributes[key])
        }
    }

    internal func delete(_ attributes: NSDictionary, itemID: Data?) -> PlayKeychainMutationOutcome {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return .invalidQuery
        }

        let allColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        guard Self.canConstrain(attributes, with: allColumns) else { return .invalidQuery }
        let (whereClause, whereBindings) = buildWhereClause(columns: allColumns, attributes: attributes, itemID: itemID)
        // `tableName` comes from the constants whitelist above, so it is safe to interpolate.
        let deleteQuery = whereClause.isEmpty
            ? "DELETE FROM \(tableName)"
            : "DELETE FROM \(tableName) WHERE \(whereClause)"

        var stmt: OpaquePointer?
        var changes = 0
        var succeeded = false

        let executed = usingDB { sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, deleteQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                PlayKeychain.debugLogger("Failed to delete items from db table: "
                                         + "\(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in whereBindings.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to bind delete parameter")
                return false
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            changes = Int(sqlite3_changes(sqlite3DB))
            succeeded = true
            return true
        }

        guard executed, succeeded else { return .ioError }
        return .succeeded(changes)
    }

    private func structDB(_ sqlite3DB: OpaquePointer) -> Bool {
        for (key, value) in PlayedAppleDBConstants.primaries {
            var columns: [CFString] = value
            columns.append(contentsOf: PlayedAppleDBConstants.attributes[key] ?? [])
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

        return true
    }

    private func usingDB(_ callback: (OpaquePointer) -> Bool) -> Bool {
        dbLock.wait()
        defer { dbLock.signal() }

        guard let sqlite3DB = openOrReuseDB() else { return false }
        let result = callback(sqlite3DB)
        if !result && shouldReconnect(afterErrorOn: sqlite3DB) {
            resetConnectionLocked()
            guard let retryDB = openOrReuseDB() else { return false }
            return callback(retryDB)
        }
        return result
    }

    private func shouldReconnect(afterErrorOn sqlite3DB: OpaquePointer) -> Bool {
        let code = sqlite3_errcode(sqlite3DB)
        switch code {
        case SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN,
             SQLITE_READONLY, SQLITE_NOMEM, SQLITE_PROTOCOL, SQLITE_BUSY, SQLITE_LOCKED:
            return true
        default:
            return false
        }
    }

    private func closePersistentConnection() {
        dbLock.wait()
        resetConnectionLocked()
        dbLock.signal()
    }

    internal func releaseIdleResources() {
        dbLock.wait()
        if let sqliteDB = persistentDB {
            sqlite3_exec(sqliteDB, "PRAGMA wal_checkpoint(PASSIVE);", nil, nil, nil)
            sqlite3_db_release_memory(sqliteDB)
            resetConnectionLocked()
        }
        dbLock.signal()
    }

    func resetConnectionLocked() {
        if let sqliteDB = persistentDB {
            _ = sqlite3_close_v2(sqliteDB)
            persistentDB = nil
        }
        isSchemaVerified = false
    }

    private func openOrReuseDB() -> OpaquePointer? {
        if let existing = persistentDB, isSchemaVerified {
            return existing
        }

        var sqlite3DB: OpaquePointer?
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "Shared"
        let playChainDir = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("PlayChain")
        if !didEnsureDirectory {
            do {
                try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
                didEnsureDirectory = true
            } catch {
                PlayKeychain.debugLogger("Failed to create PlayChain directory: \(error)")
            }
        }
        let keychainDB = playChainDir.appendingPathComponent("\(bundleID).db")

        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: keychainDB.path)
        let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        let needsSchemaInit = fileSize == 0 || !isSchemaVerified

        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(keychainDB.path, &sqlite3DB, openFlags, nil) == SQLITE_OK,
              let sqlite3DB = sqlite3DB else {
            if let sqliteDB = sqlite3DB {
                _ = sqlite3_close_v2(sqliteDB)
            }
            PlayKeychain.debugLogger("Failed to connect to DB")
            return nil
        }

        sqlite3_busy_timeout(sqlite3DB, 2000)
        sqlite3_exec(sqlite3DB, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)

        // Check PRAGMA user_version once per process (or on 0-byte files) so we do not
        // fsync CREATE TABLE on every hot query while still initializing empty/0-byte DBs.
        if needsSchemaInit {
            guard verifySchemaIfNeeded(sqlite3DB, fileSize: fileSize) else {
                _ = sqlite3_close_v2(sqlite3DB)
                return nil
            }
            isSchemaVerified = true
        }

        persistentDB = sqlite3DB
        return sqlite3DB
    }
}

private extension PlayKeychainDB {
    /// Builds a parameterized SQL WHERE clause and ordered binding values from primary key attributes.
    func buildWhereClause(
        columns: [CFString],
        attributes: NSDictionary,
        itemID: Data?
    ) -> (clause: String, bindings: [CFTypeRef]) {
        var clauses: [String] = []
        var bindings: [CFTypeRef] = []

        for col in columns {
            guard let attr = attributes[col] else { continue }
            let ref = attr as CFTypeRef
            let typeID = CFGetTypeID(ref)
            if typeID == CFDataGetTypeID() {
                clauses.append("(\(col) = ? OR CAST(\(col) AS BLOB) = ?)")
            } else {
                let legacyDefaultGroup = col == kSecAttrAccessGroup &&
                    (attr as? String) == PlayKeychain.defaultAccessGroup
                let legacyMatch = legacyDefaultGroup ? " OR \(col) IS NULL" : ""
                clauses.append("(\(col) = ? OR CAST(\(col) AS TEXT) = ?\(legacyMatch))")
            }
            bindings.append(ref)
            bindings.append(ref)
        }

        if let itemID {
            clauses.append("\(Self.itemIDColumn) = ?")
            bindings.append(itemID as CFData)
        }
        return (clauses.joined(separator: " AND "), bindings)
    }

    func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let string = value as! String // swiftlint:disable:this force_cast
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            let data = value as! CFData // swiftlint:disable:this force_cast
            let size = CFDataGetLength(data)
            if size == 0 {
                // `CFDataGetBytePtr` is NULL for empty data; binding that as a blob stores
                // SQLITE_NULL, which is indistinguishable from "no value" on read.
                result = sqlite3_bind_zeroblob(stmt, index, 0)
            } else {
                let ptr = CFDataGetBytePtr(data)
                result = sqlite3_bind_blob(stmt, index, ptr, Int32(size), sqliteTransient)
            }
        case CFNumberGetTypeID(), CFBooleanGetTypeID():
            guard let number = value as? NSNumber else { return false }
            // Existing columns use TEXT affinity. Keep numeric attributes comparable to rows
            // written as strings without losing them to the old unsupported-type NULL fallback.
            result = sqlite3_bind_text(stmt, index, number.stringValue, -1, sqliteTransient)
        case CFNullGetTypeID():
            result = sqlite3_bind_null(stmt, index)
        default:
            PlayKeychain.debugLogger("Cannot encode this data type: \(CFGetTypeID(value))")
            result = sqlite3_bind_null(stmt, index)
        }

        return result == SQLITE_OK
    }

    func decodeData(stmt: OpaquePointer, index: Int32) -> CFTypeRef? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            let byteCount = sqlite3_column_bytes(stmt, index)
            if byteCount == 0 {
                return "" as CFString
            }
            return CFStringCreateWithBytes(
                nil,
                ptr,
                CFIndex(byteCount),
                CFStringBuiltInEncodings.UTF8.rawValue,
                false
            ) ?? CFStringCreateWithBytes(
                nil,
                ptr,
                CFIndex(byteCount),
                CFStringBuiltInEncodings.isoLatin1.rawValue,
                false
            )
        case SQLITE_BLOB:
            // A legal zero-length BLOB reports a NULL pointer, so the size decides emptiness.
            let size = sqlite3_column_bytes(stmt, index)
            if size == 0 { return Data() as CFData }
            guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
            return CFDataCreate(nil, ptr, CFIndex(size))
        case SQLITE_NULL:
            return nil
        default:
            PlayKeychain.debugLogger("Cannot decode this data \(sqlite3_column_type(stmt, index))")
            return nil
        }
    }

    func decodedAttribute(_ value: CFTypeRef, column: String, tableName: String) -> CFTypeRef {
        guard tableName == kSecClassKey as String, let string = value as? String,
              let number = Int(string) else { return value }
        if PlayedAppleDBConstants.keyNumericAttributes.contains(column) { return NSNumber(value: number) }
        if PlayedAppleDBConstants.keyBooleanAttributes.contains(column) { return NSNumber(value: number != 0) }
        return value
    }

    func verifySchemaIfNeeded(_ sqlite3DB: OpaquePointer, fileSize: Int64) -> Bool {
        guard let currentVersion = readVersion(sqlite3DB) else { return false }
        if currentVersion >= dbVersion && fileSize != 0 { return true }

        // Serialize initial schema creation and additive migration across processes.
        guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil) }
        }
        guard let version = readVersion(sqlite3DB) else { return false }
        if version < dbVersion {
            guard structDB(sqlite3DB), migrateItemIDs(sqlite3DB),
                  sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion)", nil, nil, nil) == SQLITE_OK else {
                return false
            }
        }
        committed = sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed
    }

    func readVersion(_ sqliteDB: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(sqliteDB, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement, sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    func migrateItemIDs(_ sqliteDB: OpaquePointer) -> Bool {
        let column = Self.itemIDColumn
        for key in PlayedAppleDBConstants.primaries.keys {
            // The trigger also assigns an ID if an older PlayTools build subsequently adds a row.
            let migration = """
                ALTER TABLE \(key) ADD COLUMN \(column) BLOB;
                UPDATE \(key) SET \(column) = randomblob(16);
                CREATE UNIQUE INDEX \(key)_item_id ON \(key) (\(column));
                CREATE TRIGGER \(key)_assign_item_id AFTER INSERT ON \(key) WHEN NEW.\(column) IS NULL
                BEGIN
                    UPDATE \(key) SET \(column) = randomblob(16) WHERE rowid = NEW.rowid;
                END;
                """
            guard sqlite3_exec(sqliteDB, migration, nil, nil, nil) == SQLITE_OK else { return false }
        }
        return true
    }
}

extension PlayKeychain {
    static var defaultAccessGroup: String {
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "com.playcover.app"
        return "PLAYCOVER.\(bundleID)"
    }

    static func normalizedAccessGroupDict(_ attributes: NSDictionary) -> NSDictionary {
        guard let tableName = attributes[kSecClass] as? String,
              let primaries = PlayedAppleDBConstants.primaries[tableName as CFString],
              primaries.contains(kSecAttrAccessGroup),
              attributes[kSecAttrAccessGroup] == nil else {
            return attributes
        }
        let mutable = NSMutableDictionary(dictionary: attributes)
        mutable[kSecAttrAccessGroup] = defaultAccessGroup
        return mutable
    }

    static func ensureAccessGroupIfApplicable(_ dict: NSMutableDictionary) {
        let tableName = dict[kSecClass] as? String
        if let tableName,
           let primaries = PlayedAppleDBConstants.primaries[tableName as CFString],
           !primaries.contains(kSecAttrAccessGroup) {
            return
        }
        if dict[kSecAttrAccessGroup] == nil {
            dict[kSecAttrAccessGroup] = defaultAccessGroup
        }
    }
}
