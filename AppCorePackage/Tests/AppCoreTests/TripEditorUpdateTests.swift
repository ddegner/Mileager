import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class TripEditorUpdateTests: XCTestCase {
    func testEditorUpdateCommitsRouteReviewVehicleAndFeesInOneChange() throws {
        let (store, context) = try makeStore()
        let vehicle = try VehicleStore(context: context).createVehicle(name: "Work Van")
        let trip = try makeTrip(store, day: 1)
        let manual = try store.addFee(TripFee(
            tripID: trip.id,
            category: .toll,
            amount: 4,
            occurredAt: trip.startDate,
            label: "Old toll"
        ))
        let imported = try store.addFee(TripFee(
            tripID: trip.id,
            category: .toll,
            amount: 7.25,
            occurredAt: trip.startDate.addingTimeInterval(300),
            label: "Bridge",
            source: .ezPassImport,
            sourceTransactionID: "import-1"
        ))
        let start = Coordinate(latitude: 40.7409, longitude: -74.0021)
        let middle = Coordinate(latitude: 40.7367, longitude: -73.9950)
        let end = Coordinate(latitude: 40.7404, longitude: -73.9877)
        let newStart = trip.startDate.addingTimeInterval(120)
        let newEnd = trip.endDate.addingTimeInterval(600)
        let parking = TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 18,
            occurredAt: newEnd,
            label: "Client garage"
        )
        var changedManual = manual
        changedManual.amount = 5.5
        changedManual.label = "Tunnel"
        let observer = EditorChangeObserver()
        store.changeObserver = observer
        let before = try store.editableSnapshot(tripID: trip.id)

        let result = try store.updateTripWithSnapshots(
            id: trip.id,
            update: TripEditorUpdate(
                startDate: newStart,
                endDate: newEnd,
                startCoordinate: start,
                endCoordinate: end,
                startAddress: "111 Eighth Ave, New York, NY",
                endAddress: "228 Park Ave S, New York, NY",
                startAddressComponents: TripEndpointAddressComponents(
                    streetNumber: "111", streetName: "Eighth Ave", city: "New York", state: "NY"
                ),
                endAddressComponents: TripEndpointAddressComponents(
                    streetNumber: "228", streetName: "Park Ave S", city: "New York", state: "NY"
                ),
                distanceMeters: 6_800,
                routePolyline: EncodedPolyline.encode([start, middle, end]),
                manualDistanceOverrideMeters: 7_000,
                classification: .business,
                businessPurpose: "Client meeting",
                notes: "Discussed the renewal.",
                vehicleID: vehicle.id,
                fees: [parking, imported, changedManual]
            )
        )
        let updated = result.trip

        XCTAssertEqual(result.before, before)
        XCTAssertEqual(result.after, try store.editableSnapshot(tripID: trip.id))
        XCTAssertEqual(updated.startDate, newStart)
        XCTAssertEqual(updated.endDate, newEnd)
        XCTAssertEqual(updated.startCoordinate, start)
        XCTAssertEqual(updated.endCoordinate, end)
        XCTAssertEqual(updated.distanceMeters, 6_800)
        XCTAssertEqual(updated.manualDistanceOverrideMeters, 7_000)
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.businessPurpose, "Client meeting")
        XCTAssertEqual(updated.notes, "Discussed the renewal.")
        XCTAssertEqual(updated.vehicleID, vehicle.id)
        XCTAssertEqual(updated.vehicleAssignmentSource, .manual)
        XCTAssertEqual(updated.tollsAmount, 12.75, accuracy: 0.001)
        XCTAssertEqual(updated.parkingAmount, 18, accuracy: 0.001)
        XCTAssertEqual(try store.fetchFees(tripID: trip.id), [changedManual, imported, parking].sorted(by: TripEditorUpdate.feeOrder))
        XCTAssertEqual(observer.changes.count, 1)
        XCTAssertEqual(observer.changes[0].upserted.map(\.id), [trip.id])
    }

    func testInvalidFeeRollsBackEveryEditorFieldWithoutNotification() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let before = try store.editableSnapshot(tripID: trip.id)
        var update = TripEditorUpdate(trip: trip, fees: [])
        update.startAddress = "Should roll back"
        update.notes = "Should roll back"
        update.fees = [TripFee(
            tripID: trip.id,
            category: .parking,
            amount: -1,
            occurredAt: trip.startDate
        )]
        let observer = EditorChangeObserver()
        store.changeObserver = observer

        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: update)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidAmount)
        }

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
        XCTAssertTrue(observer.changes.isEmpty)
    }

    func testEditorRejectsMissingChangedAndCrossTripImportedFees() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let other = try makeTrip(store, day: 2)
        let imported = try store.addFee(TripFee(
            tripID: trip.id,
            category: .toll,
            amount: 9,
            occurredAt: trip.startDate,
            source: .ezPassImport,
            sourceTransactionID: "import-1"
        ))
        let otherFee = try store.addFee(TripFee(
            tripID: other.id,
            category: .parking,
            amount: 3,
            occurredAt: other.startDate
        ))
        let before = try store.editableSnapshot(tripID: trip.id)

        var missingImported = TripEditorUpdate(trip: trip, fees: [])
        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: missingImported)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }

        var changedImported = imported
        changedImported.amount = 99
        missingImported.fees = [changedImported]
        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: missingImported)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }

        missingImported.fees = [imported, otherFee]
        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: missingImported)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }

        XCTAssertEqual(try store.editableSnapshot(tripID: trip.id), before)
        XCTAssertEqual(try store.fetchFees(tripID: other.id), [otherFee])
    }

    func testNoOpDoesNotMarkEditedOrNotify() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let observer = EditorChangeObserver()
        store.changeObserver = observer

        let result = try store.updateTripWithSnapshots(
            id: trip.id,
            update: TripEditorUpdate(trip: trip, fees: [])
        )

        XCTAssertEqual(result.trip, trip)
        XCTAssertEqual(result.before, result.after)
        XCTAssertTrue(observer.changes.isEmpty)
    }

    func testClearingEditorPolylineDoesNotRebuildItFromLegEndpoints() throws {
        let (store, context) = try makeStore()
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Coordinate(latitude: 40.7409, longitude: -74.0021)
        let end = Coordinate(latitude: 40.7404, longitude: -73.9877)
        let routePolyline = EncodedPolyline.encode([start, end])
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            startCoordinate: start,
            endCoordinate: end,
            startAddress: "Origin",
            endAddress: "Destination",
            distanceMeters: 5_000,
            routePolyline: routePolyline
        ))
        XCTAssertEqual(trip.routePolyline, routePolyline)
        XCTAssertEqual(trip.legs.first?.routePolyline, routePolyline)
        var update = TripEditorUpdate(trip: trip, fees: [])
        update.routePolyline = nil

        let result = try store.updateTrip(id: trip.id, update: update)
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", trip.id as CVarArg)
        let entity = try XCTUnwrap(context.fetch(request).first)

        XCTAssertNil(entity.routePolyline)
        XCTAssertNil(result.routePolyline)
        XCTAssertNil(result.legs.first?.routePolyline)
        XCTAssertEqual(result.startCoordinate, start)
        XCTAssertEqual(result.endCoordinate, end)
        XCTAssertEqual(result.distanceMeters, 5_000)
    }

    func testMergedEndpointEditInvalidatesOnlyAffectedLegAndPreservesSourceMileage() throws {
        let (store, _) = try makeStore()
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let firstStart = Coordinate(latitude: 40.000, longitude: -74.000)
        let firstEnd = Coordinate(latitude: 40.010, longitude: -73.990)
        let secondStart = Coordinate(latitude: 41.000, longitude: -75.000)
        let secondEnd = Coordinate(latitude: 41.010, longitude: -74.990)
        let firstPolyline = EncodedPolyline.encode([firstStart, firstEnd])
        let secondPolyline = EncodedPolyline.encode([secondStart, secondEnd])
        let first = try store.createManualTrip(ManualTripInput(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1_800),
            startCoordinate: firstStart,
            endCoordinate: firstEnd,
            startAddress: "First origin",
            endAddress: "First destination",
            distanceMeters: 4_000,
            routePolyline: firstPolyline
        ))
        let second = try store.createManualTrip(ManualTripInput(
            startDate: startDate.addingTimeInterval(3_600),
            endDate: startDate.addingTimeInterval(5_400),
            startCoordinate: secondStart,
            endCoordinate: secondEnd,
            startAddress: "Second origin",
            endAddress: "Second destination",
            distanceMeters: 6_000,
            routePolyline: secondPolyline
        ))
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        var update = TripEditorUpdate(trip: merged, fees: [])
        update.startAddress = "Corrected free-text origin"
        update.startCoordinate = nil
        update.routePolyline = nil
        update.distanceMeters = 0
        update.manualDistanceOverrideMeters = merged.reportableDistanceMeters

        let edited = try store.updateTrip(id: merged.id, update: update)

        XCTAssertNil(edited.routePolyline)
        XCTAssertNil(edited.startCoordinate)
        XCTAssertEqual(edited.manualDistanceOverrideMeters, 10_000)
        XCTAssertNil(edited.legs[0].routePolyline)
        XCTAssertEqual(edited.legs[0].distanceMeters, 4_000)
        XCTAssertEqual(edited.legs[1].routePolyline, secondPolyline)
        XCTAssertEqual(edited.legs[1].distanceMeters, 6_000)

        let restored = try store.unmergeTrip(id: merged.id)
        XCTAssertNil(restored[0].routePolyline)
        XCTAssertNil(restored[0].startCoordinate)
        XCTAssertEqual(restored[0].distanceMeters, 4_000)
        XCTAssertEqual(restored[1].routePolyline, secondPolyline)
        XCTAssertEqual(restored[1].distanceMeters, 6_000)
    }

    func testNotesOnlyEditPreservesPurposeOnLegacyPersonalTrip() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let personal = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .personal, businessPurpose: "Legacy detail")
        )
        var update = TripEditorUpdate(trip: personal, fees: [])
        update.notes = "New Notes"

        let result = try store.updateTrip(id: trip.id, update: update)

        XCTAssertEqual(result.classification, .personal)
        XCTAssertEqual(result.businessPurpose, "Legacy detail")
        XCTAssertEqual(result.notes, "New Notes")
    }

    func testEditorReclassifyAwayFromBusinessPreservesPurposeForRoundTrip() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        var toBusiness = TripEditorUpdate(trip: trip, fees: [])
        toBusiness.classification = .business
        toBusiness.businessPurpose = "Client meeting"
        let business = try store.updateTrip(id: trip.id, update: toBusiness)

        var toPersonal = TripEditorUpdate(trip: business, fees: [])
        toPersonal.classification = .personal
        toPersonal.businessPurpose = nil
        let personal = try store.updateTrip(id: trip.id, update: toPersonal)
        XCTAssertEqual(personal.classification, .personal)
        XCTAssertEqual(personal.businessPurpose, "Client meeting")

        var backToBusiness = TripEditorUpdate(trip: personal, fees: [])
        backToBusiness.classification = .business
        let restored = try store.updateTrip(id: trip.id, update: backToBusiness)
        XCTAssertEqual(restored.businessPurpose, "Client meeting")
    }

    func testEditorReclassifyToNotADriveClearsPurpose() throws {
        let (store, _) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        var toBusiness = TripEditorUpdate(trip: trip, fees: [])
        toBusiness.classification = .business
        toBusiness.businessPurpose = "Client meeting"
        let business = try store.updateTrip(id: trip.id, update: toBusiness)

        var toNotADrive = TripEditorUpdate(trip: business, fees: [])
        toNotADrive.classification = .notADrive
        toNotADrive.businessPurpose = nil
        let updated = try store.updateTrip(id: trip.id, update: toNotADrive)

        XCTAssertEqual(updated.classification, .notADrive)
        XCTAssertNil(updated.businessPurpose)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
    }

    func testEquivalentDuplicateStoredFeeCountsOnceAndEditorConvergesCopies() throws {
        let (store, context) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let fee = try store.addFee(TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 12,
            occurredAt: trip.startDate,
            label: "Garage"
        ))
        XCTAssertThrowsError(try store.addFee(fee)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }
        try insertDuplicate(of: fee, amount: fee.amount, into: context)

        var update = TripEditorUpdate(trip: try store.fetchTrip(id: trip.id), fees: [fee])
        update.notes = "Saved after convergence"

        XCTAssertEqual(try store.fetchFees(tripID: trip.id), [fee])
        XCTAssertEqual(try store.recomputeTripFeeTotals(tripID: trip.id).parkingAmount, 12)
        XCTAssertEqual(try store.updateTrip(id: trip.id, update: update).notes, "Saved after convergence")

        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", fee.id as CVarArg)
        XCTAssertEqual(try context.count(for: request), 1)
    }

    func testDivergentDuplicateStoredFeeRejectsEditAndExplicitDeleteRemovesCopies() throws {
        let (store, context) = try makeStore()
        let trip = try makeTrip(store, day: 1)
        let fee = try store.addFee(TripFee(
            tripID: trip.id,
            category: .parking,
            amount: 12,
            occurredAt: trip.startDate,
            label: "Garage"
        ))
        try insertDuplicate(of: fee, amount: 13, into: context)
        var update = TripEditorUpdate(trip: try store.fetchTrip(id: trip.id), fees: [fee])
        update.notes = "Must not partially save"

        XCTAssertThrowsError(try store.fetchFees(tripID: trip.id)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }
        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: update)) { error in
            XCTAssertEqual(error as? TripStoreError, .invalidFeeEdit)
        }
        XCTAssertEqual(try store.fetchTrip(id: trip.id).notes, "Trip 1")

        try store.deleteFee(id: fee.id)
        XCTAssertTrue(try store.fetchFees(tripID: trip.id).isEmpty)
        XCTAssertEqual(try store.fetchTrip(id: trip.id).parkingAmount, 0)
    }

    private func makeStore() throws -> (TripStore, NSManagedObjectContext) {
        let persistence = try PersistenceController(scope: .cloudOnly, inMemory: true)
        let context = persistence.container.viewContext
        return (TripStore(context: context), context)
    }

    private func makeTrip(_ store: TripStore, day: Int) throws -> TripSummary {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(day * 86_400))
        return try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Origin \(day)",
            endAddress: "Destination \(day)",
            distanceMeters: 5_000,
            notes: "Trip \(day)"
        ))
    }

    private func insertDuplicate(
        of fee: TripFee,
        amount: Double,
        into context: NSManagedObjectContext
    ) throws {
        let duplicate = TripFeeEntity.insert(into: context)
        duplicate.id = fee.id
        duplicate.tripID = fee.tripID
        duplicate.category = fee.category
        duplicate.amount = amount
        duplicate.occurredAt = fee.occurredAt
        duplicate.label = fee.label
        duplicate.source = fee.source
        duplicate.presetID = fee.presetID
        duplicate.sourceTransactionID = fee.sourceTransactionID
        duplicate.tagOrPlate = fee.tagOrPlate
        duplicate.agency = fee.agency
        duplicate.entryPlaza = fee.entryPlaza
        duplicate.exitPlaza = fee.exitPlaza
        duplicate.vehicleClass = fee.vehicleClass
        duplicate.importedAt = fee.importedAt
        try context.save()
    }
}

private final class EditorChangeObserver: TripStoreChangeObserver {
    private(set) var changes: [TripChangeSet] = []

    func tripStoreDidChange(_ change: TripChangeSet) {
        changes.append(change)
    }
}
