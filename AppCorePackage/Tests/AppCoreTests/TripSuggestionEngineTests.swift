import AppCoreEnrichment
import AppCoreModels
import Foundation
import XCTest
@testable import AppCore
@testable import AppCoreSuggestions

/// Behavioral suite for the shared suggestion engine, pinning the semantics
/// both app models delegate to: iPhone scheduling/caching behavior composed
/// with the adopted hardenings (attempted-version retry memory, generation
/// guards, accept-staleness validation, post-completion scene checks).
@MainActor
final class TripSuggestionEngineTests: XCTestCase {
    nonisolated(unsafe) private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suite in defaultsSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testCloudOptInChangesFingerprintAndRejectsCachedSuggestion() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        var preferences: SuggestionPreferences?
        let harness = try makeHarness(trips: [trip], provider: FakeEngineSuggestionProvider(),
                                      configurePreferences: { preferences = $0 })
        let stored = try XCTUnwrap(preferences)
        XCTAssertFalse(stored.privateCloudComputeEnabled)
        let localFingerprint = harness.engine.suggestionFingerprint(for: trip)
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertNotNil(harness.engine.validatedSuggestionForAccept(tripID: trip.id))

        stored.privateCloudComputeEnabled = true
        XCTAssertTrue(SuggestionPreferences(defaults: stored.defaults).privateCloudComputeEnabled)
        XCTAssertNotEqual(harness.engine.suggestionFingerprint(for: trip), localFingerprint)
        XCTAssertNil(harness.engine.validatedSuggestionForAccept(tripID: trip.id))

