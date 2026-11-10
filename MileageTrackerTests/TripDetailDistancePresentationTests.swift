import AppCore
import Foundation
import SwiftUI
import XCTest
@testable import MileageTracker

@MainActor
final class TripDetailDistancePresentationTests: XCTestCase {
    func testKilometerTextUsesManualDistanceOverride() {
        var trip = makeTrip(startDate: Date(), miles: 10)
        trip.manualDistanceOverrideMeters = 5_000

        let text = TripDetailDistancePresentation.text(for: trip, unit: .kilometers)

        XCTAssertEqual(
            text,
            DistanceFormatting.valueText(meters: 5_000, unit: .kilometers)
        )
        XCTAssertNotEqual(
            text,
            DistanceFormatting.valueText(meters: trip.distanceMeters, unit: .kilometers)
        )
    }

    func testExternalEnrichmentRebasesUntouchedDraftWithoutRequestingRouteDeletion() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let startCoordinate = Coordinate(latitude: 42.35, longitude: -71.06)
        let endCoordinate = Coordinate(latitude: 42.36, longitude: -71.05)
        let routePolyline = EncodedPolyline.encode([startCoordinate, endCoordinate])
        var baseline = makeTrip(
            startDate: start,
            miles: 2,
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate,
            routePolyline: routePolyline
        )
        baseline.captureSource = "automatic"
        baseline.startAddress = nil
        baseline.endAddress = nil
        baseline.startAddressEnrichmentState = .pending
        baseline.endAddressEnrichmentState = .pending
        baseline.routeEnrichmentState = .pending

        var refreshed = baseline
        refreshed.updatedAt = start.addingTimeInterval(30)
        refreshed.startAddress = "1 Main Street"
        refreshed.endAddress = "2 State Street"
        refreshed.distanceMeters = 4_200
        refreshed.routePolyline = EncodedPolyline.encode([
            startCoordinate,
            Coordinate(latitude: 42.355, longitude: -71.055),
            endCoordinate
        ])
        refreshed.startAddressEnrichmentState = .complete
        refreshed.endAddressEnrichmentState = .complete
        refreshed.routeEnrichmentState = .complete

        var draft = refreshState(for: baseline, distanceText: "2.00")
        draft.rebaseUntouchedFields(
            from: baseline,
            to: refreshed,
            refreshedDistanceText: "2.61",
            distanceWasEdited: false,
            clearManualDistanceOverride: false,
            vehicleManuallyChanged: false
        )

        XCTAssertEqual(draft.origin, "1 Main Street")
        XCTAssertEqual(draft.destination, "2 State Street")
        XCTAssertEqual(draft.correctedDistanceText, "2.61")
        XCTAssertFalse(draft.hasPersistedFieldEdits(comparedTo: refreshed))

