import CoreData
import XCTest
@testable import AppCore

final class DriveCompletionCoordinatorConfinedMovementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = Coordinate(latitude: 40.68, longitude: -73.98)

    func testHistoricalConfinedPostParkingNonDriveSignaturesAreDiscarded() throws {
        let cases: [(
            distanceMiles: Double,
            duration: TimeInterval,
            footprint: Double,
            displacement: Double,
            priorGap: TimeInterval,
            priorDistance: Double,
            automaticPrior: Bool,
            sampleCount: Int,
            validSpeedCount: Int,
            fastSpeedCount: Int
        )] = [
            (0.0087, 18, 14, 13.8, 215, 137, false, 3, 2, 0),
            (0.0978, 255, 28, 7.7, 98, 31, false, 132, 124, 0),
            (0.2513, 702, 61, 47, 249, 204, false, 675, 95, 3),
            (0.2589, 362, 87, 32.6, 95, 36.85, true, 344, 130, 4),
            // A 21-second stationary capture near the parking endpoint exceeded
            // the previous 25 m bound despite every usable speed staying below
            // the pedestrian threshold.
            (0.0703, 21, 49, 15, 113, 14.7, true, 9, 8, 0)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft(
                distanceMiles: testCase.distanceMiles,
                duration: testCase.duration,
                footprintMeters: testCase.footprint,
                endpointDisplacementMeters: testCase.displacement,
                fastSpeedSampleCount: testCase.fastSpeedCount,
                sampleCount: testCase.sampleCount,
                validSpeedSampleCount: testCase.validSpeedCount
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-testCase.priorGap),
                parkedAt: coordinate(metersNorth: -testCase.priorDistance),
                classification: testCase.automaticPrior ? nil : .personal,
                automatic: testCase.automaticPrior
            )

            let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

            assertDiscarded(outcome, source: .autoShortTrip)
            XCTAssertNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
        }
    }

    func testReviewedGenuineSubPointTwoMileDriveSignaturesAreSaved() throws {
        let cases: [(distanceMiles: Double, duration: TimeInterval, footprint: Double, displacement: Double, priorGap: TimeInterval, speed: Double)] = [
            (0.1258, 63, 104.5, 77.7, 85, 6.1),
            (0.1386, 191, 145.4, 131.2, 163, 5.8)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft(
                distanceMiles: testCase.distanceMiles,
                duration: testCase.duration,
                footprintMeters: testCase.footprint,
                endpointDisplacementMeters: testCase.displacement,
                speedMetersPerSecond: testCase.speed,
                automotiveSampleIndex: 10
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-testCase.priorGap),
                parkedAt: origin
            )

            let result = try savedResult(
                harness.coordinator.complete(draft, monitoringSessionID: nil)
            )

            XCTAssertEqual(result.trip.id, draft.id)
        }
    }

    func testExactlyNinetyFivePercentSlowSpeedsStillDiscards() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(fastSpeedSampleCount: 1)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        assertDiscarded(
            try harness.coordinator.complete(draft, monitoringSessionID: nil),
            source: .autoShortTrip
        )
    }

    func testLessThanNinetyFivePercentSlowSpeedsSaves() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(fastSpeedSampleCount: 2)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testAnyPrimaryAutomotiveMotionSaves() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(automotiveSampleIndex: 10)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testAutomotiveMotionInsideFullSnapshotSaves() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(automotiveActivitySampleIndex: 10)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testMissingSpeedCoverageFailsOpen() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(includesSpeeds: false)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testTooFewSpeedsForNonTinyCaptureFailsOpen() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(validSpeedSampleCount: 19)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testTinyArtifactDistanceBoundIsOneHundredFiftyMeters() throws {
        // 30 s at the 4 m/s pedestrian ceiling is 120 m; 150 m leaves room for
        // GPS scatter. At the bound a nine-fix capture discards on two speeds;
        // one meter past it the general twenty-speed floor applies and the
        // capture is kept.
        for (meters, expectsDiscard) in [(150.0, true), (151.0, false)] {
            let harness = try makeHarness()
            let draft = confinedDraft(
                distanceMiles: meters / 1_609.344,
                duration: 30,
                footprintMeters: 49,
                endpointDisplacementMeters: 15,
                sampleCount: 9,
                validSpeedSampleCount: 8
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-113),
                parkedAt: coordinate(metersNorth: -14.7)
            )

            let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

            if expectsDiscard {
                assertDiscarded(outcome, source: .autoShortTrip)
            } else {
                _ = try savedResult(outcome)
            }
        }
    }

    func testSpeedAtPedestrianCeilingDoesNotCountAsSlow() throws {
        let harness = try makeHarness()
        let draft = confinedDraft(speedMetersPerSecond: 4)
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testMissingPostParkingContextFailsOpen() throws {
        let harness = try makeHarness()
        let draft = confinedDraft()

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testOldOrDistantPriorTripFailsOpen() throws {
        let cases: [(gap: TimeInterval, distance: Double)] = [
            (901, 0),
            (95, 251)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft()
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-testCase.gap),
                parkedAt: coordinate(metersNorth: -testCase.distance)
            )

            _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
        }
    }

    func testPriorNotADriveDoesNotEstablishParkingContext() throws {
        let harness = try makeHarness()
        let draft = confinedDraft()
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin,
            classification: .notADrive
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testLargeFootprintOrEndpointDisplacementSaves() throws {
        let cases: [(footprint: Double, displacement: Double)] = [
            (126, 20),
            (100, 51)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft(
                footprintMeters: testCase.footprint,
                endpointDisplacementMeters: testCase.displacement
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-95),
                parkedAt: origin
            )

            _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
        }
    }

    func testPathologicalLongitudeRangeFailsOpen() throws {
        let harness = try makeHarness()
        var draft = confinedDraft()
        for index in draft.samples.indices {
            draft.samples[index].longitude = -179.999
        }
        draft.samples[1].longitude = 0
        draft.samples[2].longitude = 179.999
        let parkedAt = Coordinate(
            latitude: draft.samples[0].latitude,
            longitude: draft.samples[0].longitude
        )
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: parkedAt
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
    }

    func testCaptureOutsideDistanceOrDurationScopeSaves() throws {
        let cases: [(distanceMiles: Double, duration: TimeInterval)] = [
            (0.501, 362),
            (0.259, 1_201)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft(
                distanceMiles: testCase.distanceMiles,
                duration: testCase.duration
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-95),
                parkedAt: origin
            )

            _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
        }
    }

    func testInclusivePolicyBoundariesStillDiscard() throws {
        let cases: [(
            distanceMiles: Double,
            duration: TimeInterval,
            footprint: Double,
            displacement: Double,
            priorGap: TimeInterval,
            priorDistance: Double
        )] = [
            (0.2589, 362, 87, 32.6, 900, 0),
            (0.2589, 362, 87, 32.6, 95, 250),
            (0.5, 362, 87, 32.6, 95, 0),
            (0.2589, 1_200, 87, 32.6, 95, 0),
            (0.2589, 362, 125, 32.6, 95, 0),
            (0.2589, 362, 87, 50, 95, 0)
        ]

        for testCase in cases {
            let harness = try makeHarness()
            let draft = confinedDraft(
                distanceMiles: testCase.distanceMiles,
                duration: testCase.duration,
                footprintMeters: testCase.footprint,
                endpointDisplacementMeters: testCase.displacement
            )
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-testCase.priorGap),
                parkedAt: coordinate(metersNorth: -testCase.priorDistance)
            )

            assertDiscarded(
                try harness.coordinator.complete(draft, monitoringSessionID: nil),
                source: .autoShortTrip
            )
        }
    }

    func testEachInFlightUserDecisionProtectsQualifyingCapture() throws {
        enum UserDecision: CaseIterable {
            case classification
            case fee
            case purpose
            case note
            case manualVehicle
        }

        for decision in UserDecision.allCases {
            let harness = try makeHarness()
            var draft = confinedDraft()
            switch decision {
            case .classification:
                draft.classification = .personal
            case .fee:
                draft.fees = [
                    TripFee(
                        tripID: draft.id,
                        category: .toll,
                        amount: 5,
                        occurredAt: draft.startDate
                    )
                ]
            case .purpose:
                draft.businessPurpose = "Client visit"
            case .note:
                draft.notes = "Keep this capture"
            case .manualVehicle:
                draft.vehicleID = UUID()
                draft.vehicleAssignmentSource = .manual
            }
            try seedPriorDrive(
                harness.tripStore,
                endingAt: draft.startDate.addingTimeInterval(-95),
                parkedAt: origin
            )

            _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))
        }
    }

    func testPersistedManualDistanceOverrideProtectsQualifyingCapture() throws {
        let harness = try makeHarness()
        let draft = confinedDraft()
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )
        _ = try harness.tripStore.saveCompletedTrip(draft)
        _ = try harness.tripStore.updateReview(
            tripID: draft.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: 500)
        )

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))

        XCTAssertEqual(try harness.tripStore.fetchTrip(id: draft.id).manualDistanceOverrideMeters, 500)
    }

    func testPersistedUserManagedEndpointProtectsQualifyingCapture() throws {
        let harness = try makeHarness()
        let draft = confinedDraft()
        try seedPriorDrive(
            harness.tripStore,
            endingAt: draft.startDate.addingTimeInterval(-95),
            parkedAt: origin
        )
        let original = try harness.tripStore.saveCompletedTrip(draft)
        var update = TripEditorUpdate(trip: original, fees: [])
        update.startAddress = "User-selected start"
        let edited = try harness.tripStore.updateTrip(id: draft.id, update: update)
        XCTAssertEqual(edited.startAddressEnrichmentState, .userManaged)

        _ = try savedResult(harness.coordinator.complete(draft, monitoringSessionID: nil))

        XCTAssertEqual(
            try harness.tripStore.fetchTrip(id: draft.id).startAddress,
            "User-selected start"
        )
    }

    private struct Harness {
        var tripStore: TripStore
        var coordinator: DriveCompletionCoordinator
    }

    private func makeHarness() throws -> Harness {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let tripStore = TripStore(context: context)
        return Harness(
            tripStore: tripStore,
            coordinator: DriveCompletionCoordinator(
                tripStore: tripStore,
                activeDriveStore: ActiveDriveStore(context: context)
            )
        )
    }

    @discardableResult
    private func seedPriorDrive(
        _ store: TripStore,
        endingAt endDate: Date,
        parkedAt endpoint: Coordinate,
        classification: TripClassification? = .personal,
        automatic: Bool = false
    ) throws -> TripSummary {
        if automatic {
            let startDate = endDate.addingTimeInterval(-600)
            let startCoordinate = Coordinate(
                latitude: endpoint.latitude - 0.07,
                longitude: endpoint.longitude
            )
            return try store.saveCompletedTrip(TripDraft(
                startDate: startDate,
                endDate: endDate,
                samples: [
                    LocationSample(
                        timestamp: startDate,
                        latitude: startCoordinate.latitude,
                        longitude: startCoordinate.longitude,
                        horizontalAccuracy: 8,
                        speedMetersPerSecond: 13,
                        motionHint: .automotive
                    ),
                    LocationSample(
                        timestamp: endDate,
                        latitude: endpoint.latitude,
                        longitude: endpoint.longitude,
                        horizontalAccuracy: 8,
                        speedMetersPerSecond: 0,
                        motionHint: .stationary
                    )
                ],
                distanceMeters: DistanceConversion.meters(fromMiles: 5.13),
                classification: classification
            ))
        }
        return try makeTrip(
            store,
            start: endDate.addingTimeInterval(-600),
            duration: 600,
            distanceMiles: 5.13,
            classification: classification,
            startCoordinate: Coordinate(
                latitude: endpoint.latitude - 0.07,
                longitude: endpoint.longitude
            ),
            endCoordinate: endpoint
        )
    }

    private func confinedDraft(
        distanceMiles: Double = 0.2589,
        duration: TimeInterval = 362,
        footprintMeters: Double = 87,
        endpointDisplacementMeters: Double = 32.6,
        speedMetersPerSecond: Double = 3,
        fastSpeedSampleCount: Int = 0,
        automotiveSampleIndex: Int? = nil,
        automotiveActivitySampleIndex: Int? = nil,
        includesSpeeds: Bool = true,
        sampleCount: Int = 20,
        validSpeedSampleCount: Int? = nil
    ) -> TripDraft {
        precondition(sampleCount >= 3)
        let validSpeedSampleCount = min(validSpeedSampleCount ?? sampleCount, sampleCount)
        precondition(validSpeedSampleCount >= 0)
        precondition(fastSpeedSampleCount <= validSpeedSampleCount)
        let samples = (0..<sampleCount).map { index -> LocationSample in
            let progress = Double(index) / Double(sampleCount - 1)
            let metersNorth: Double
            switch index {
            case 0:
                metersNorth = 0
            case 1:
                metersNorth = footprintMeters
            case sampleCount - 1:
                metersNorth = endpointDisplacementMeters
            default:
                metersNorth = index.isMultiple(of: 2) ? 0 : footprintMeters * 0.75
            }
            let timestamp = start.addingTimeInterval(duration * progress)
            let hasValidSpeed = includesSpeeds && index < validSpeedSampleCount
            let isFast = hasValidSpeed
                && index >= validSpeedSampleCount - fastSpeedSampleCount
            let motionActivity: MotionActivitySnapshot?
            if index == automotiveActivitySampleIndex {
                motionActivity = MotionActivitySnapshot(
                    startDate: timestamp,
                    confidence: .high,
                    hints: [.automotive]
                )
            } else {
                motionActivity = nil
            }
            let location = coordinate(metersNorth: metersNorth)
            return LocationSample(
                timestamp: timestamp,
                latitude: location.latitude,
                longitude: location.longitude,
                horizontalAccuracy: 8,
                speedMetersPerSecond: hasValidSpeed
                    ? (isFast ? 5 : speedMetersPerSecond)
                    : nil,
                motionHint: index == automotiveSampleIndex ? .automotive : .unknown,
                motionActivity: motionActivity
            )
        }
        return TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            samples: samples,
            distanceMeters: DistanceConversion.meters(fromMiles: distanceMiles)
        )
    }

    private func coordinate(metersNorth: Double) -> Coordinate {
        Coordinate(
            latitude: origin.latitude + (metersNorth / 6_371_000) * 180 / .pi,
            longitude: origin.longitude
        )
    }

    private func savedResult(_ outcome: DriveCompletionOutcome) throws -> DriveCompletionResult {
        guard case .saved(let result) = outcome else {
            XCTFail("Expected a saved completion outcome")
            throw TestError.expectedSavedOutcome
        }
        return result
    }

    private func assertDiscarded(
        _ outcome: DriveCompletionOutcome,
        source: TripClassificationSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .discardedAutomaticCapture(let actualSource, let reason) = outcome else {
            XCTFail("Expected an automatic discard", file: file, line: line)
            return
        }
        XCTAssertEqual(actualSource, source, file: file, line: line)
        XCTAssertTrue(reason.contains("Confined post-parking movement"), file: file, line: line)
    }

    private enum TestError: Error {
        case expectedSavedOutcome
    }
}
