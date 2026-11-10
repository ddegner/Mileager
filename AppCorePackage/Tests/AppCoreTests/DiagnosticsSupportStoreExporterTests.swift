import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class DiagnosticsSupportStoreExporterTests: XCTestCase {
    func testBundleFiltersDatedRowsAndIncludesGlobalContext() throws {
        let source = try PersistenceController(inMemory: true)
        let context = source.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inWindow = now.addingTimeInterval(-24 * 60 * 60)
        let old = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let includedTripID = UUID()
        let overlapTripID = UUID()
        let excludedTripID = UUID()

        let includedTrip = insertTrip(
            id: includedTripID,
            start: inWindow,
            end: inWindow.addingTimeInterval(1_800),
            in: context
        )
        includedTrip.startAddress = nil
        includedTrip.startAddressEnrichmentState = .pending
        insertTrip(id: overlapTripID, start: now.addingTimeInterval(-5 * 24 * 60 * 60), end: now.addingTimeInterval(-2 * 24 * 60 * 60), in: context)
        insertTrip(id: excludedTripID, start: old, end: old.addingTimeInterval(1_800), in: context)
        insertTripFee(tripID: includedTripID, occurredAt: old, in: context)
        insertTripFee(tripID: nil, occurredAt: inWindow, in: context)
        insertTripFee(tripID: excludedTripID, occurredAt: old, in: context)
        insertOdometer(date: inWindow, in: context)
        insertOdometer(date: old, in: context)
        insertRawSample(tripID: includedTripID, date: inWindow, in: context)
        insertRawSample(tripID: excludedTripID, date: old, in: context)
        insertEnrichmentAttempt(tripID: includedTripID, date: old, in: context)
        insertEnrichmentAttempt(tripID: excludedTripID, date: old, in: context)
        insertDiagnosticSample(date: inWindow, in: context)
        insertDiagnosticSample(date: old, in: context)
        insertCaptureEvent(date: inWindow, in: context)
        insertCaptureEvent(date: old, in: context)
        insertPendingSignal(date: inWindow, in: context)
        insertPendingSignal(date: old, in: context)
        insertBluetoothObservation(date: inWindow, in: context)
        insertBluetoothObservation(date: old, in: context)
        insertBluetoothHint(date: old, displayName: "Old Car", in: context)
        insertBluetoothHint(date: inWindow, displayName: "Current Car", in: context)
        insertBluetoothMetadata(in: context)
        insertPreference(in: context)
        insertVehicle(in: context)
        insertReportSnapshot(start: old, end: old.addingTimeInterval(86_400), in: context)
        insertActiveDrive(in: context)
        try context.save()

        let sourceCountsBefore = try counts(
            [
                "TripEntity",
                "TripFeeEntity",
                "OdometerCheckpointEntity",
                "RawSampleEntity",
                "TripEnrichmentAttemptEntity",
                "DiagnosticSampleEntity",
                "DriveCaptureEventEntity",
                "PendingDriveStartSignalEntity",
                "BluetoothObservationEntity",
                "BluetoothHintEntity",
                "BluetoothMetadataEntity",
                "PreferenceEntity",
                "VehicleEntity",
                "ReportSnapshotEntity",
                "ActiveDriveEntity"
            ],
            in: context
        )

        let bundle = try DiagnosticsSupportStoreExporter.makeBundle(
            from: source.container,
            selectedDays: 3,
            now: now,
            metadata: DiagnosticsSupportExportMetadata(
                appVersion: "1.0",
                buildNumber: "9",
                bundleIdentifier: "test.bundle",
                backgroundRefreshAvailable: true,
                lowPowerModeEnabled: false
            )
        )
        defer { try? FileManager.default.removeItem(at: bundle.directoryURL) }

        let exported = try PersistenceController(mode: .localOnly, storeDirectory: bundle.directoryURL)
        let exportedContext = exported.container.viewContext
        XCTAssertEqual(try count("TripEntity", in: exportedContext), 2)
        XCTAssertEqual(try count("TripFeeEntity", in: exportedContext), 2)
        XCTAssertEqual(try count("OdometerCheckpointEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("RawSampleEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("TripEnrichmentAttemptEntity", in: exportedContext), 1)
        let enrichmentAttempts = try exportedContext.fetch(TripEnrichmentAttemptEntity.fetchRequest())
        let enrichmentAttempt = try XCTUnwrap(enrichmentAttempts.first)
        XCTAssertEqual(enrichmentAttempt.component, .startAddress)
        XCTAssertEqual(enrichmentAttempt.failureCategory, .networkUnavailable)
        XCTAssertEqual(
            Set(enrichmentAttempt.entity.attributesByName.keys),
            [
                "id",
                "tripID",
                "componentRaw",
                "lastAttemptAt",
                "consecutiveFailures",
                "failureCategoryRaw"
            ],
            "Support exports must contain only sanitized attempt metadata, never raw error text."
        )
        XCTAssertEqual(try count("DiagnosticSampleEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("DriveCaptureEventEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("PendingDriveStartSignalEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("BluetoothObservationEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("BluetoothHintEntity", in: exportedContext), 2)
        XCTAssertEqual(try count("BluetoothMetadataEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("PreferenceEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("VehicleEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("ReportSnapshotEntity", in: exportedContext), 1)
        XCTAssertEqual(try count("ActiveDriveEntity", in: exportedContext), 1)

        XCTAssertEqual(bundle.rowCounts["TripEntity"], 2)
        XCTAssertEqual(bundle.rowCounts["TripEnrichmentAttemptEntity"], 1)
        XCTAssertEqual(bundle.rowCounts["ReportSnapshotEntity"], 1)
        XCTAssertEqual(bundle.rowCounts["VehicleEntity"], 1)
        let manifest = try JSONDecoder.iso8601.decode(TestManifest.self, from: bundle.manifestData)
        XCTAssertEqual(manifest.selectedDays, 3)
        XCTAssertEqual(manifest.rowCounts["BluetoothHintEntity"], 2)
        XCTAssertEqual(manifest.metadata.appVersion, "1.0")
        XCTAssertEqual(manifest.metadata.backgroundRefreshAvailable, true)
        XCTAssertEqual(manifest.metadata.lowPowerModeEnabled, false)
        XCTAssertEqual(try counts(Array(sourceCountsBefore.keys), in: context), sourceCountsBefore)
    }

    func testBundleExcludesStaleAndOrphanAttemptsWithoutMutatingSource() throws {
        let source = try PersistenceController(inMemory: true)
        let context = source.container.viewContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tripDate = now.addingTimeInterval(-3_600)
        let validTripID = UUID()
        let completedTripID = UUID()
        let orphanTripID = UUID()

        let validTrip = insertTrip(
            id: validTripID,
            start: tripDate,
            end: tripDate.addingTimeInterval(600),
            in: context
        )
        validTrip.startAddress = nil
        validTrip.startAddressEnrichmentState = .pending

        let completedTrip = insertTrip(
            id: completedTripID,
            start: tripDate.addingTimeInterval(900),
            end: tripDate.addingTimeInterval(1_500),
            in: context
        )
        completedTrip.startAddressEnrichmentState = .complete

        let validAttempt = insertEnrichmentAttempt(
            tripID: validTripID,
            date: now.addingTimeInterval(-60),
            in: context
        )
        validAttempt.failureCategoryRaw = "NSURLError -1009 https://private.example"
        insertEnrichmentAttempt(
            tripID: completedTripID,
            date: now.addingTimeInterval(-60),
            in: context
        )
        insertEnrichmentAttempt(
            tripID: orphanTripID,
            date: now.addingTimeInterval(-60),
            in: context
        )
        try context.save()

        XCTAssertEqual(
            Set(try TripStore(context: context).eligibleEnrichmentAttemptIDs()),
            [validAttempt.id]
        )
        let backgroundContext = source.container.newBackgroundContext()
        let backgroundEligibleIDs = try backgroundContext.performAndWait {
            try TripStore(context: backgroundContext).eligibleEnrichmentAttemptIDs()
        }
        XCTAssertEqual(Set(backgroundEligibleIDs), [validAttempt.id])

        let bundle = try DiagnosticsSupportStoreExporter.makeBundle(
            from: source.container,
            selectedDays: 1,
            now: now
        )
        defer { try? FileManager.default.removeItem(at: bundle.directoryURL) }

        let exported = try PersistenceController(
            mode: .localOnly,
            storeDirectory: bundle.directoryURL
        )
        let attempts = try exported.container.viewContext.fetch(
            TripEnrichmentAttemptEntity.fetchRequest()
        )
        let exportedAttempt = try XCTUnwrap(attempts.first)

        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(exportedAttempt.id, validAttempt.id)
        XCTAssertEqual(exportedAttempt.tripID, validTripID)
        XCTAssertEqual(exportedAttempt.component, .startAddress)
        XCTAssertEqual(exportedAttempt.failureCategory, .unknown)
        XCTAssertEqual(
            exportedAttempt.failureCategoryRaw,
            TripEnrichmentFailureCategory.unknown.rawValue
        )
        XCTAssertEqual(bundle.rowCounts["TripEnrichmentAttemptEntity"], 1)
        XCTAssertEqual(
            try context.count(for: TripEnrichmentAttemptEntity.fetchRequest()),
            3,
            "Support export filtering must not mutate the live local store."
        )
        XCTAssertEqual(
            validAttempt.failureCategoryRaw,
            "NSURLError -1009 https://private.example"
        )
    }

    func testInvalidDayCountThrows() throws {
        let source = try PersistenceController(inMemory: true)

        XCTAssertThrowsError(try DiagnosticsSupportStoreExporter.makeBundle(from: source.container, selectedDays: 2)) { error in
            XCTAssertEqual(error.localizedDescription, "Diagnostics reports can include only 1, 3, 7, or 30 days. 2 days is not supported.")
        }
    }

    @discardableResult
    private func insertTrip(
        id: UUID,
        start: Date,
        end: Date,
        in context: NSManagedObjectContext
    ) -> TripEntity {
        let trip = TripEntity.insert(into: context)
        trip.id = id
        trip.createdAt = start
        trip.updatedAt = start
        trip.captureSource = "automatic"
        trip.startDate = start
        trip.endDate = end
        trip.startCoordinate = Coordinate(latitude: 42, longitude: -71)
        trip.endCoordinate = Coordinate(latitude: 42.1, longitude: -71.1)
        trip.startAddress = "Start"
        trip.endAddress = "End"
        trip.distanceMeters = 1_000
        trip.durationSeconds = end.timeIntervalSince(start)
        trip.reviewStatusRaw = ReviewStatus.needsReview.rawValue
        trip.tollsAmount = 0
        trip.parkingAmount = 0
        trip.needsAttention = false
        return trip
    }

    private func insertTripFee(tripID: UUID?, occurredAt: Date, in context: NSManagedObjectContext) {
        let fee = TripFeeEntity.insert(into: context)
        fee.id = UUID()
        fee.tripID = tripID
        fee.categoryRaw = TripFeeCategory.toll.rawValue
        fee.amount = 2.50
        fee.occurredAt = occurredAt
        fee.sourceRaw = TripFeeSource.manual.rawValue
    }

    private func insertVehicle(in context: NSManagedObjectContext) {
        let vehicle = VehicleEntity.insert(into: context)
        vehicle.id = UUID()
        vehicle.name = "Work Van"
        vehicle.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        vehicle.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        vehicle.sortOrder = 0
        vehicle.isArchived = false
    }

    private func insertOdometer(date: Date, in context: NSManagedObjectContext) {
        let checkpoint = OdometerCheckpointEntity.insert(into: context)
        checkpoint.id = UUID()
        checkpoint.date = date
        checkpoint.odometerMiles = 12_345
        checkpoint.createdAt = date
    }

    private func insertRawSample(tripID: UUID, date: Date, in context: NSManagedObjectContext) {
        let sample = RawSampleEntity.insert(into: context)
        sample.id = UUID()
        sample.tripID = tripID
        sample.timestamp = date
        sample.latitude = 42
        sample.longitude = -71
        sample.horizontalAccuracy = 8
        sample.motionHintRaw = MotionHint.automotive.rawValue
        sample.expiresAt = date.addingTimeInterval(30 * 24 * 60 * 60)
    }

    @discardableResult
    private func insertEnrichmentAttempt(
        tripID: UUID,
        date: Date,
        in context: NSManagedObjectContext
    ) -> TripEnrichmentAttemptEntity {
        let attempt = TripEnrichmentAttemptEntity.insert(into: context)
        attempt.id = UUID()
        attempt.tripID = tripID
        attempt.component = .startAddress
        attempt.lastAttemptAt = date
        attempt.consecutiveFailures = 1
        attempt.failureCategory = .networkUnavailable
        return attempt
    }

    private func insertDiagnosticSample(date: Date, in context: NSManagedObjectContext) {
        let sample = DiagnosticSampleEntity.insert(into: context)
        sample.id = UUID()
        sample.monitoringSessionID = UUID()
        sample.receivedAt = date
        sample.sampleTimestamp = date
        sample.latitude = 42
        sample.longitude = -71
        sample.horizontalAccuracy = 8
        sample.motionHintRaw = MotionHint.automotive.rawValue
        sample.trackingPhaseRaw = "recording"
        sample.powerConnected = false
        sample.recentPowerConnected = false
        sample.recentPowerDisconnected = false
        sample.trustedBluetoothVehicleHint = true
        sample.acceptedForDetection = true
        sample.expiresAt = date.addingTimeInterval(30 * 24 * 60 * 60)
    }

    private func insertCaptureEvent(date: Date, in context: NSManagedObjectContext) {
        let event = DriveCaptureEventEntity.insert(into: context)
        event.id = UUID()
        event.date = date
        event.category = "tracking"
        event.message = "Location update"
        event.powerConnected = false
        event.recentPowerConnected = false
        event.recentPowerDisconnected = false
        event.trustedBluetoothVehicleHint = false
        event.expiresAt = date.addingTimeInterval(30 * 24 * 60 * 60)
    }

    private func insertPendingSignal(date: Date, in context: NSManagedObjectContext) {
        let signal = PendingDriveStartSignalEntity.insert(into: context)
        signal.id = UUID()
        signal.triggerRaw = DriveStartExternalTrigger.vehicleBluetooth.rawValue
        signal.sourceRaw = DriveStartSignalSource.externalVehicleAutomation.rawValue
        signal.confidenceRaw = DriveStartSignalConfidence.assist.rawValue
        signal.createdAt = date
        signal.expiresAt = date.addingTimeInterval(180)
        signal.statusRaw = PendingDriveStartSignalStatus.pending.rawValue
        signal.updatedAt = date
    }

    private func insertBluetoothObservation(date: Date, in context: NSManagedObjectContext) {
        let observation = BluetoothObservationEntity.insert(into: context)
        observation.id = UUID()
        observation.identifierHash = UUID().uuidString
        observation.displayName = "Car Audio"
        observation.sourceRaw = BluetoothSignalSource.audioRoute.rawValue
        observation.observedAt = date
        observation.expiresAt = date.addingTimeInterval(7 * 24 * 60 * 60)
    }

    private func insertBluetoothHint(date: Date, displayName: String, in context: NSManagedObjectContext) {
        let hint = BluetoothHintEntity.insert(into: context)
        hint.id = UUID()
        hint.identifierHash = UUID().uuidString
        hint.displayName = displayName
        hint.sourceRaw = BluetoothSignalSource.audioRoute.rawValue
        hint.firstSeenAt = date
        hint.lastSeenAt = date
        hint.correlationCount = 1
        hint.notADriveCount = 0
        hint.trusted = true
    }

    private func insertBluetoothMetadata(in context: NSManagedObjectContext) {
        let metadata = BluetoothMetadataEntity.insert(into: context)
        metadata.key = "salt"
        metadata.value = "test-salt"
    }

    private func insertPreference(in context: NSManagedObjectContext) {
        let preference = PreferenceEntity.insert(into: context)
        preference.id = UUID()
        preference.key = "AutomaticTrackingEnabled"
        preference.valueData = Data("true".utf8)
        preference.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func insertReportSnapshot(start: Date, end: Date, in context: NSManagedObjectContext) {
        let snapshot = ReportSnapshotEntity.insert(into: context)
        snapshot.id = UUID()
        snapshot.createdAt = start
        snapshot.startDate = start
        snapshot.endDate = end
        snapshot.title = "Old Report"
        snapshot.csvText = "date,miles"
        snapshot.pdfData = Data("pdf".utf8)
        snapshot.businessMiles = 1
        snapshot.businessValue = 0.67
        snapshot.rateCentsPerMile = 67
    }

    private func insertActiveDrive(in context: NSManagedObjectContext) {
        let active = ActiveDriveEntity.insert(into: context)
        active.id = "current"
        active.phaseRaw = DriveCapturePhase.idle.rawValue
        active.sampleCount = 0
        active.stateData = Data("{}".utf8)
        active.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func counts(_ entityNames: [String], in context: NSManagedObjectContext) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for entityName in entityNames {
            result[entityName] = try count(entityName, in: context)
        }
        return result
    }

    private func count(_ entityName: String, in context: NSManagedObjectContext) throws -> Int {
        try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
    }
}

private struct TestManifest: Decodable {
    var selectedDays: Int
    var metadata: TestMetadata
    var rowCounts: [String: Int]
}

private struct TestMetadata: Decodable {
    var appVersion: String
    var backgroundRefreshAvailable: Bool
    var lowPowerModeEnabled: Bool
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
