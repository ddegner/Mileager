import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation
import SQLite3

enum SQLiteFetchIndexMaintenance {
    private struct IndexDefinition {
        var name: String
        var table: String
        var columns: String
    }

    private static let definitions: [IndexDefinition] = [
        .init(
            name: "Z_TripEntity_byID",
            table: "ZTRIPENTITY",
            columns: "ZID COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_TripEntity_byDateRange",
            table: "ZTRIPENTITY",
            columns: "ZSTARTDATE COLLATE BINARY DESC, ZENDDATE COLLATE BINARY DESC"
        ),
        .init(
            name: "Z_TripEntity_byArchiveAndStartDate",
            table: "ZTRIPENTITY",
            columns: "ZISARCHIVED COLLATE BINARY ASC, ZSTARTDATE COLLATE BINARY DESC"
        ),
        .init(
            name: "Z_RawSampleEntity_byTripID",
            table: "ZRAWSAMPLEENTITY",
            columns: "ZTRIPID COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_RawSampleEntity_byExpiresAt",
            table: "ZRAWSAMPLEENTITY",
            columns: "ZEXPIRESAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DiagnosticSampleEntity_byTripID",
            table: "ZDIAGNOSTICSAMPLEENTITY",
            columns: "ZTRIPID COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DiagnosticSampleEntity_bySampleTimestamp",
            table: "ZDIAGNOSTICSAMPLEENTITY",
            columns: "ZSAMPLETIMESTAMP COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DiagnosticSampleEntity_byExpiresAt",
            table: "ZDIAGNOSTICSAMPLEENTITY",
            columns: "ZEXPIRESAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DriveCaptureEventEntity_byDate",
            table: "ZDRIVECAPTUREEVENTENTITY",
            columns: "ZDATE COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DriveCaptureEventEntity_byExpiresAt",
            table: "ZDRIVECAPTUREEVENTENTITY",
            columns: "ZEXPIRESAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DriveCaptureEventEntity_byWakeReason",
            table: "ZDRIVECAPTUREEVENTENTITY",
            columns: "ZWAKEREASON COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_DriveCaptureEventEntity_byCaptureID",
            table: "ZDRIVECAPTUREEVENTENTITY",
            columns: "ZCAPTUREID COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_PendingDriveStartSignalEntity_byStatusAndCreatedAt",
            table: "ZPENDINGDRIVESTARTSIGNALENTITY",
            columns: "ZSTATUSRAW COLLATE BINARY ASC, ZCREATEDAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_PendingDriveStartSignalEntity_byUpdatedAt",
            table: "ZPENDINGDRIVESTARTSIGNALENTITY",
            columns: "ZUPDATEDAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_BluetoothObservationEntity_byIdentifierHash",
            table: "ZBLUETOOTHOBSERVATIONENTITY",
            columns: "ZIDENTIFIERHASH COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_BluetoothObservationEntity_byObservedAt",
            table: "ZBLUETOOTHOBSERVATIONENTITY",
            columns: "ZOBSERVEDAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_BluetoothObservationEntity_byExpiresAt",
            table: "ZBLUETOOTHOBSERVATIONENTITY",
            columns: "ZEXPIRESAT COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_TripFeeEntity_byTripID",
            table: "ZTRIPFEEENTITY",
            columns: "ZTRIPID COLLATE BINARY ASC"
        ),
        .init(
            name: "Z_TripFeeEntity_bySourceTransactionID",
            table: "ZTRIPFEEENTITY",
            columns: "ZSOURCETRANSACTIONID COLLATE BINARY ASC"
        )
    ]

    static func installMissingIndexes(for coordinator: NSPersistentStoreCoordinator) throws {
        for store in coordinator.persistentStores where store.type == NSSQLiteStoreType {
            guard let url = store.url, url.isFileURL else { continue }
            try installMissingIndexes(at: url)
        }
    }

    static func installMissingIndexes(at storeURL: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map(errorMessage) ?? "Unable to open SQLite store."
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteFetchIndexMaintenanceError.openFailed(storeURL, message)
        }
        defer { sqlite3_close(database) }

        try execute("PRAGMA busy_timeout = 5000", database: database)
        let tables = try existingTables(in: database)
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            for definition in definitions where tables.contains(definition.table) {
                try execute(
                    "CREATE INDEX IF NOT EXISTS \(definition.name) ON \(definition.table) (\(definition.columns))",
                    database: database
                )
            }
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private static func existingTables(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteFetchIndexMaintenanceError.statementFailed(sql, errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var tables = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    tables.insert(String(cString: text))
                }
            case SQLITE_DONE:
                return tables
            default:
                throw SQLiteFetchIndexMaintenanceError.statementFailed(sql, errorMessage(database))
            }
        }
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &rawError) == SQLITE_OK else {
            let message = rawError.map { String(cString: $0) } ?? errorMessage(database)
            if let rawError {
                sqlite3_free(rawError)
            }
            throw SQLiteFetchIndexMaintenanceError.statementFailed(sql, message)
        }
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite error."
    }
}

private enum SQLiteFetchIndexMaintenanceError: Error, LocalizedError {
    case openFailed(URL, String)
    case statementFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let url, let message):
            "Failed to open SQLite store at \(url.path): \(message)"
        case .statementFailed(let sql, let message):
            "Failed to maintain SQLite fetch index with SQL '\(sql)': \(message)"
        }
    }
}
