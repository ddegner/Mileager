import CoreData
import XCTest
@testable import AppCore

final class DiagnosticSampleStoreTests: XCTestCase {
    func testSavesUnattachedDiagnosticSample() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sample = makeDiagnosticSample(tripID: nil)

        try store.save(sample)

        let fetched = try store.fetchSamples()
        XCTAssertEqual(fetched, [sample])
        XCTAssertNil(fetched.first?.tripID)
    }

    func testStaleRejectedSamplePersistsWithoutTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sample = makeDiagnosticSample(
            acceptedForDetection: false,
            detectionOutput: "rejected",
            detectionReason: "Ignored stale cached location"
        )

        try store.save(sample)

        let fetched = try XCTUnwrap(try store.fetchSamples().first)
        XCTAssertFalse(fetched.acceptedForDetection)
        XCTAssertEqual(fetched.detectionOutput, "rejected")
        XCTAssertEqual(fetched.detectionReason, "Ignored stale cached location")
        XCTAssertNil(fetched.tripID)
    }

    func testIgnoredNonDrivingSamplePersistsReason() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sample = makeDiagnosticSample(
            acceptedForDetection: true,
            detectionOutput: "ignored",
            detectionReason: "No driving signal"
        )

        try store.save(sample)

        let fetched = try XCTUnwrap(try store.fetchSamples().first)
        XCTAssertTrue(fetched.acceptedForDetection)
        XCTAssertEqual(fetched.detectionOutput, "ignored")
        XCTAssertEqual(fetched.detectionReason, "No driving signal")
    }

    func testCompletedTripTaggingKeepsCanonicalRawSamples() throws {
        let persistence = try PersistenceController(inMemory: true)
        let tripStore = TripStore(context: persistence.container.viewContext)
        let diagnosticStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocationSample(
            timestamp: start,
            latitude: 40,
            longitude: -73,
            horizontalAccuracy: 10,
            speedMetersPerSecond: 12,
            motionHint: .automotive
        )
        let second = LocationSample(
            timestamp: start.addingTimeInterval(60),
            latitude: 40.01,
            longitude: -73.01,
            horizontalAccuracy: 10,
            speedMetersPerSecond: 11,
            motionHint: .automotive
        )
        try diagnosticStore.save(makeDiagnosticSample(monitoringSessionID: sessionID, sample: first, detectionOutput: "tripStarted"))
        try diagnosticStore.save(makeDiagnosticSample(monitoringSessionID: sessionID, sample: second, detectionOutput: "tripEnded"))

        let trip = try tripStore.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: second.timestamp,
            samples: [first, second],
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: [first, second])
        ))
        let tagged = try diagnosticStore.tagSamples(
            monitoringSessionID: sessionID,
            tripID: trip.id,
            from: start,
            to: second.timestamp
        )

        XCTAssertEqual(tagged, 2)
        XCTAssertEqual(try tripStore.rawSampleCount(tripID: trip.id), 2)
        let samples = try diagnosticStore.fetchSamples()
        XCTAssertEqual(samples.filter { $0.tripID == trip.id }.count, 2)
        XCTAssertEqual(Set(samples.compactMap(\.tripID)), [trip.id])
    }

    func testCrossSessionTripTaggingCoversInterruptedBackgroundCapture() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSession = UUID()
        let secondSession = UUID()

        try diagnosticStore.save(makeDiagnosticSample(
            id: UUID(),
            monitoringSessionID: firstSession,
            sample: LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10)
        ))
        try diagnosticStore.save(makeDiagnosticSample(
            id: UUID(),
            monitoringSessionID: secondSession,
            sample: LocationSample(timestamp: start.addingTimeInterval(60), latitude: 40.01, longitude: -73, horizontalAccuracy: 10)
        ))

        let tagged = try diagnosticStore.tagSamples(
            tripID: tripID,
            from: start,
            to: start.addingTimeInterval(60)
        )

        XCTAssertEqual(tagged, 2)
        XCTAssertEqual(Set(try diagnosticStore.fetchSamples().compactMap(\.tripID)), [tripID])
    }

    func testPurgesExpiredDiagnosticSamples() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(makeDiagnosticSample(
            sample: LocationSample(timestamp: now.addingTimeInterval(-40), latitude: 40, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(-1)
        ))
        try store.save(makeDiagnosticSample(
            sample: LocationSample(timestamp: now, latitude: 40.001, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(60)
        ))

        let purged = try store.purgeExpiredSamples(now: now)

        XCTAssertEqual(purged, 1)
        XCTAssertEqual(try store.fetchSamples().count, 1)
    }

    func testStandardRetentionDeletesOldRowsAndClampsCurrentExpiry() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        try store.save(makeDiagnosticSample(
            id: UUID(),
            sample: LocationSample(timestamp: old, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        ))
        try store.save(makeDiagnosticSample(
            id: UUID(),
            sample: LocationSample(timestamp: now, latitude: 40.01, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        ))

        XCTAssertEqual(try store.applyRetentionPolicy(retentionDays: 1, now: now, preservingFrom: nil), 1)
        let retained = try XCTUnwrap(try store.fetchSamples().first)
        XCTAssertEqual(retained.expiresAt, now.addingTimeInterval(24 * 60 * 60))
    }

    func testStandardRetentionPreservesSamplesNeededByActiveCapture() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captureStart = now.addingTimeInterval(-26 * 60 * 60)
        try store.save(makeDiagnosticSample(
            id: UUID(),
            sample: LocationSample(timestamp: captureStart, latitude: 40, longitude: -73, horizontalAccuracy: 10)
        ))

        XCTAssertEqual(
            try store.applyRetentionPolicy(retentionDays: 1, now: now, preservingFrom: captureStart),
            0
        )
        let retained = try XCTUnwrap(try store.fetchSamples().first)
        XCTAssertGreaterThan(retained.expiresAt, now)
    }

    func testDetailedRetentionExtendsSamplesRecordedInStandardMode() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(makeDiagnosticSample(
            id: UUID(),
            sample: LocationSample(timestamp: now, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(24 * 60 * 60)
        ))

        _ = try store.applyRetentionPolicy(retentionDays: 30, now: now, preservingFrom: nil)

        XCTAssertEqual(
            try XCTUnwrap(store.fetchSamples().first).expiresAt,
            now.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }

    func testUnchangedRetentionPolicyDoesNotRefetchTheRetainedTable() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = DiagnosticSampleStore(context: context)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(makeDiagnosticSample(
            sample: LocationSample(timestamp: now, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(24 * 60 * 60)
        ))
        _ = try store.applyRetentionPolicy(retentionDays: 1, now: now, preservingFrom: nil)
        context.reset()
        context.retainsRegisteredObjects = true

        XCTAssertEqual(
            try store.applyRetentionPolicy(retentionDays: 1, now: now.addingTimeInterval(60), preservingFrom: nil),
            0
        )
        XCTAssertTrue(
            context.registeredObjects.isEmpty,
            "an unchanged policy should issue only the bounded expiry query, not materialize retained rows"
        )
    }

    func testUnchangedRetentionPolicyStillExtendsActiveCaptureSamples() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = DiagnosticSampleStore(context: persistence.container.viewContext)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captureStart = now.addingTimeInterval(-60)
        try store.save(makeDiagnosticSample(
            sample: LocationSample(timestamp: captureStart, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            expiresAt: now.addingTimeInterval(10)
        ))
        _ = try store.applyRetentionPolicy(retentionDays: 1, now: now, preservingFrom: nil)

        _ = try store.applyRetentionPolicy(
            retentionDays: 1,
            now: now.addingTimeInterval(3_600),
            preservingFrom: captureStart
        )

        XCTAssertEqual(
            try XCTUnwrap(store.fetchSamples().first).expiresAt,
            now.addingTimeInterval(3_600 + 24 * 60 * 60)
        )
    }

    func testDiagnosticsExportIncludesPersistedSamplesAfterStoreReopen() throws {
        let storeDirectory = try makeTemporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let diagnosticSample = makeDiagnosticSample(detectionOutput: "ignored", detectionReason: "No driving signal")

        do {
            let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
            let store = DiagnosticSampleStore(context: persistence.container.viewContext)
            try store.save(diagnosticSample)
        }

        let reopenedPersistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        let reopenedStore = DiagnosticSampleStore(context: reopenedPersistence.container.viewContext)
        let persistedSamples = try reopenedStore.fetchSamples()
        let diagnostics = DiagnosticsService()
        let exportData = try diagnostics.export(health: .unknown, diagnosticSamples: persistedSamples)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DiagnosticsExport.self, from: exportData)

        XCTAssertEqual(export.diagnosticSamples, [diagnosticSample])
    }

    private func makeDiagnosticSample(
        id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        monitoringSessionID: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        tripID: UUID? = nil,
        sample: LocationSample = LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            latitude: 40,
            longitude: -73,
            horizontalAccuracy: 10,
            speedMetersPerSecond: 12,
            speedAccuracyMetersPerSecond: 0.8,
            courseDegrees: 180,
            motionHint: .automotive,
            motionActivity: MotionActivitySnapshot(
                startDate: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-5),
                confidence: .medium,
                hints: [.automotive]
            )
        ),
        trackingPhase: String = "listening",
        powerConnected: Bool = false,
        recentPowerConnected: Bool = false,
        recentPowerDisconnected: Bool = false,
        trustedBluetoothVehicleHint: Bool = false,
        acceptedForDetection: Bool = true,
        detectionOutput: String? = nil,
        detectionReason: String? = nil,
        expiresAt: Date = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(30 * 24 * 60 * 60)
    ) -> DiagnosticLocationSample {
        DiagnosticLocationSample(
            id: id,
            monitoringSessionID: monitoringSessionID,
            tripID: tripID,
            receivedAt: sample.timestamp,
            sample: sample,
            trackingPhase: trackingPhase,
            powerConnected: powerConnected,
            recentPowerConnected: recentPowerConnected,
            recentPowerDisconnected: recentPowerDisconnected,
            trustedBluetoothVehicleHint: trustedBluetoothVehicleHint,
            acceptedForDetection: acceptedForDetection,
            detectionOutput: detectionOutput,
            detectionReason: detectionReason,
            expiresAt: expiresAt
        )
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileageTrackerDiagnosticStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
