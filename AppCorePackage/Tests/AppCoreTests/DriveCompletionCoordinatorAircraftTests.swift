import CoreData
import XCTest
@testable import AppCore

final class DriveCompletionCoordinatorAircraftTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testCruiseLegCompletionIsDiscardedBeforePersistence() throws {
        let harness = try makeHarness()
        let draft = cruiseLegDraft()

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

        guard case .discardedAutomaticCapture(let source, let reason) = outcome else {
            return XCTFail("Expected an automatic discard, got \(outcome)")
        }
        XCTAssertEqual(source, .autoAircraft)
        XCTAssertTrue(reason.contains("Aircraft corroborated"), reason)
        XCTAssertNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
        XCTAssertEqual(try harness.tripStore.rawSampleCount(tripID: draft.id), 0)
    }

    func testRecompletionRemovesAnUntouchedPersistedAircraftCapture() throws {
        let harness = try makeHarness()
        let draft = cruiseLegDraft()
        _ = try harness.tripStore.saveCompletedTrip(draft)

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

        guard case .discardedAutomaticCapture(let source, _) = outcome else {
            return XCTFail("Expected an automatic discard, got \(outcome)")
        }
        XCTAssertEqual(source, .autoAircraft)
        XCTAssertNil(try harness.tripStore.fetchTripIfExists(id: draft.id))
    }

    func testAircraftCaptureWithInFlightUserDecisionIsSaved() throws {
        let harness = try makeHarness()
        var draft = cruiseLegDraft()
        draft.notes = "Flight, keep for the expense report"

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

        guard case .saved(let result) = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertNil(result.trip.classification)
        XCTAssertEqual(try harness.tripStore.fetchTrip(id: draft.id).notes, draft.notes)
    }

    func testAircraftCaptureWithPersistedUserClassificationIsSaved() throws {
        let harness = try makeHarness()
        let draft = cruiseLegDraft()
        let first = try harness.tripStore.saveCompletedTrip(draft)
        _ = try harness.tripStore.updateReview(
            tripID: first.id,
            update: ReviewUpdate(classification: .personal, reviewStatus: .readyToExport)
        )

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

        guard case .saved = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        let persisted = try harness.tripStore.fetchTrip(id: first.id)
        XCTAssertEqual(persisted.classification, .personal)
        XCTAssertNil(persisted.classificationSource)
    }

    func testHighwayDriveWithOneFastGlitchIsSaved() throws {
        let harness = try makeHarness()
        var samples = highwaySamples(from: 0, to: 1_200, interval: 2)
        samples[300].speedMetersPerSecond = 142.6
        samples[300].speedAccuracyMetersPerSecond = 1.3
        let draft = TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(1_200),
            samples: samples,
            distanceMeters: DistanceConversion.meters(fromMiles: 24)
        )

        let outcome = try harness.coordinator.complete(draft, monitoringSessionID: nil)

        guard case .saved(let result) = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(result.trip.id, draft.id)
        XCTAssertNil(result.trip.classification)
        XCTAssertNil(result.trip.classificationSource)
    }

    // MARK: - Helpers

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

    /// Gate and taxi fixes, a GPS blackout, then a single 215.9 m/s fix
    /// 460 km away.
    private func cruiseLegDraft() -> TripDraft {
        var samples = stride(from: 0.0, to: 1_920, by: 2).enumerated().map { index, offset in
            LocationSample(
                timestamp: start.addingTimeInterval(offset),
                latitude: 40.7773 + Double(index % 20) * 0.00002,
                longitude: -38.8756,
                horizontalAccuracy: 4,
                speedMetersPerSecond: 2,
                speedAccuracyMetersPerSecond: 1,
                motionHint: .automotive
            )
        }
        samples.append(LocationSample(
            timestamp: start.addingTimeInterval(4_497),
            latitude: 41.0776,
            longitude: -44.3515,
            horizontalAccuracy: 5,
            speedMetersPerSecond: 215.9,
            speedAccuracyMetersPerSecond: 2.7,
            motionHint: .automotive
        ))
        return TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(4_680),
            samples: samples,
            distanceMeters: DistanceConversion.meters(fromMiles: 1.39)
        )
    }

    private func highwaySamples(
        from startOffset: TimeInterval,
        to endOffset: TimeInterval,
        interval: TimeInterval,
        speed: Double = 32
    ) -> [LocationSample] {
        stride(from: startOffset, to: endOffset, by: interval).map { offset in
            let meters = (offset - startOffset) * speed
            return LocationSample(
                timestamp: start.addingTimeInterval(offset),
                latitude: 41.0 + (meters / 6_371_000) * 180 / .pi,
                longitude: -38.9,
                horizontalAccuracy: 5,
                speedMetersPerSecond: speed,
                speedAccuracyMetersPerSecond: 1,
                motionHint: .automotive
            )
        }
    }
}