        stored.privateCloudComputeEnabled = false
        XCTAssertEqual(harness.engine.suggestionFingerprint(for: trip), localFingerprint)
    }

    func testPairedDriveStopReachesProviderAndInvalidatesWhenPartnerChanges() async throws {
        var outbound = makeTripSummary(daysAgo: 1)
        var inbound = makeTripSummary(daysAgo: 1)
        let vehicle = UUID()
        outbound.vehicleID = vehicle
        inbound.vehicleID = vehicle
        inbound.startDate = outbound.endDate.addingTimeInterval(73 * 60)
        inbound.endDate = inbound.startDate.addingTimeInterval(24 * 60)
        inbound.startAddressComponents = outbound.endAddressComponents
        inbound.endAddressComponents = outbound.startAddressComponents
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(
            trips: [outbound, inbound], provider: provider,
            calendarEvidenceEnabled: true, calendarFullAccess: { true }
        )
        let fingerprint = harness.engine.suggestionFingerprint(for: outbound)

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        let request = try XCTUnwrap(provider.requests.first { $0.trip.id == outbound.id })
        XCTAssertEqual(request.pairedDriveStop?.interval.duration, 73 * 60)
        XCTAssertEqual(request.pairedDriveStop?.partnerID, inbound.id)

        inbound.updatedAt = inbound.updatedAt.addingTimeInterval(60)
        harness.setTrips([outbound, inbound])
        XCTAssertNotEqual(harness.engine.suggestionFingerprint(for: outbound), fingerprint)
        XCTAssertNil(harness.engine.validatedSuggestionForAccept(tripID: outbound.id))
    }

    func testBackfillGeneratesForUnclassifiedTripsOnly() async throws {
        let unclassified = makeTripSummary(daysAgo: 1)
        let classified = makeTripSummary(daysAgo: 2, classification: .personal)
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(trips: [unclassified, classified], provider: provider)

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.map(\.trip.id), [unclassified.id])
        XCTAssertNotNil(harness.engine.tripSuggestions[unclassified.id])
        XCTAssertNil(harness.engine.tripSuggestions[classified.id])
    }

    func testAcceptValidationRejectsStaleFingerprintAndDropsRow() async throws {
        var trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(trips: [trip], provider: provider)
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertNotNil(harness.engine.validatedSuggestionForAccept(tripID: trip.id))

        // An edit bumps updatedAt, changing the fingerprint under the row.
        trip.updatedAt = trip.updatedAt.addingTimeInterval(60)
        harness.setTrips([trip])

        XCTAssertNil(harness.engine.validatedSuggestionForAccept(tripID: trip.id))
        XCTAssertNil(
            harness.engine.tripSuggestions[trip.id],
            "A stale suggestion must be dropped so the band never re-offers it"
        )
    }

    func testAttemptedVersionSkipsFailedTripUntilEdited() async throws {
        var trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        provider.failingTripIDs = [trip.id]
        let harness = try makeHarness(trips: [trip], provider: provider)

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertEqual(provider.requests.count, 1)

        // A second pass skips the failed version instead of spinning on it.
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertEqual(provider.requests.count, 1)

        // Editing the trip clears the memory for it.
        trip.updatedAt = trip.updatedAt.addingTimeInterval(60)
        harness.setTrips([trip])
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testRegenerateReachesPreviouslyFailedTrips() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        provider.failingTripIDs = [trip.id]
        let harness = try makeHarness(trips: [trip], provider: provider)
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value
        XCTAssertEqual(provider.requests.count, 1)

        provider.failingTripIDs = []
        harness.engine.regenerateSuggestions()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertNotNil(harness.engine.tripSuggestions[trip.id])
    }

    func testRegenerateDuringInFlightWorkerStartsReplacementGeneration() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = ControlledEngineSuggestionProvider()
        let harness = try makeHarness(trips: [trip], provider: provider)

        harness.engine.scheduleSuggestionBackfill()
        await provider.waitForRequest()
        let supersededWorker = try XCTUnwrap(harness.engine.suggestionBackfillTask)

        harness.engine.regenerateSuggestions()
        XCTAssertTrue(supersededWorker.isCancelled)
        XCTAssertFalse(harness.engine.suggestionBackfillRerunRequested)

        provider.finishPending()
        await supersededWorker.value
        await provider.waitForRequest()

        XCTAssertEqual(
            provider.requestCount,
            2,
            "The old generation must release its worker handle and start the requested replacement"
        )
        if provider.requestCount == 2 {
            provider.finishPending()
            await harness.engine.suggestionBackfillTask?.value
        }
        XCTAssertNil(harness.engine.suggestionBackfillTask)
        XCTAssertNotNil(harness.engine.tripSuggestions[trip.id])
    }

    func testEvidenceOptOutCancelsSuspendedProviderBeforeSendForScheduledAndDirectCalls() async throws {
        for directCall in [false, true] {
            let trip = makeTripSummary(daysAgo: 1)
            let provider = ControlledEngineSuggestionProvider()
            var configuredPreferences: SuggestionPreferences?
            let harness = try makeHarness(
                trips: [trip], provider: provider,
                calendarEvidenceEnabled: true,
                calendarFullAccess: { true },
                configurePreferences: { preferences in
                    self.configureOwnHomeAndWork(preferences)
                    configuredPreferences = preferences
                }
            )
            let work: Task<Void, Never>
            if directCall {
                work = Task { await harness.engine.generateSuggestionIfNeeded(for: trip.id) }
            } else {
                harness.engine.scheduleSuggestionBackfill()
                work = try XCTUnwrap(harness.engine.suggestionBackfillTask)
            }
            await provider.waitForRequest()
            XCTAssertEqual(provider.latestRequest?.calendarEvidenceEnabled, true)
            XCTAssertEqual(provider.latestRequest?.contactEvidenceEnabled, true)

            let preferences = try XCTUnwrap(configuredPreferences)
            preferences.calendarEvidenceEnabled = false
            preferences.contactEvidenceEnabled = false
            harness.engine.invalidateAllSuggestions()
            provider.finishPending()
            await work.value

            XCTAssertEqual(provider.cancelledRequestCount, 1)
            XCTAssertEqual(provider.sentRequestCount, 0,
                           "A suspended request must observe cancellation before sending opted-out evidence")
            XCTAssertTrue(harness.engine.tripSuggestions.isEmpty)
            XCTAssertTrue(harness.engine.suggestionsInFlight.isEmpty)
        }
    }

    func testTwoTierCandidateSelectionPrefersMissingOverStale() async throws {
        let older = makeTripSummary(daysAgo: 3)
        let newer = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(trips: [older, newer], provider: provider)
        // The older trip already has a (stale-marked) suggestion.
        harness.engine.tripSuggestions[older.id] = TripClassificationSuggestion(
            tripID: older.id,
            classification: .business,
            businessPurpose: "Old",
            evidence: [],
            generatedAt: Date()
        )
        harness.engine.suggestionFingerprints[older.id] = harness.engine.suggestionFingerprint(for: older)
        harness.engine.suggestionRefreshNeeded.insert(older.id)

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertEqual(
            provider.requests.first?.trip.id,
            newer.id,
            "The missing suggestion outranks the stale refresh"
        )
        XCTAssertEqual(provider.requests.map(\.trip.id), [newer.id, older.id])
    }

    func testInFlightResultIsDiscardedAfterInvalidation() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = ControlledEngineSuggestionProvider()
        let harness = try makeHarness(trips: [trip], provider: provider)

        harness.engine.scheduleSuggestionBackfill()
        await provider.waitForRequest()

        harness.engine.invalidateSuggestionWork(clearSuggestions: true)
        provider.finishPending()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertNil(
            harness.engine.tripSuggestions[trip.id],
            "A result generated under an invalidated generation must not publish"
        )
    }

    func testSceneInactiveCompletionIsDiscarded() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = ControlledEngineSuggestionProvider()
        var sceneActive = true
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            sceneIsActive: { sceneActive }
        )

        harness.engine.scheduleSuggestionBackfill()
        await provider.waitForRequest()

        sceneActive = false
        provider.finishPending()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertNil(
            harness.engine.tripSuggestions[trip.id],
            "A result completing after the scene deactivated belongs to a session the user left"
        )
    }

    func testCancelledContactLoadCannotStartBackgroundModelRequest() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let contactLoader = ControlledContactIndexLoader()
        var sceneActive = true
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            sceneIsActive: { sceneActive },
            contactsAuthorized: { true },
            contactIndexLoader: { await contactLoader.value() }
        )

        harness.engine.scheduleSuggestionBackfill()
        await contactLoader.waitForLoad()
        let supersededWorker = try XCTUnwrap(harness.engine.suggestionBackfillTask)

        sceneActive = false
        harness.engine.invalidateSuggestionWork(clearSuggestions: false)
        contactLoader.finish()
        await supersededWorker.value

        XCTAssertTrue(
            provider.requests.isEmpty,
            "A cancelled contact lookup must not resume into a background model request"
        )

        sceneActive = true
        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertNotNil(harness.engine.tripSuggestions[trip.id])
    }

    func testUserWorkDestinationReachesProviderAsTypedWorkplace() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            configurePreferences: { preferences in
                preferences.contactEvidenceEnabled = true
                preferences.userWorkStreetLine = "2 Destination Ave"
                preferences.userWorkCity = "Cambridge"
            }
        )

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.destinationContactNote, "the user's work address")
        XCTAssertTrue(request.destinationIsWorkplace)
        XCTAssertEqual(request.destinationEndpointIdentity, .userWorkplace)
        XCTAssertEqual(request.originEndpointIdentity, .other)
        XCTAssertFalse(request.isDirectHomeWorkTrip)
    }

    func testOwnHomeWorkIdentityRecognizesDirectTripsInEitherDirection() async throws {
        for returningHome in [false, true] {
            for hasRecordedLeg in [false, true] {
                var trip = makeTripSummary(daysAgo: 1)
                if returningHome {
                    let origin = trip.startAddressComponents
                    let originAddress = trip.startAddress
                    trip.startAddressComponents = trip.endAddressComponents
                    trip.startAddress = trip.endAddress
                    trip.endAddressComponents = origin
                    trip.endAddress = originAddress
                }
                if hasRecordedLeg { trip.legs = [makeLeg(for: trip)] }
                let provider = FakeEngineSuggestionProvider()
                let harness = try makeHarness(
                    trips: [trip], provider: provider,
                    configurePreferences: configureOwnHomeAndWork
                )

                harness.engine.scheduleSuggestionBackfill()
                await harness.engine.suggestionBackfillTask?.value

                let request = try XCTUnwrap(provider.requests.first)
                XCTAssertEqual(request.originEndpointIdentity, returningHome ? .userWorkplace : .userHome)
                XCTAssertEqual(request.destinationEndpointIdentity, returningHome ? .userHome : .userWorkplace)
                XCTAssertTrue(request.isDirectHomeWorkTrip)
            }
        }
    }

    func testCombinedHomeWorkTripWithClientStopIsNotExcludedAsDirectCommute() async throws {
        var trip = makeTripSummary(daysAgo: 1)
        var outbound = makeLeg(for: trip)
        outbound.endDate = trip.startDate.addingTimeInterval(600)
        outbound.distanceMeters = trip.distanceMeters / 2
        outbound.endAddress = "3 Client Rd, Boston"
        outbound.endAddressComponents = TripEndpointAddressComponents(
            streetNumber: "3", streetName: "Client Rd", city: "Boston"
        )
        var onward = makeLeg(for: trip)
        onward.startDate = trip.startDate.addingTimeInterval(1_200)
        onward.distanceMeters = trip.distanceMeters / 2
        onward.startAddress = outbound.endAddress
        onward.startAddressComponents = outbound.endAddressComponents
        trip.legs = [outbound, onward]
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(
            trips: [trip], provider: provider,
            configurePreferences: configureOwnHomeAndWork
        )

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.originEndpointIdentity, .userHome)
        XCTAssertEqual(request.destinationEndpointIdentity, .userWorkplace)
        XCTAssertFalse(request.isDirectHomeWorkTrip)
    }

    func testOtherWorkplaceContactDoesNotBecomeUsersOwnWorkplace() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let key = try XCTUnwrap(ContactAddressIndex.key(streetLine: "2 Destination Ave", city: "Cambridge"))
        let harness = try makeHarness(
            trips: [trip], provider: provider,
            contactsAuthorized: { true },
            contactIndexLoader: {
                ContactAddressIndex(entries: [key: .init(contactName: "Client", isOrganization: true)])
            },
            configurePreferences: { preferences in
                preferences.contactEvidenceEnabled = true
                preferences.userHomeStreetLine = "1 Origin St"
                preferences.userHomeCity = "Boston"
            }
        )

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.originEndpointIdentity, .userHome)
        XCTAssertEqual(request.destinationEndpointIdentity, .other)
        XCTAssertTrue(request.destinationIsWorkplace)
        XCTAssertFalse(request.isDirectHomeWorkTrip)
    }

    func testDisabledContactEvidenceDoesNotIdentifyHomeOrWork() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let harness = try makeHarness(
            trips: [trip], provider: provider,
            configurePreferences: { preferences in
                self.configureOwnHomeAndWork(preferences)
                preferences.contactEvidenceEnabled = false
            }
        )

        harness.engine.scheduleSuggestionBackfill()
        await harness.engine.suggestionBackfillTask?.value

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.originEndpointIdentity, .other)
        XCTAssertEqual(request.destinationEndpointIdentity, .other)
        XCTAssertNil(request.originContactNote)
        XCTAssertNil(request.destinationContactNote)
        XCTAssertFalse(request.destinationIsWorkplace)
        XCTAssertFalse(request.isDirectHomeWorkTrip)
    }

    private func configureOwnHomeAndWork(_ preferences: SuggestionPreferences) {
        preferences.contactEvidenceEnabled = true
        preferences.userHomeStreetLine = "1 Origin St"
        preferences.userHomeCity = "Boston"
        preferences.userWorkStreetLine = "2 Destination Ave"
        preferences.userWorkCity = "Cambridge"
    }

    private func makeLeg(for trip: TripSummary) -> TripLeg {
        var leg = TripLeg(
            captureSource: "test", startDate: trip.startDate, endDate: trip.endDate,
            startCoordinate: nil, endCoordinate: nil,
            startAddress: trip.startAddress, endAddress: trip.endAddress,
            distanceMeters: trip.distanceMeters, routePolyline: nil
        )
        leg.startAddressComponents = trip.startAddressComponents
        leg.endAddressComponents = trip.endAddressComponents
        return leg
    }

    func testContactsPermissionCallbackSurvivesSceneWorkInvalidation() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let permission = ControlledPermissionRequest()
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            contactsAuthorized: { false },
            contactsPermissionUndetermined: { true },
            requestContactsAccess: { await permission.value() }
        )

        harness.engine.requestContactsAccessForSuggestions()
        await permission.waitForRequest()
        harness.engine.invalidateSuggestionWork(clearSuggestions: false)
        permission.finish(granted: false)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(
            harness.engine.contactsEvidencePermissionDenied,
            "The permission sheet's inactive scene phase must not invalidate its own callback"
        )
    }

    func testCalendarPermissionCallbackSurvivesSceneWorkInvalidation() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let permission = ControlledPermissionRequest()
        var denialCallbackCount = 0
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            calendarEvidenceEnabled: true,
            calendarPermissionUndetermined: { true },
            requestCalendarAccess: { await permission.value() },
            onCalendarAccessDenied: { denialCallbackCount += 1 }
        )

        harness.engine.requestCalendarAccessForSuggestions()
        await permission.waitForRequest()
        harness.engine.invalidateSuggestionWork(clearSuggestions: false)
        permission.finish(granted: false)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(harness.engine.calendarEvidencePermissionDenied)
        XCTAssertEqual(denialCallbackCount, 1)
    }

    func testLateContactsPermissionCallbackIgnoredAfterPermissionInvalidation() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = FakeEngineSuggestionProvider()
        let permission = ControlledPermissionRequest()
        var contactsAuthorized = false
        var contactsUndetermined = true
        let harness = try makeHarness(
            trips: [trip],
            provider: provider,
            contactsAuthorized: { contactsAuthorized },
            contactsPermissionUndetermined: { contactsUndetermined },
            requestContactsAccess: { await permission.value() }
        )

        harness.engine.requestContactsAccessForSuggestions()
        await permission.waitForRequest()
        // The user churns the feature while the system prompt is up.
        harness.engine.invalidateSuggestionPermissionRequests()
        contactsAuthorized = true
        contactsUndetermined = false
        permission.finish(granted: false)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(
            harness.engine.contactsEvidencePermissionDenied,
            "A late denial from a superseded request must not set the warning flag"
        )
    }

    func testCancelledWorkerNeverRespawnsFromRerunRequest() async throws {
        let trip = makeTripSummary(daysAgo: 1)
        let provider = ControlledEngineSuggestionProvider()
        let harness = try makeHarness(trips: [trip], provider: provider)

        harness.engine.scheduleSuggestionBackfill()
        await provider.waitForRequest()
        // A schedule request arriving mid-run normally respawns the worker...
        harness.engine.scheduleSuggestionBackfill()
        XCTAssertTrue(harness.engine.suggestionBackfillRerunRequested)

        // ...but a cancelled worker must exit without rescheduling.
        harness.engine.suggestionBackfillTask?.cancel()
        provider.finishPending()
        await harness.engine.suggestionBackfillTask?.value
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(provider.requestCount, 1)
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let engine: TripSuggestionEngine
        private let tripsBox: TripsBox

        init(engine: TripSuggestionEngine, tripsBox: TripsBox) {
            self.engine = engine
            self.tripsBox = tripsBox
        }

        func setTrips(_ trips: [TripSummary]) {
            tripsBox.trips = trips
        }
    }

    @MainActor
    private final class TripsBox {
        var trips: [TripSummary] = []
    }

    private func makeHarness(
        trips: [TripSummary],
        provider: any TripSuggestionProviding,
        sceneIsActive: @escaping () -> Bool = { true },
        contactsAuthorized: @escaping () -> Bool = { false },
        contactsPermissionUndetermined: @escaping () -> Bool = { true },
        requestContactsAccess: @escaping () async -> Bool = { false },
        contactIndexLoader: @escaping () async -> ContactAddressIndex = {
            ContactAddressIndex(entries: [:])
        },
        calendarEvidenceEnabled: Bool = false,
        calendarFullAccess: @escaping () -> Bool = { false },
        calendarPermissionUndetermined: @escaping () -> Bool = { true },
        requestCalendarAccess: @escaping () async -> Bool = { false },
        onCalendarAccessDenied: @escaping () -> Void = {},
        configurePreferences: (SuggestionPreferences) -> Void = { _ in }
    ) throws -> Harness {
        let box = TripsBox()
        box.trips = trips
        let suite = "TripSuggestionEngineTests-\(UUID().uuidString)"
        defaultsSuiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = SuggestionPreferences(defaults: defaults)
        preferences.calendarEvidenceEnabled = calendarEvidenceEnabled
        configurePreferences(preferences)
        let engine = TripSuggestionEngine(dependencies: .init(
            provider: { provider },
            unclassifiedTrips: { box.trips.filter { $0.classification == nil } },
            nearbyTrips: { box.trips },
            fetchTrip: { id in box.trips.first { $0.id == id } },
            businessPurposePresets: { ["Client meeting"] },
            preferences: preferences,
            calendarFullAccess: calendarFullAccess,
            contactsAuthorized: contactsAuthorized,
            contactsPermissionUndetermined: contactsPermissionUndetermined,
            contactsPermissionRawValue: { 0 },
            calendarPermissionUndetermined: calendarPermissionUndetermined,
            requestContactsAccess: requestContactsAccess,
            requestCalendarAccess: requestCalendarAccess,
            contactIndexLoader: contactIndexLoader,
            sceneIsActive: sceneIsActive,
            onCalendarAccessDenied: onCalendarAccessDenied
        ))
        return Harness(engine: engine, tripsBox: box)
    }

    private func makeTripSummary(
        daysAgo: Double,
        classification: TripClassification? = nil
    ) -> TripSummary {
        let start = Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        return TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: start.addingTimeInterval(1_800),
            captureSource: "test",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "1 Origin St",
            endAddress: "2 Destination Ave",
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "1",
                streetName: "Origin St",
                city: "Boston"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "2",
                streetName: "Destination Ave",
                city: "Cambridge"
            ),
            distanceMeters: 10_000,
            routePolyline: nil,
            classification: classification,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil,
            legs: []
        )
    }
}

