import AppCore
import XCTest
@testable import MileageTracker

/// Covers the undo feature that drives shake / three-finger / ⌘Z.
///
/// These are synchronous on purpose: `TripUndoCoordinator` sets
/// `groupsByEvent = false` and groups explicitly, so `undo()` takes effect
/// immediately instead of waiting on a run-loop observer. That avoids the
/// async-vs-viewContext flake class documented in `TripStoreHardeningTests`.
@MainActor
final class TripUndoTests: XCTestCase {

    private func makeModel() throws -> MileageAppModel {
        MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
    }

    private func makeStoredTrip(
        _ model: MileageAppModel,
        start: Date,
        miles: Double = 5,
        duration: TimeInterval = 1_800,
        classification: TripClassification? = nil,
        purpose: String? = nil
    ) throws -> TripSummary {
        try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            startAddress: "1200 Broadway, New York, NY",
            endAddress: "450 W 33rd St, New York, NY",
            distanceMeters: DistanceConversion.meters(fromMiles: miles),
            classification: classification,
            businessPurpose: purpose
        ))
    }

    // MARK: - Field edits

    /// The load-bearing case: a bulk classify must restore each trip's OWN prior
    /// state, which a naive single-snapshot restore gets wrong.
    func testUndoOfBulkClassifyRestoresPerTripPriorState() throws {
        let model = try makeModel()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let unclassified = try makeStoredTrip(model, start: base)
        let personal = try makeStoredTrip(
            model, start: base.addingTimeInterval(7_200), classification: .personal
        )
        let notADrive = try makeStoredTrip(
            model, start: base.addingTimeInterval(14_400), classification: .notADrive
        )
        model.refresh()

        model.classify(
            tripIDs: [unclassified.id, personal.id, notADrive.id],
            as: .business,
            purpose: "Client meeting"
        )
        for id in [unclassified.id, personal.id, notADrive.id] {
            XCTAssertEqual(try model.tripStore.fetchTrip(id: id).classification, .business)
        }

        XCTAssertEqual(model.undoCoordinator.undoManager.undoActionName, "Classify Trips")
        XCTAssertTrue(model.undoCoordinator.undoManager.canUndo)
        model.undoCoordinator.undoManager.undo()

        XCTAssertNil(try model.tripStore.fetchTrip(id: unclassified.id).classification)
        XCTAssertEqual(try model.tripStore.fetchTrip(id: personal.id).classification, .personal)
        XCTAssertEqual(try model.tripStore.fetchTrip(id: notADrive.id).classification, .notADrive)

        XCTAssertTrue(model.undoCoordinator.undoManager.canRedo)
        model.undoCoordinator.undoManager.redo()
        for id in [unclassified.id, personal.id, notADrive.id] {
            XCTAssertEqual(try model.tripStore.fetchTrip(id: id).classification, .business)
        }
    }

    /// `update(...)` makes four separate store calls; they must collapse into a
    /// single undo group so one shake reverts the whole edit.
    func testUndoOfTripDetailEditRevertsEveryFieldInOneStep() throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeStoredTrip(model, start: start)
        model.refresh()

        XCTAssertTrue(model.update(
            trip,
            classification: .business,
            purpose: "Photo shoot",
            notes: "Second location",
            tolls: 6.75,
            correctedDistanceMiles: 12,
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            origin: "99 Wall St, New York, NY",
            destination: "1 Metropolitan Ave, Brooklyn, NY"
        ))
        XCTAssertEqual(model.undoCoordinator.undoManager.undoActionName, "Edit Trip")

        model.undoCoordinator.undoManager.undo()

        let reverted = try model.tripStore.fetchTrip(id: trip.id)
        XCTAssertNil(reverted.classification)
        XCTAssertNil(reverted.businessPurpose)
        XCTAssertNil(reverted.notes)
        XCTAssertEqual(reverted.tollsAmount, 0)
        XCTAssertNil(reverted.manualDistanceOverrideMeters)
        XCTAssertEqual(reverted.startAddress, "1200 Broadway, New York, NY")
        XCTAssertEqual(reverted.endAddress, "450 W 33rd St, New York, NY")
        XCTAssertEqual(reverted.endDate, trip.endDate)
    }

    // MARK: - Structural commands

    func testUndoOfMergeRestoresSourcesAndRedoRestoresMergedTrip() throws {
        let model = try makeModel()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeStoredTrip(
            model, start: base, miles: 4, duration: 7_200, classification: .business, purpose: "Supplies"
        )
        let second = try makeStoredTrip(
            model, start: base.addingTimeInterval(600), miles: 9, classification: .personal
        )
        model.refresh()

        model.merge(tripIDs: [first.id, second.id])
        XCTAssertNil(try model.tripStore.fetchTripIfExists(id: first.id))
        let mergedID = try XCTUnwrap(
            model.tripStore.fetchTrips().first { $0.captureSource == "merged" }
        ).id
        XCTAssertEqual(try model.tripStore.fetchTrip(id: mergedID).endDate, first.endDate)

        XCTAssertEqual(model.undoCoordinator.undoManager.undoActionName, "Merge Trips")
        model.undoCoordinator.undoManager.undo()

        // Exact restoration, including the per-source values merge destroys.
        let restoredFirst = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: first.id))
        let restoredSecond = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: second.id))
        XCTAssertNil(try model.tripStore.fetchTripIfExists(id: mergedID))
        XCTAssertEqual(restoredFirst.classification, .business)
        XCTAssertEqual(restoredFirst.businessPurpose, "Supplies")
        XCTAssertEqual(restoredFirst.createdAt, first.createdAt)
        XCTAssertEqual(restoredFirst.captureSource, first.captureSource)
        XCTAssertEqual(restoredSecond.classification, .personal)
        XCTAssertEqual(restoredSecond.distanceMeters, second.distanceMeters)
        XCTAssertEqual(restoredFirst.endDate, first.endDate)
        XCTAssertEqual(restoredSecond.endDate, second.endDate)

        model.undoCoordinator.undoManager.redo()
        XCTAssertNotNil(try model.tripStore.fetchTripIfExists(id: mergedID))
        XCTAssertEqual(try model.tripStore.fetchTrip(id: mergedID).endDate, first.endDate)
        XCTAssertNil(try model.tripStore.fetchTripIfExists(id: first.id))
    }

    func testUndoOfDeleteRestoresTripAndItsFees() throws {
        let model = try makeModel()
        let trip = try makeStoredTrip(
            model,
            start: Date(timeIntervalSince1970: 1_800_000_000),
            classification: .business,
            purpose: "Client meeting"
        )
        let fee = try XCTUnwrap(model.addFee(
            to: trip, category: .parking, amount: 12.5, label: "Garage"
        ))
        model.refresh()

        model.delete(tripIDs: [trip.id])
        XCTAssertNil(try model.tripStore.fetchTripIfExists(id: trip.id))

        XCTAssertEqual(model.undoCoordinator.undoManager.undoActionName, "Delete Trips")
        model.undoCoordinator.undoManager.undo()

        let restored = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(restored.createdAt, trip.createdAt)
        XCTAssertEqual(restored.businessPurpose, "Client meeting")
        XCTAssertEqual(try model.tripStore.fetchFees(tripID: trip.id).map(\.id), [fee.id])
    }

    // MARK: - Gating: only interactive commands register

    /// Pins the entire gating strategy. `applyClassification` is the shared core
    /// that `SetTripClassificationIntent` calls; it must never register undo,
    /// while the UI-facing `classify` must. Fails loudly if the wrapper is ever
    /// moved down into the shared core.
    func testAppIntentClassificationDoesNotRegisterUndoButUIClassifyDoes() throws {
        let model = try makeModel()
        let trip = try makeStoredTrip(model, start: Date(timeIntervalSince1970: 1_800_000_000))
        model.refresh()

        _ = try model.applyClassification(to: trip, classification: .business)
        XCTAssertFalse(
            model.undoCoordinator.undoManager.canUndo,
            "App Intent path registered undo — the wrapper leaked into applyClassification"
        )

        let current = try model.tripStore.fetchTrip(id: trip.id)
        model.classify(current, as: .personal)
        XCTAssertTrue(model.undoCoordinator.undoManager.canUndo)
        XCTAssertEqual(model.undoCoordinator.undoManager.undoActionName, "Classify Trip")
    }

    /// Registration is suspended by default, so a direct store write — which is
    /// how background capture, enrichment, and seeding all reach Core Data —
    /// cannot land on the stack.
    func testDirectStoreWritesDoNotRegisterUndo() throws {
        let model = try makeModel()
        model.refresh()
        XCTAssertFalse(model.undoCoordinator.isRegistrationEnabled)

        _ = try makeStoredTrip(model, start: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertFalse(
            model.undoCoordinator.undoManager.canUndo,
            "a direct TripStore write registered undo; registration should be suspended"
        )
    }

    // MARK: - Invalidation

    func testRemoteCloudChangeClearsUndoHistoryIdempotently() throws {
        let model = try makeModel()
        let trip = try makeStoredTrip(model, start: Date(timeIntervalSince1970: 1_800_000_000))
        model.refresh()
        model.classify(trip, as: .business)
        XCTAssertTrue(model.undoCoordinator.undoManager.canUndo)

        model.handleRemoteCloudChange()
        model.handleRemoteCloudChange()

        XCTAssertFalse(model.undoCoordinator.undoManager.canUndo)
        XCTAssertFalse(model.undoCoordinator.undoManager.canRedo)
    }

    func testUndoStackIsBoundedByLevelsOfUndo() throws {
        let model = try makeModel()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var trips: [TripSummary] = []
        for index in 0..<12 {
            trips.append(try makeStoredTrip(model, start: base.addingTimeInterval(Double(index) * 7_200)))
        }
        model.refresh()

        for trip in trips {
            model.classify(trip, as: .business)
        }

        var undoCount = 0
        while model.undoCoordinator.undoManager.canUndo, undoCount < 50 {
            model.undoCoordinator.undoManager.undo()
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 10, "stack should be capped at levelsOfUndo")
    }

    // MARK: - Persistence and refresh after undo

    /// The coordinator does no suggestion bookkeeping of its own. This pins the
    /// reason that is safe: `refresh()` after an undo runs the suggestion
    /// engine's fingerprint sweep, so a suggestion made stale by the revert is
    /// dropped without the coordinator tracking which trips changed.
    func testUndoLeavesNoStaleSuggestionBehind() throws {
        let model = try makeModel()
        let trip = try makeStoredTrip(model, start: Date(timeIntervalSince1970: 1_800_000_000))
        model.refresh()

        // Plant a suggestion for the unclassified trip, fingerprinted against
        // its current state, exactly as the backfill would.
        model.tripSuggestions[trip.id] = TripClassificationSuggestion(
            tripID: trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
        model.suggestionFingerprints[trip.id] = model.suggestionFingerprint(for: trip)
        XCTAssertNotNil(model.tripSuggestions[trip.id])

        // Classifying clears it (existing behavior); undoing must not leave a
        // stale entry keyed to a now-different trip.
        model.classify(trip, as: .personal)
        XCTAssertNil(model.tripSuggestions[trip.id])

        model.undoCoordinator.undoManager.undo()

        // After undo the trip is unclassified again, but no suggestion is
        // present because the fingerprint sweep only KEEPS entries that
        // still match — it never resurrects one that was cleared.
        XCTAssertNil(try model.tripStore.fetchTrip(id: trip.id).classification)
        XCTAssertNil(model.tripSuggestions[trip.id])
    }


    /// Core Data undo reverts the context without saving. If the coordinator's
    /// observer did not save, the revert would be lost on the next merge.
    func testUndoLeavesNoUnsavedChangesAndRefreshesPublishedTrips() throws {
        let model = try makeModel()
        let trip = try makeStoredTrip(model, start: Date(timeIntervalSince1970: 1_800_000_000))
        model.refresh()

        model.classify(trip, as: .business)
        XCTAssertEqual(model.trips.first { $0.id == trip.id }?.classification, .business)

        model.undoCoordinator.undoManager.undo()

        XCTAssertFalse(
            model.persistence.container.viewContext.hasChanges,
            "undo left the context dirty; the post-undo save did not run"
        )
        XCTAssertNil(
            model.trips.first { $0.id == trip.id }?.classification,
            "published trips still show the pre-undo state"
        )
    }
}
