import Foundation
import SQLite3
import XCTest
@testable import AppCore
@testable import DriveCaptureEngine

/// Replays the field diagnostics pulled off real devices (`data/iphone-*/`)
/// through the current capture logic. Gated on `MILEAGE_REPLAY_DATA_ROOT`
/// because the pulls are multi-gigabyte reference data that never ships with
/// the repo checkout on CI.
///
///     MILEAGE_REPLAY_DATA_ROOT=$PWD/data swift test \
///         --package-path AppCorePackage --filter HistoricCaptureReplayTests
///
/// Two questions, both aimed at the 2.2 capture changes:
/// 1. Would the new confined-post-parking discard rule have thrown away any
///    trip a real device actually recorded? (Replayed chronologically so each
///    completion sees the same prior-trip context the device had.)
/// 2. What does strict possible-drive recovery materialize from the real
///    diagnostic streams, and does the overlap backstop correctly separate
///    adjacent-burst duplicates from genuinely missed drives?
final class HistoricCaptureReplayTests: XCTestCase {
    private static let coreDataEpochOffset: TimeInterval = 978_307_200

    func testReplayHistoricPullsThroughCurrentCaptureLogic() throws {
        guard let root = ProcessInfo.processInfo.environment["MILEAGE_REPLAY_DATA_ROOT"] else {
            throw XCTSkip("Set MILEAGE_REPLAY_DATA_ROOT to the data/ directory of device pulls")
        }
        let stores = try discoverStores(root: root)
        guard !stores.isEmpty else {
            return XCTFail("No readable device pulls under \(root)")
        }

        var mergedTrips: [UUID: HistoricTrip] = [:]
        var mergedSamples: [UUID: [LocationSample]] = [:]
        var diagnosticWindows: [(pull: String, samples: [DiagnosticLocationSample])] = []
        var skipped: [String] = []

        for store in stores {
            do {
                let trips = try readTrips(cloudStorePath: store.cloudPath)
                for trip in trips { mergedTrips[trip.id] = trip }
                let rawSamples = try readRawSamples(rawStorePath: store.rawPath)
                for (tripID, samples) in rawSamples where (mergedSamples[tripID]?.count ?? 0) < samples.count {
                    mergedSamples[tripID] = samples
                }
                let diagnostics = try readDiagnosticSamples(rawStorePath: store.rawPath)
                if !diagnostics.isEmpty {
                    diagnosticWindows.append((pull: store.label, samples: diagnostics))
                }
            } catch {
                skipped.append("\(store.label): \(error.localizedDescription)")
            }
        }
        if !skipped.isEmpty {
            print("REPLAY skipped pulls (schema drift or unreadable):")
            skipped.forEach { print("  - \($0)") }
        }

        try replayCompletionClassifier(trips: mergedTrips, samplesByTrip: mergedSamples)
        replayRecovery(diagnosticWindows: diagnosticWindows, trips: Array(mergedTrips.values))
    }

    // MARK: - Analysis 1: confined-post-parking classifier vs real saved trips

    private func replayCompletionClassifier(
        trips: [UUID: HistoricTrip],
        samplesByTrip: [UUID: [LocationSample]]
    ) throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        let coordinator = DriveCompletionCoordinator(
            tripStore: tripStore,
            activeDriveStore: ActiveDriveStore(context: context)
        )

        let ordered = trips.values.sorted { $0.startDate < $1.startDate }
        var replayedAutomatic = 0
        var withSamples = 0
        var nowDiscarded: [(HistoricTrip, String)] = []

        for trip in ordered {
            let samples = samplesByTrip[trip.id] ?? []
            let isAutomatic = trip.captureSource != "manual"
            guard isAutomatic, !samples.isEmpty else {
                // Keep the timeline faithful for later prior-trip context even
                // when we cannot re-run the classifier for this row.
                try? tripStore.saveCompletedTrip(trip.draft(samples: samples))
                continue
            }
            replayedAutomatic += 1
            withSamples += 1
            // classification nil: we want the raw classifier verdict, not the
            // in-flight user-decision shield.
            let draft = trip.draft(samples: samples, classification: nil)
            let outcome = try coordinator.complete(draft, monitoringSessionID: nil)
            switch outcome {
            case .saved:
                // Restore the historic classification so the next completion
                // sees the same prior-trip context the device had.
                if let classification = trip.classification {
                    _ = try? tripStore.updateReview(
                        tripID: trip.id,
                        update: ReviewUpdate(classification: classification)
                    )
                }
            case let .discardedAutomaticCapture(source, reason):
                nowDiscarded.append((trip, "\(source.rawValue): \(reason)"))
                // Re-insert so downstream prior-trip context stays faithful.
                try? tripStore.saveCompletedTrip(trip.draft(samples: samples))
            }
        }