@MainActor
private final class FakeEngineSuggestionProvider: TripSuggestionProviding {
    var isAvailable = true
    var failingTripIDs: Set<UUID> = []
    private(set) var requests: [TripSuggestionRequest] = []

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        requests.append(request)
        guard !failingTripIDs.contains(request.trip.id) else { return nil }
        return TripClassificationSuggestion(
            tripID: request.trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
    }
}

/// Continuation-driven provider so tests control exactly when a generation
/// completes relative to invalidations and scene changes.
@MainActor
private final class ControlledEngineSuggestionProvider: TripSuggestionProviding {
    var isAvailable = true
    private(set) var requestCount = 0
    private(set) var latestRequest: TripSuggestionRequest?
    private(set) var cancelledRequestCount = 0
    private(set) var sentRequestCount = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var requestArrived: CheckedContinuation<Void, Never>?

    func prewarm() {}

    func waitForRequest() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { requestArrived = $0 }
    }

    func finishPending() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        requestCount += 1
        latestRequest = request
        requestArrived?.resume()
        requestArrived = nil
        await withCheckedContinuation { pending.append($0) }
        // Stand in for the real provider's cancellable send point after
        // asynchronous evidence/locale preparation has completed.
        guard !Task.isCancelled else {
            cancelledRequestCount += 1
            return nil
        }
        sentRequestCount += 1
        return TripClassificationSuggestion(
            tripID: request.trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
    }
}

@MainActor
private final class ControlledPermissionRequest {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestArrived: CheckedContinuation<Void, Never>?

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requestArrived = $0 }
    }

    func value() async -> Bool {
        requestArrived?.resume()
        requestArrived = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
private final class ControlledContactIndexLoader {
    private var continuation: CheckedContinuation<ContactAddressIndex, Never>?
    private var loadArrived: CheckedContinuation<Void, Never>?

    func waitForLoad() async {
        if continuation != nil { return }
        await withCheckedContinuation { loadArrived = $0 }
    }

    func value() async -> ContactAddressIndex {
        loadArrived?.resume()
        loadArrived = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: ContactAddressIndex(entries: [:]))
        continuation = nil
    }
}
