import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class MileageAppModelBluetoothTests: XCTestCase {
    func testPermissionChecklistOnlyAuthorizedIsReady() {
        for state in PermissionChecklistState.allCases {
            XCTAssertEqual(state.isReady, state == .authorized, "\(state)")
        }
    }

    func testPermissionLaunchOverridesMapRows() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--permission-states=motion:authorized,location:partial,bluetooth:denied,notifications:restricted"
            ],
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertEqual(model.permissionState(for: .motion), .authorized)
        XCTAssertEqual(model.permissionState(for: .location), .partial)
        XCTAssertEqual(model.permissionState(for: .bluetooth), .denied)
        XCTAssertEqual(model.permissionState(for: .notifications), .restricted)
    }

    func testDeniedPermissionRequestAsksForSettings() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--permission-states=location:denied"
            ],
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertEqual(model.requestPermission(.location), .openSettingsNeeded)
    }

    func testAuthorizedPermissionRequestIsIdempotent() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker",
                "--uitesting",
                "--skip-onboarding",
                "--permission-states=motion:authorized"
            ],
            preferences: Preferences(defaults: defaults)
        )

        XCTAssertEqual(model.requestPermission(.motion), .alreadyAuthorized)
    }

    func testBluetoothPermissionRequiresAuthorizationAndEnabledHints() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))

        model.vehicleBluetoothAuthorizationStatus = .allowed
        model.vehicleBluetoothHintsEnabled = false
        model.refreshPermissionStates()
        XCTAssertEqual(model.permissionState(for: .bluetooth), .partial)
        XCTAssertFalse(model.permissionState(for: .bluetooth).isReady)

        model.vehicleBluetoothHintsEnabled = true
        model.refreshPermissionStates()
        XCTAssertEqual(model.permissionState(for: .bluetooth), .authorized)
    }

    func testPermissionRequestShowsRequestingUntilRefreshCompletes() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))

        XCTAssertEqual(model.requestPermission(.location), .requested)
        XCTAssertEqual(model.permissionState(for: .location), .requesting)
    }

    func testClassifyFromUnreviewedRecordsConfirmedDriveForTripHashes() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)

        model.classify(trip, as: .business)

        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 0)
        XCTAssertEqual(model.trip(id: trip.id)?.classification, .business)
    }

    func testReclassifyBusinessToPersonalDoesNotDoubleCount() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)

        model.classify(trip, as: .business)
        let reclassified = try XCTUnwrap(model.trip(id: trip.id))
        model.classify(reclassified, as: .personal)

        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 0)
    }

    func testReclassifyNotADriveToBusinessSwapsCounters() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)

        model.classify(trip, as: .notADrive)
        var hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 0)
        XCTAssertEqual(hint.notADriveCount, 1)

        let marked = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(marked.classification, .notADrive)
        XCTAssertEqual(marked.reviewStatus, .readyToExport)
        XCTAssertNil(marked.businessPurpose)

        model.classify(marked, as: .business)
        hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 0)
    }

    func testUndoingAutoTransitMarkEmitsOnlyConfirmedDrive() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        // Earned negative evidence from an earlier explicit review must survive.
        _ = try model.bluetoothHintStore.applyReviewOutcome(
            identifierHashes: [observation.identifierHash],
            outcome: .notADrive
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)
        _ = try model.tripStore.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoTransit
        )
        model.refresh()
        let autoMarked = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(autoMarked.classificationSource, .autoTransit)

        model.classify(autoMarked, as: .business)

        // The machine's notADrive never trained, so flipping to business adds
        // a confirmation without emitting .undoNotADrive against the earned 1.
        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 1)
        let reclassified = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(reclassified.classification, .business)
        XCTAssertNil(reclassified.classificationSource)
    }

    func testUndoingAutoShortTripMarkEmitsOnlyConfirmedDrive() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        _ = try model.bluetoothHintStore.applyReviewOutcome(
            identifierHashes: [observation.identifierHash],
            outcome: .notADrive
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)
        _ = try model.tripStore.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoShortTrip
        )
        model.refresh()
        let autoMarked = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(autoMarked.classificationSource, .autoShortTrip)

        model.classify(autoMarked, as: .business)

        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 1)
        let reclassified = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(reclassified.classification, .business)
        XCTAssertNil(reclassified.classificationSource)
    }

    func testUndoingAutoWaterMarkEmitsOnlyConfirmedDrive() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "car-audio",
            displayName: "Toyota Camry",
            source: .audioRoute,
            observedAt: start.addingTimeInterval(-60)
        )
        _ = try model.bluetoothHintStore.applyReviewOutcome(
            identifierHashes: [observation.identifierHash],
            outcome: .notADrive
        )
        let trip = try makeUnreviewedTrip(model: model, start: start)
        _ = try model.tripStore.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoWater
        )
        model.refresh()
        let autoMarked = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(autoMarked.classificationSource, .autoWater)

        model.classify(autoMarked, as: .business)

        let hint = try XCTUnwrap(model.bluetoothHintStore.fetchHints().first)
        XCTAssertEqual(hint.correlationCount, 1)
        XCTAssertEqual(hint.notADriveCount, 1)
        let reclassified = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(reclassified.classification, .business)
        XCTAssertNil(reclassified.classificationSource)
    }

    func testClassifyWithExplicitPurposeUsesThatPurpose() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(previewMode: true, preferences: Preferences(defaults: defaults))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeUnreviewedTrip(model: model, start: start)

        model.classify(trip, as: .business, purpose: "Site visit")

        let classified = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(classified.businessPurpose, "Site visit")
    }

    func testVehicleReviewOutcomeTransitions() {
        typealias Outcomes = [VehicleReviewOutcome]
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: nil, new: .business), Outcomes([.confirmedDrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: nil, new: .personal), Outcomes([.confirmedDrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: nil, new: .notADrive), Outcomes([.notADrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .business, new: .personal), Outcomes([]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .business, new: .notADrive), Outcomes([.undoConfirmedDrive, .notADrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .notADrive, new: .personal), Outcomes([.undoNotADrive, .confirmedDrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .business, new: nil), Outcomes([.undoConfirmedDrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .notADrive, new: nil), Outcomes([.undoNotADrive]))
        XCTAssertEqual(MileageAppModel.vehicleReviewOutcomes(previous: .business, new: .business), Outcomes([]))
    }

    func testUnknownConnectionChoiceAssignsConnectionAndCompletedTrip() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let vehicle = try XCTUnwrap(model.createVehicle(name: "Forester"))
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "forester-carplay",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [observation.identifierHash]
        )

        model.queueVehicleConnectionDecision(for: trip)
        guard case let .unknownConnection(hint, _)? = model.pendingVehicleConnectionDecision?.kind else {
            return XCTFail("Expected a connection choice")
        }
        XCTAssertEqual(hint.identifierHash, observation.identifierHash)

        model.chooseVehicleForPendingConnection(vehicle.id)

        XCTAssertNil(model.pendingVehicleConnectionDecision)
        let assignedHint = try XCTUnwrap(
            model.bluetoothHintStore.fetchHints(matching: [observation.identifierHash]).first
        )
        XCTAssertEqual(assignedHint.vehicleID, vehicle.id)
        XCTAssertEqual(assignedHint.mappingDisposition, .assigned)
        XCTAssertNotNil(assignedHint.connectionAliasID)
        let assignedTrip = try XCTUnwrap(model.tripStore.fetchTrip(id: trip.id))
        XCTAssertEqual(assignedTrip.vehicleID, vehicle.id)
        XCTAssertEqual(assignedTrip.vehicleAssignmentSource, .vehicleConnection)
    }

    func testUnknownConnectionChoiceForDeletedTripDismissesWithoutCommittingMapping() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let vehicle = try XCTUnwrap(model.createVehicle(name: "Forester"))
        let start = Date(timeIntervalSince1970: 1_800_150_000)
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "stale-dialog-carplay",
            displayName: "SUBARU BT",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [observation.identifierHash]
        )
        model.queueVehicleConnectionDecision(for: trip)
        try model.tripStore.deleteTrip(id: trip.id)

        model.chooseVehicleForPendingConnection(vehicle.id)

        XCTAssertNil(model.pendingVehicleConnectionDecision)
        let preserved = try XCTUnwrap(
            model.bluetoothHintStore.fetchHints(matching: [observation.identifierHash]).first
        )
        XCTAssertNil(preserved.vehicleID)
        XCTAssertNil(preserved.connectionAliasID)
        XCTAssertEqual(preserved.mappingDisposition, .unreviewed)
    }

    func testNotOneOfMyVehiclesSuppressesConnectionWithoutChangingTrip() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "passenger-car",
            displayName: "Passenger Car",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [observation.identifierHash]
        )

        model.queueVehicleConnectionDecision(for: trip)
        model.ignorePendingVehicleConnection()

        let ignored = try XCTUnwrap(
            model.bluetoothHintStore.fetchHints(matching: [observation.identifierHash]).first
        )
        XCTAssertEqual(ignored.mappingDisposition, .ignored)
        XCTAssertFalse(ignored.contributesDriveDetection)
        let unchangedTrip = try XCTUnwrap(model.tripStore.fetchTrip(id: trip.id))
        XCTAssertNil(unchangedTrip.vehicleID)
        XCTAssertNil(unchangedTrip.vehicleAssignmentSource)
    }

    func testIgnoredConnectionCanBeRestoredFromVehicleSettings() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "accidentally-ignored",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier
        )
        let ignored = try model.bluetoothHintStore.markIgnored(
            identifierHash: observation.identifierHash
        )
        XCTAssertEqual(model.ignoredVehicleConnections.map(\.identifierHash), [observation.identifierHash])

        model.restoreIgnoredVehicleConnection(ignored)

        XCTAssertTrue(model.ignoredVehicleConnections.isEmpty)
        let restored = try XCTUnwrap(
            model.bluetoothHintStore.fetchHints(matching: [observation.identifierHash]).first
        )
        XCTAssertEqual(restored.mappingDisposition, .unreviewed)
        XCTAssertTrue(restored.contributesDriveDetection)
    }

    func testAskLaterWaitsUntilTheConnectionIsObservedAgain() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "later-carplay",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [observation.identifierHash]
        )

        model.queueVehicleConnectionDecision(for: trip)
        model.deferPendingVehicleConnection()

        XCTAssertTrue(try model.bluetoothHintStore.fetchReviewCandidates().isEmpty)
        let deferred = try XCTUnwrap(
            model.bluetoothHintStore.fetchHints(matching: [observation.identifierHash]).first
        )
        XCTAssertEqual(deferred.mappingDisposition, .deferred)

        _ = try model.bluetoothHintStore.recordObservation(
            identifier: "later-carplay",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(3_600)
        )

        XCTAssertEqual(
            try model.bluetoothHintStore.fetchReviewCandidates().map(\.identifierHash),
            [observation.identifierHash]
        )
        model.recoverRecentVehicleConnectionDecisionIfNeeded(
            now: start.addingTimeInterval(3_601)
        )
        XCTAssertNil(
            model.pendingVehicleConnectionDecision,
            "the new observation can qualify a later trip, but never reopens this trip"
        )
    }

    func testConflictingConnectionsRequireManualTripChoiceAndDoNotRemapEitherConnection() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let firstVehicle = try XCTUnwrap(model.createVehicle(name: "Forester"))
        let secondVehicle = try XCTUnwrap(model.createVehicle(name: "Outback"))
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            vehicleID: firstVehicle.id,
            vehicleAssignmentSource: .vehicleConnection
        )

        model.queueVehicleConnectionDecision(
            for: trip,
            conflictingVehicleIDs: [secondVehicle.id]
        )
        guard case let .conflictingVehicles(vehicleIDs, latchedVehicleID)? =
            model.pendingVehicleConnectionDecision?.kind else {
            return XCTFail("Expected a conflicting-vehicle choice")
        }
        XCTAssertEqual(vehicleIDs, [firstVehicle.id, secondVehicle.id])
        XCTAssertEqual(latchedVehicleID, firstVehicle.id)

        model.chooseVehicleForPendingConnection(secondVehicle.id)

        let correctedTrip = try XCTUnwrap(model.tripStore.fetchTrip(id: trip.id))
        XCTAssertEqual(correctedTrip.vehicleID, secondVehicle.id)
        XCTAssertEqual(correctedTrip.vehicleAssignmentSource, .manual)
        XCTAssertTrue(model.connectionAliases(for: firstVehicle.id).isEmpty)
        XCTAssertTrue(model.connectionAliases(for: secondVehicle.id).isEmpty)
    }

    func testReviewLaterPersistsConflictForTheNextForegroundRecovery() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let firstVehicle = try XCTUnwrap(model.createVehicle(name: "Forester"))
        let secondVehicle = try XCTUnwrap(model.createVehicle(name: "Outback"))
        let trip = try makeAutomaticTrip(
            model: model,
            start: Date(timeIntervalSince1970: 1_800_500_000),
            vehicleID: firstVehicle.id,
            vehicleAssignmentSource: .vehicleConnection
        )
        model.refresh()

        model.queueVehicleConnectionDecision(
            for: trip,
            conflictingVehicleIDs: [secondVehicle.id]
        )
        model.deferPendingVehicleConnection()
        XCTAssertNil(model.pendingVehicleConnectionDecision)

        model.recoverRecentVehicleConnectionDecisionIfNeeded()

        guard case let .conflictingVehicles(vehicleIDs, latchedVehicleID)? =
            model.pendingVehicleConnectionDecision?.kind else {
            return XCTFail("Expected the deferred conflict to return")
        }
        XCTAssertEqual(vehicleIDs, [firstVehicle.id, secondVehicle.id])
        XCTAssertEqual(latchedVehicleID, firstVehicle.id)
    }

    func testManualTripNeverQueuesUnknownConnectionOrLosesManualProtection() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let vehicle = try XCTUnwrap(model.createVehicle(name: "Forester"))
        let start = Date(timeIntervalSince1970: 1_800_600_000)
        let observation = try model.bluetoothHintStore.recordObservation(
            identifier: "manual-drive-route",
            displayName: "Unknown Route",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [observation.identifierHash],
            vehicleID: vehicle.id,
            vehicleAssignmentSource: .manual
        )

        model.queueVehicleConnectionDecision(for: trip)

        XCTAssertNil(model.pendingVehicleConnectionDecision)
        let preserved = try XCTUnwrap(model.tripStore.fetchTrip(id: trip.id))
        XCTAssertEqual(preserved.vehicleID, vehicle.id)
        XCTAssertEqual(preserved.vehicleAssignmentSource, .manual)
        XCTAssertEqual(
            try model.bluetoothHintStore.fetchHints().first?.mappingDisposition,
            .unreviewed
        )
    }

    func testUnknownConnectionReviewPrioritizesCarPlayOverNewerBluetooth() throws {
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: try makeTestDefaults())
        )
        model.sceneIsActive = true
        let start = Date(timeIntervalSince1970: 1_800_700_000)
        let carPlay = try model.bluetoothHintStore.recordObservation(
            identifier: "carplay-route",
            displayName: "CarPlay",
            source: .audioRoute,
            connectionKind: .carPlay,
            identityQuality: .stablePortIdentifier,
            observedAt: start
        )
        let bluetooth = try model.bluetoothHintStore.recordObservation(
            identifier: "bluetooth-route",
            displayName: "Bluetooth",
            source: .audioRoute,
            connectionKind: .bluetooth,
            identityQuality: .stablePortIdentifier,
            observedAt: start.addingTimeInterval(30)
        )
        let trip = try makeAutomaticTrip(
            model: model,
            start: start,
            startHintHashes: [bluetooth.identifierHash, carPlay.identifierHash]
        )

        model.queueVehicleConnectionDecision(for: trip)

        guard case let .unknownConnection(hint, _)? = model.pendingVehicleConnectionDecision?.kind else {
            return XCTFail("Expected a connection choice")
        }
        XCTAssertEqual(hint.identifierHash, carPlay.identifierHash)
    }

    // Manual trips carry no stamped hashes, so classify exercises the
    // legacy fallback: observations recorded within the 10-minute window
    // before the trip's start feed the learning engine.
    private func makeUnreviewedTrip(
        model: MileageAppModel,
        start: Date
    ) throws -> TripSummary {
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 5,
            origin: "Start",
            destination: "End",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        model.refresh()
        return try XCTUnwrap(model.trip(id: created.id))
    }

    private func makeAutomaticTrip(
        model: MileageAppModel,
        start: Date,
        startHintHashes: [String] = [],
        vehicleID: UUID? = nil,
        vehicleAssignmentSource: VehicleAssignmentSource? = nil
    ) throws -> TripSummary {
        let end = start.addingTimeInterval(600)
        let trip = try model.tripStore.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: end,
            samples: [
                LocationSample(
                    timestamp: start,
                    latitude: 40,
                    longitude: -73,
                    horizontalAccuracy: 8,
                    speedMetersPerSecond: 12,
                    motionHint: .automotive
                ),
                LocationSample(
                    timestamp: end,
                    latitude: 40.01,
                    longitude: -73,
                    horizontalAccuracy: 8,
                    speedMetersPerSecond: 0,
                    motionHint: .stationary
                )
            ],
            distanceMeters: 1_609.344,
            vehicleID: vehicleID,
            vehicleAssignmentSource: vehicleAssignmentSource
        ))
        guard !startHintHashes.isEmpty else { return trip }
        return try model.tripStore.setStartBluetoothHints(
            tripID: trip.id,
            identifierHashes: startHintHashes
        )
    }
}