        print("REPLAY classifier: \(ordered.count) historic trips, \(replayedAutomatic) automatic with samples replayed")
        if nowDiscarded.isEmpty {
            print("REPLAY classifier: no historic saved trip would be discarded by the current rule")
        }
        for (trip, reason) in nowDiscarded {
            print("REPLAY classifier DISCARD-DELTA: \(trip.debugLine) → \(reason)")
        }
        // The dangerous direction: a trip the user explicitly classified as
        // Business must never be machine-discardable at completion time.
        let lostBusiness = nowDiscarded.filter { $0.0.classification == .business }
        XCTAssertTrue(
            lostBusiness.isEmpty,
            "Current discard rule would have suppressed user-classified business trips: "
                + lostBusiness.map(\.0.debugLine).joined(separator: " | ")
        )
    }

    // MARK: - Analysis 2: strict recovery + overlap backstop on real streams

    private func replayRecovery(
        diagnosticWindows: [(pull: String, samples: [DiagnosticLocationSample])],
        trips: [HistoricTrip]
    ) {
        var totalDrafts = 0
        var suppressedByBackstop = 0
        var wouldMaterialize = 0

        for window in diagnosticWindows {
            let drafts = DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: window.samples)
            totalDrafts += drafts.count
            for recovery in drafts {
                let draft = recovery.draft
                let overlapping = trips.filter {
                    $0.id != draft.id && $0.startDate <= draft.endDate && $0.endDate >= draft.startDate
                }
                let minutes = Int(draft.endDate.timeIntervalSince(draft.startDate) / 60)
                let miles = DistanceConversion.value(meters: draft.distanceMeters, in: .miles)
                let line = "\(window.pull) \(Self.timestamp(draft.startDate)) — "
                    + String(format: "%.2f mi, %d min, %d samples", miles, minutes, draft.samples.count)
                if overlapping.isEmpty {
                    wouldMaterialize += 1
                    let adjacent = trips
                        .filter { abs($0.startDate.timeIntervalSince(draft.endDate)) < 30 * 60
                            || abs(draft.startDate.timeIntervalSince($0.endDate)) < 30 * 60 }
                    print("REPLAY recovery NEW TRIP: \(line)"
                        + (adjacent.isEmpty ? "" : " (adjacent to \(adjacent.map(\.debugLine).joined(separator: "; ")))"))
                } else {
                    suppressedByBackstop += 1
                    print("REPLAY recovery SUPPRESSED (overlap backstop): \(line) overlaps "
                        + overlapping.map(\.debugLine).joined(separator: "; "))
                }
            }
        }

        print("REPLAY recovery: \(totalDrafts) strict candidates across \(diagnosticWindows.count) windows — "
            + "\(suppressedByBackstop) suppressed by the overlap backstop, \(wouldMaterialize) would surface for review")
    }

    // MARK: - Store discovery

    private struct HistoricStorePair {
        var label: String
        var cloudPath: String
        var rawPath: String
    }

    private func discoverStores(root: String) throws -> [HistoricStorePair] {
        let fm = FileManager.default
        var result: [HistoricStorePair] = []
        for pull in (try? fm.contentsOfDirectory(atPath: root))?.sorted() ?? [] {
            let pullPath = "\(root)/\(pull)"
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: pullPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for device in (try? fm.contentsOfDirectory(atPath: pullPath)) ?? [] {
                let devicePath = "\(pullPath)/\(device)"
                // Prefer the analysis copy when the pull kept one.
                for candidate in ["\(devicePath)/analysis-copy", devicePath] {
                    let cloud = "\(candidate)/MileageTracker.sqlite"
                    let raw = "\(candidate)/MileageTrackerRaw.sqlite"
                    if fm.fileExists(atPath: cloud), fm.fileExists(atPath: raw) {
                        result.append(HistoricStorePair(label: "\(pull)/\(device)", cloudPath: cloud, rawPath: raw))
                        break
                    }
                }
            }
        }
        return result
    }

    // MARK: - SQLite readers

    private struct HistoricTrip {
        var id: UUID
        var startDate: Date
        var endDate: Date
        var distanceMeters: Double
        var captureSource: String
        var classification: TripClassification?

        var debugLine: String {
            let miles = DistanceConversion.value(meters: distanceMeters, in: .miles)
            return "trip \(id.uuidString.prefix(8)) \(HistoricCaptureReplayTests.timestamp(startDate)) "
                + String(format: "%.2f mi", miles)
                + " [\(classification?.rawValue ?? "unclassified")]"
        }

        func draft(samples: [LocationSample], classification: TripClassification? = nil) -> TripDraft {
            TripDraft(
                id: id,
                startDate: startDate,
                endDate: endDate,
                samples: samples,
                distanceMeters: distanceMeters,
                classification: classification ?? self.classification
            )
        }
    }

    private func readTrips(cloudStorePath: String) throws -> [HistoricTrip] {
        try withDatabase(cloudStorePath) { db in
            try requireColumns(db, table: "ZTRIPENTITY", columns: ["ZID", "ZSTARTDATE", "ZENDDATE", "ZDISTANCEMETERS", "ZCAPTURESOURCE"])
            var rows: [HistoricTrip] = []
            try query(
                db,
                "SELECT ZID, ZSTARTDATE, ZENDDATE, ZDISTANCEMETERS, ZCAPTURESOURCE, ZCLASSIFICATIONRAW FROM ZTRIPENTITY"
            ) { statement in
                guard let id = Self.uuid(statement, 0) else { return }
                rows.append(HistoricTrip(
                    id: id,
                    startDate: Self.date(statement, 1),
                    endDate: Self.date(statement, 2),
                    distanceMeters: sqlite3_column_double(statement, 3),
                    captureSource: Self.text(statement, 4) ?? "",
                    classification: (Self.text(statement, 5)).flatMap(TripClassification.init(rawValue:))
                ))
            }
            return rows
        }
    }

    private func readRawSamples(rawStorePath: String) throws -> [UUID: [LocationSample]] {
        try withDatabase(rawStorePath) { db in
            try requireColumns(db, table: "ZRAWSAMPLEENTITY", columns: ["ZTRIPID", "ZTIMESTAMP", "ZLATITUDE", "ZLONGITUDE"])
            var rows: [UUID: [LocationSample]] = [:]
            try query(
                db,
                """
                SELECT ZTRIPID, ZTIMESTAMP, ZLATITUDE, ZLONGITUDE, ZHORIZONTALACCURACY,
                       ZSPEEDMETERSPERSECOND, ZSPEEDACCURACYMETERSPERSECOND, ZCOURSEDEGREES, ZMOTIONHINTRAW
                FROM ZRAWSAMPLEENTITY WHERE ZTRIPID IS NOT NULL ORDER BY ZTIMESTAMP
                """
            ) { statement in
                guard let tripID = Self.uuid(statement, 0) else { return }
                rows[tripID, default: []].append(LocationSample(
                    timestamp: Self.date(statement, 1),
                    latitude: sqlite3_column_double(statement, 2),
                    longitude: sqlite3_column_double(statement, 3),
                    horizontalAccuracy: sqlite3_column_double(statement, 4),
                    speedMetersPerSecond: Self.optionalDouble(statement, 5),
                    speedAccuracyMetersPerSecond: Self.optionalDouble(statement, 6),
                    courseDegrees: Self.optionalDouble(statement, 7),
                    motionHint: (Self.text(statement, 8)).flatMap(MotionHint.init(rawValue:)) ?? .unknown
                ))
            }
            return rows
        }
    }

    private func readDiagnosticSamples(rawStorePath: String) throws -> [DiagnosticLocationSample] {
        try withDatabase(rawStorePath) { db in
            try requireColumns(db, table: "ZDIAGNOSTICSAMPLEENTITY", columns: ["ZID", "ZMONITORINGSESSIONID", "ZSAMPLETIMESTAMP"])
            var rows: [DiagnosticLocationSample] = []
            try query(
                db,
                """
                SELECT ZID, ZMONITORINGSESSIONID, ZTRIPID, ZRECEIVEDAT, ZSAMPLETIMESTAMP,
                       ZLATITUDE, ZLONGITUDE, ZHORIZONTALACCURACY, ZSPEEDMETERSPERSECOND,
                       ZSPEEDACCURACYMETERSPERSECOND, ZCOURSEDEGREES, ZMOTIONHINTRAW,
                       ZTRACKINGPHASERAW, ZPOWERCONNECTED, ZRECENTPOWERCONNECTED,
                       ZRECENTPOWERDISCONNECTED, ZTRUSTEDBLUETOOTHVEHICLEHINT,
                       ZACCEPTEDFORDETECTION, ZDETECTIONOUTPUTRAW, ZDETECTIONREASON
                FROM ZDIAGNOSTICSAMPLEENTITY ORDER BY ZSAMPLETIMESTAMP
                """
            ) { statement in
                guard let id = Self.uuid(statement, 0), let sessionID = Self.uuid(statement, 1) else { return }
                rows.append(DiagnosticLocationSample(
                    id: id,
                    monitoringSessionID: sessionID,
                    tripID: Self.uuid(statement, 2),
                    receivedAt: Self.date(statement, 3),
                    sample: LocationSample(
                        timestamp: Self.date(statement, 4),
                        latitude: sqlite3_column_double(statement, 5),
                        longitude: sqlite3_column_double(statement, 6),
                        horizontalAccuracy: sqlite3_column_double(statement, 7),
                        speedMetersPerSecond: Self.optionalDouble(statement, 8),
                        speedAccuracyMetersPerSecond: Self.optionalDouble(statement, 9),
                        courseDegrees: Self.optionalDouble(statement, 10),
                        motionHint: (Self.text(statement, 11)).flatMap(MotionHint.init(rawValue:)) ?? .unknown
                    ),
                    trackingPhase: Self.text(statement, 12) ?? "",
                    powerConnected: sqlite3_column_int(statement, 13) != 0,
                    recentPowerConnected: sqlite3_column_int(statement, 14) != 0,
                    recentPowerDisconnected: sqlite3_column_int(statement, 15) != 0,
                    trustedBluetoothVehicleHint: sqlite3_column_int(statement, 16) != 0,
                    acceptedForDetection: sqlite3_column_int(statement, 17) != 0,
                    detectionOutput: Self.text(statement, 18),
                    detectionReason: Self.text(statement, 19),
                    expiresAt: .distantFuture
                ))
            }
            return rows
        }
    }

    // MARK: - SQLite plumbing

    private enum ReplayError: LocalizedError {
        case cannotOpen(String)
        case missingColumns(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case let .cannotOpen(path): "cannot open \(path)"
            case let .missingColumns(table): "schema drift: missing columns on \(table)"
            case let .queryFailed(message): "query failed: \(message)"
            }
        }
    }

    private func withDatabase<T>(_ path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ReplayError.cannotOpen(path)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func requireColumns(_ db: OpaquePointer, table: String, columns: [String]) throws {
        var present = Set<String>()
        try query(db, "PRAGMA table_info(\(table))") { statement in
            if let name = Self.text(statement, 1) { present.insert(name) }
        }
        guard Set(columns).isSubset(of: present) else {
            throw ReplayError.missingColumns(table)
        }
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReplayError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private static func date(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }

    private static func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func uuid(_ statement: OpaquePointer, _ index: Int32) -> UUID? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, index) == 16,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let buffer = bytes.assumingMemoryBound(to: UInt8.self)
        return UUID(uuid: (
            buffer[0], buffer[1], buffer[2], buffer[3],
            buffer[4], buffer[5], buffer[6], buffer[7],
            buffer[8], buffer[9], buffer[10], buffer[11],
            buffer[12], buffer[13], buffer[14], buffer[15]
        ))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        return formatter.string(from: date)
    }
}
