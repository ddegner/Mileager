import XCTest
@testable import AppCore

@MainActor
final class TripAutomaticEnrichmentGuardTests: XCTestCase {
    func testAutomaticAddressesApplyWhenTripStillMatchesBasis() throws {
        let (store, trip) = try makeTrip()
        let updated = try XCTUnwrap(store.updateAutomaticAddressesIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: trip),
            startAddress: "Resolved Start",
            endAddress: "Resolved End"
        ))

        XCTAssertEqual(updated.startAddress, "Resolved Start")
        XCTAssertEqual(updated.endAddress, "Resolved End")
    }

    func testAutomaticAddressesCannotOverwriteNewerUserEdit() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        _ = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "My Start",
            endAddress: "My End"
        )

        XCTAssertNil(try store.updateAutomaticAddressesIfUnchanged(
            basis: basis,
            startAddress: "Stale Start",
            endAddress: "Stale End"
        ))
        let preserved = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(preserved.startAddress, "My Start")
        XCTAssertEqual(preserved.endAddress, "My End")
    }

    func testAutomaticRouteWriteDoesNotInvalidateIndependentAddressEnrichment() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let filledRoute = EncodedPolyline.encode([
            Coordinate(latitude: 42, longitude: -71),
            Coordinate(latitude: 42.3, longitude: -71.3)
        ])
        XCTAssertNotNil(try store.updateAutomaticRouteIfUnchanged(
            basis: basis,
            routePolyline: filledRoute,
            distanceMeters: 4_000
        ))

        let addressed = try store.updateAutomaticAddressesIfUnchanged(
            basis: basis,
            startAddress: "Resolved Start",
            endAddress: "Resolved End"
        )

        XCTAssertEqual(addressed?.startAddress, "Resolved Start")
        XCTAssertEqual(addressed?.endAddress, "Resolved End")
        XCTAssertEqual(addressed?.routePolyline, filledRoute)
    }

    func testAutomaticRouteCannotOverwriteNewerUserDistanceOrRoute() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let editedRoute = EncodedPolyline.encode([
            Coordinate(latitude: 42.1, longitude: -71.1),
            Coordinate(latitude: 42.2, longitude: -71.2)
        ])
        _ = try store.updateRoute(
            tripID: trip.id,
            startCoordinate: Coordinate(latitude: 42.1, longitude: -71.1),
            endCoordinate: Coordinate(latitude: 42.2, longitude: -71.2),
            routePolyline: editedRoute,
            distanceMeters: 2_500
        )

        let staleRoute = EncodedPolyline.encode([
            Coordinate(latitude: 42, longitude: -71),
            Coordinate(latitude: 42.3, longitude: -71.3)
        ])
        XCTAssertNil(try store.updateAutomaticRouteIfUnchanged(
            basis: basis,
            routePolyline: staleRoute,
            distanceMeters: 4_000
        ))
        let preserved = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(preserved.routePolyline, editedRoute)
        XCTAssertEqual(preserved.distanceMeters, 2_500)
    }

    func testStaleAutomaticAttentionCannotReopenReviewedTrip() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .personal)
        )

        XCTAssertNil(try store.appendAutomaticRouteAttentionReasonIfUnchanged(
            basis: basis,
            attentionReason: AutomaticRouteFiller.lowConfidenceAttentionReason
        ))
        let preserved = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(preserved.reviewStatus, .readyToExport)
        XCTAssertFalse(preserved.needsAttention)
    }

    func testAutomaticClassificationAppliesToUntouchedAutomaticTrip() throws {
        let (store, trip) = try makeTrip()

        let updated = try XCTUnwrap(store.applyAutomaticClassificationIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: trip),
            rawSamples: try store.fetchRawSamples(tripID: trip.id),
            classification: .notADrive,
            source: .autoWater
        ))

        XCTAssertEqual(updated.classification, .notADrive)
        XCTAssertEqual(updated.classificationSource, .autoWater)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertNil(updated.businessPurpose)
        XCTAssertTrue(updated.attentionReasons.isEmpty)
    }

    func testAutomaticClassificationAllowsIndependentAutomaticAddressUpdate() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let rawSamples = try store.fetchRawSamples(tripID: trip.id)
        let addressed = try XCTUnwrap(store.updateAutomaticEndpointIfUnchanged(
            basis: basis,
            component: .startAddress,
            address: "Resolved Start"
        ))
        XCTAssertEqual(addressed.startAddress, "Resolved Start")

        let updated = try XCTUnwrap(store.applyAutomaticClassificationIfUnchanged(
            basis: basis,
            rawSamples: rawSamples,
            classification: .notADrive,
            source: .autoWater
        ))

        XCTAssertEqual(updated.classificationSource, .autoWater)
        XCTAssertEqual(updated.startAddress, "Resolved Start")
    }

    func testAutomaticClassificationRejectsUserEditedTripWithFreshBasis() throws {
        let (store, trip) = try makeTrip()
        let edited = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(notes: "Keep this capture")
        )

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: edited),
            rawSamples: try store.fetchRawSamples(tripID: trip.id),
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    func testAutomaticClassificationRejectsUserManagedEndpoint() throws {
        let (store, trip) = try makeTrip()
        let edited = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "My Dock",
            endAddress: nil
        )

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: edited),
            rawSamples: try store.fetchRawSamples(tripID: trip.id),
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    func testAutomaticClassificationRejectsConcurrentPathChange() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let rawSamples = try store.fetchRawSamples(tripID: trip.id)
        let route = EncodedPolyline.encode([
            try XCTUnwrap(trip.startCoordinate),
            try XCTUnwrap(trip.endCoordinate)
        ])
        XCTAssertNotNil(try store.updateAutomaticRouteIfUnchanged(
            basis: basis,
            routePolyline: route,
            distanceMeters: trip.distanceMeters + 500
        ))

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: basis,
            rawSamples: rawSamples,
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    func testAutomaticClassificationRejectsConcurrentRawSampleReplacement() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let rawSamples = try store.fetchRawSamples(tripID: trip.id)
        var replacementSamples = rawSamples
        replacementSamples.insert(
            LocationSample(
                timestamp: trip.startDate.addingTimeInterval(900),
                latitude: 42.15,
                longitude: -71.15,
                horizontalAccuracy: 5,
                motionHint: .automotive
            ),
            at: 1
        )
        _ = try store.saveCompletedTrip(TripDraft(
            id: trip.id,
            startDate: trip.startDate,
            endDate: trip.endDate,
            samples: replacementSamples,
            distanceMeters: trip.distanceMeters
        ))

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: basis,
            rawSamples: rawSamples,
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    func testAutomaticClassificationRejectsConcurrentCaptureWindowChange() throws {
        let (store, trip) = try makeTrip()
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        let rawSamples = try store.fetchRawSamples(tripID: trip.id)
        _ = try store.saveCompletedTrip(TripDraft(
            id: trip.id,
            startDate: trip.startDate.addingTimeInterval(60),
            endDate: trip.endDate.addingTimeInterval(-60),
            samples: rawSamples,
            distanceMeters: trip.distanceMeters
        ))

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: basis,
            rawSamples: rawSamples,
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    func testAutomaticClassificationRejectsAnyFeeRow() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let fee = TripFee(
            tripID: nil,
            category: .toll,
            amount: 0,
            occurredAt: start.addingTimeInterval(300),
            label: "Pending toll"
        )
        let (store, trip) = try makeTrip(fees: [fee])
        XCTAssertEqual(trip.tollsAmount, 0)
        XCTAssertEqual(try store.fetchFees(tripID: trip.id).count, 1)

        XCTAssertNil(try store.applyAutomaticClassificationIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: trip),
            rawSamples: try store.fetchRawSamples(tripID: trip.id),
            classification: .notADrive,
            source: .autoWater
        ))
        XCTAssertNil(try store.fetchTrip(id: trip.id).classification)
    }

    private func makeTrip(fees: [TripFee] = []) throws -> (TripStore, TripSummary) {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            samples: [
                LocationSample(
                    timestamp: start,
                    latitude: 42,
                    longitude: -71,
                    horizontalAccuracy: 5
                ),
                LocationSample(
                    timestamp: start.addingTimeInterval(1_800),
                    latitude: 42.3,
                    longitude: -71.3,
                    horizontalAccuracy: 5
                )
            ],
            distanceMeters: 3_000,
            fees: fees
        ))
        return (store, trip)
    }
}