        let currentKey = try XCTUnwrap(ManualRouteLookupKey(
            origin: draft.origin,
            destination: draft.destination
        ))
        let storedKey = try XCTUnwrap(ManualRouteLookupKey(
            origin: refreshed.startAddress ?? "",
            destination: refreshed.endAddress ?? ""
        ))
        let presentation = ManualRouteLookupPresentation(
            lookup: ManualRouteLookupController(debounceNanoseconds: 0),
            currentKey: currentKey,
            storedKey: storedKey,
            storedTrip: refreshed
        )
        XCTAssertFalse(presentation.endpointsChangedFromStored)
        XCTAssertFalse(presentation.shouldClearRouteOnSave)
        XCTAssertNotNil(presentation.mapContent)
    }

    func testExternalEnrichmentPreservesGenuineLocalEditsAndRebasesOtherFields() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var baseline = makeTrip(startDate: start, miles: 2)
        baseline.captureSource = "automatic"
        baseline.startAddress = nil
        baseline.endAddress = nil
        baseline.startAddressEnrichmentState = .pending
        baseline.endAddressEnrichmentState = .pending

        let localVehicleID = UUID()
        var draft = refreshState(for: baseline, distanceText: "2.00")
        draft.classification = .business
        draft.purpose = "Photo shoot"
        draft.notes = "Local note"
        draft.origin = "My Studio"
        draft.startDate = start.addingTimeInterval(60)
        draft.correctedDistanceText = "9.25"
        draft.vehicleID = localVehicleID

        var refreshed = baseline
        refreshed.updatedAt = start.addingTimeInterval(30)
        refreshed.classification = .personal
        refreshed.businessPurpose = "Remote purpose"
        refreshed.notes = "Remote note"
        refreshed.startAddress = "Resolved Start"
        refreshed.endAddress = "Resolved End"
        refreshed.startDate = start.addingTimeInterval(120)
        refreshed.endDate = baseline.endDate.addingTimeInterval(120)
        refreshed.vehicleID = UUID()

        draft.rebaseUntouchedFields(
            from: baseline,
            to: refreshed,
            refreshedDistanceText: "2.50",
            distanceWasEdited: true,
            clearManualDistanceOverride: false,
            vehicleManuallyChanged: true
        )

        XCTAssertEqual(draft.classification, .business)
        XCTAssertEqual(draft.purpose, "Photo shoot")
        XCTAssertEqual(draft.notes, "Local note")
        XCTAssertEqual(draft.origin, "My Studio")
        XCTAssertEqual(draft.destination, "Resolved End")
        XCTAssertEqual(draft.startDate, start.addingTimeInterval(60))
        XCTAssertEqual(draft.endDate, refreshed.endDate)
        XCTAssertEqual(draft.correctedDistanceText, "9.25")
        XCTAssertEqual(draft.vehicleID, localVehicleID)
        XCTAssertTrue(draft.hasPersistedFieldEdits(comparedTo: refreshed))
    }

    func testProgrammaticEndpointRefreshDoesNotTriggerManualRouteChangeHandler() {
        var storedText = "Dropped Pin"
        var handledValues: [String] = []
        let source = Binding(
            get: { storedText },
            set: { storedText = $0 }
        )
        let userEditable = TripEndpointTextChangeBinding.userEditable(source) {
            handledValues.append(storedText)
        }

        // Automatic enrichment rebases the parent-owned state directly. The
        // field must display that value without launching a manual route lookup.
        storedText = "1 Main Street"
        XCTAssertEqual(userEditable.wrappedValue, "1 Main Street")
        XCTAssertTrue(handledValues.isEmpty)

        // A real text-field write still runs the manual-route workflow, after
        // the new endpoint value is visible to the callback.
        userEditable.wrappedValue = "2 State Street"
        XCTAssertEqual(storedText, "2 State Street")
        XCTAssertEqual(handledValues, ["2 State Street"])

        // Preserve the old onChange semantics: assigning the same value is not
        // another user-visible edit and should not schedule duplicate work.
        userEditable.wrappedValue = "2 State Street"
        XCTAssertEqual(handledValues, ["2 State Street"])
    }

    func testEndpointFieldShowsDeduplicatedAddressWithoutRewritingStoredText() {
        var storedText = "123 Main St, 123 Main St, Brooklyn, NY 11201, United States"
        let source = Binding(
            get: { storedText },
            set: { storedText = $0 }
        )
        let display = AddressDisplayFormatter.readableAddress(storedText)
        var manualRouteEdits = 0

        // Unfocused: the repeated reverse-geocode components stay out of sight.
        let unfocused = TripEndpointTextChangeBinding.userEditable(
            source,
            onChange: { manualRouteEdits += 1 },
            displayedAs: display
        )
        XCTAssertEqual(unfocused.wrappedValue, "123 Main St, Brooklyn, NY 11201")
        XCTAssertEqual(storedText, "123 Main St, 123 Main St, Brooklyn, NY 11201, United States")

        // The field echoing its own displayed text back is not a user edit: it
        // must neither replace the stored address nor start a route lookup.
        unfocused.wrappedValue = display
        XCTAssertEqual(storedText, "123 Main St, 123 Main St, Brooklyn, NY 11201, United States")
        XCTAssertEqual(manualRouteEdits, 0)

        // Focused: editing starts from — and saves — the persisted value.
        let focused = TripEndpointTextChangeBinding.userEditable(source, onChange: {})
        XCTAssertEqual(focused.wrappedValue, storedText)
        focused.wrappedValue = "44 Court St, Brooklyn, NY 11201"
        XCTAssertEqual(storedText, "44 Court St, Brooklyn, NY 11201")
    }

    func testAddReturnTripStructuralActionUsesSavedDraft() throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let source = try XCTUnwrap(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 5,
            origin: "Studio",
            destination: "Client",
            classification: .personal,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        var dismissed = false

        let succeeded = TripDetailStructuralAction.perform(
            saveDraft: {
                model.update(
                    source,
                    classification: .business,
                    purpose: "Photo shoot",
                    notes: "Edited before return",
                    correctedDistanceMiles: 7.25,
                    startDate: source.startDate,
                    endDate: source.endDate,
                    origin: "Updated Studio",
                    destination: "Updated Client"
                )
            },
            close: {
                dismissed = true
            },
            mutation: {
                model.addReturnTrip(source)
            },
            scheduling: { $0() }
        )

        XCTAssertTrue(succeeded)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(model.trips.count, 2)
        let returnTrip = try XCTUnwrap(model.trips.first { $0.id != source.id })
        XCTAssertEqual(returnTrip.classification, .business)
        XCTAssertEqual(returnTrip.businessPurpose, "Photo shoot")
        XCTAssertEqual(returnTrip.notes, "Edited before return")
        XCTAssertEqual(returnTrip.startAddress, "Updated Client")
        XCTAssertEqual(returnTrip.endAddress, "Updated Studio")
        XCTAssertEqual(returnTrip.miles, 7.25, accuracy: 0.001)
    }

    func testUnmergeStructuralActionUsesSavedDraft() throws {
        let model = try makeModel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 5,
            origin: "Studio",
            destination: "First Client",
            classification: .business,
            purpose: "Original purpose",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        let second = try XCTUnwrap(model.createManualTrip(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(5_400),
            distanceMiles: 6,
            origin: "First Client",
            destination: "Second Client",
            classification: .business,
            purpose: "Original purpose",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        let merged = try model.tripStore.mergeTrips(ids: [first.id, second.id])
        model.refresh()
        var dismissed = false

        let succeeded = TripDetailStructuralAction.perform(
            saveDraft: {
                model.update(
                    merged,
                    classification: .business,
                    purpose: "Edited merged purpose",
                    notes: "Edited before un-merge",
                    correctedDistanceMiles: merged.miles,
                    distanceWasEdited: false,
                    startDate: merged.startDate,
                    endDate: merged.endDate,
                    origin: merged.startAddress ?? "",
                    destination: merged.endAddress ?? ""
                )
            },
            close: {
                dismissed = true
            },
            mutation: {
                model.unmerge(merged)
            },
            scheduling: { $0() }
        )

        XCTAssertTrue(succeeded)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(Set(model.trips.map(\.id)), Set([first.id, second.id]))
        for restored in model.trips {
            XCTAssertEqual(restored.classification, .business)
            XCTAssertEqual(restored.businessPurpose, "Edited merged purpose")
            XCTAssertEqual(restored.notes, "Edited before un-merge")
        }
    }

    func testStructuralActionStopsBeforeCloseWhenDraftSaveFails() {
        var events: [String] = []

        let succeeded = TripDetailStructuralAction.perform(
            saveDraft: {
                events.append("save")
                return false
            },
            close: {
                events.append("close")
            },
            mutation: {
                events.append("mutate")
                return true
            },
            scheduling: { $0() }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(events, ["save"], "A failed save leaves the screen open and never mutates")
    }

    func testStructuralActionClosesBeforeDeferredMutation() {
        // Close-before-mutate is deliberate: once the mutation removes this
        // trip, the live-resolving .trip destination would replace the screen
        // mid-dismissal and strand it on Trip Not Found. A failed mutation
        // surfaces through the model's root-level error alert, which outlives
        // the already-closed screen.
        var events: [String] = []
        var deferred: (() -> Void)?

        let succeeded = TripDetailStructuralAction.perform(
            saveDraft: {
                events.append("save")
                return true
            },
            close: {
                events.append("close")
            },
            mutation: {
                events.append("mutate")
                return false
            },
            scheduling: { deferred = $0 }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(events, ["save", "close"], "The mutation waits for the scheduler")
        deferred?()
        XCTAssertEqual(events, ["save", "close", "mutate"])
    }

    private func refreshState(
        for trip: TripSummary,
        distanceText: String
    ) -> TripDetailDraftRefreshState {
        TripDetailDraftRefreshState(
            purpose: trip.businessPurpose ?? "",
            notes: trip.notes ?? "",
            classification: trip.classification,
            vehicleID: trip.vehicleID,
            correctedDistanceText: distanceText,
            startDate: trip.startDate,
            endDate: trip.endDate,
            origin: trip.startAddress ?? "",
            destination: trip.endAddress ?? ""
        )
    }

    private func makeModel() throws -> MileageAppModel {
        let defaults = try makeTestDefaults()
        return MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: defaults)
        )
    }
}
