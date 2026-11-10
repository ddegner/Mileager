import AppCore
import Contacts
import Foundation
import XCTest
@testable import MileageTracker

/// Plumbing tests for the AI classification-suggestion cache: backfill,
/// accept, invalidation, and gating. The provider is faked — model quality is
/// out of scope here.
@MainActor
final class MileageAppModelSuggestionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testSuggestionSettingsStayReachableWhileGenerationIsUnavailable() throws {
        let (model, provider) = try makeModel()
        provider.isAvailable = false
        provider.supportsConfiguration = true
        XCTAssertFalse(model.tripSuggestionsAvailable)
        XCTAssertTrue(model.tripSuggestionsConfigurable)
        provider.supportsConfiguration = false
        XCTAssertFalse(model.tripSuggestionsConfigurable)
    }

    func testBackfillCachesSuggestionsForUnclassifiedTripsOnly() async throws {
        let (model, provider) = try makeModel()
        let unclassified = try makeTrip(model: model)
        try makeTrip(model: model, dayOffset: -1, classification: .personal)

        model.refresh()
        await model.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.map(\.trip.id), [unclassified.id])
        XCTAssertEqual(model.tripSuggestions[unclassified.id]?.classification, .business)
        XCTAssertEqual(model.tripSuggestions.count, 1)
    }

    func testBackfillSkipsAlreadyCachedTrips() async throws {
        let (model, provider) = try makeModel()
        try makeTrip(model: model)

        model.refresh()
        await model.suggestionBackfillTask?.value
        model.refresh()
        await model.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.count, 1)
    }

    func testAcceptAppliesClassificationAndPurposeAndClearsCache() async throws {
        let (model, _) = try makeModel()
        let trip = try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[trip.id])

        model.acceptSuggestion(for: trip.id)

        let updated = try XCTUnwrap(model.trip(id: trip.id))
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.businessPurpose, "Client meeting")
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertNil(model.tripSuggestions[trip.id])
    }

    func testManualClassificationInvalidatesSuggestion() async throws {
        let (model, _) = try makeModel()
        let trip = try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[trip.id])

        model.classify(try XCTUnwrap(model.trip(id: trip.id)), as: .personal)

        XCTAssertNil(model.tripSuggestions[trip.id])
    }

    func testDeleteSweepsSuggestionOnRefresh() async throws {
        let (model, _) = try makeModel()
        let trip = try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[trip.id])

        model.delete(try XCTUnwrap(model.trip(id: trip.id)))

        XCTAssertNil(model.tripSuggestions[trip.id])
    }

    func testDisablingFeatureClearsCacheAndStopsGeneration() async throws {
        let (model, provider) = try makeModel()
        try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertEqual(model.tripSuggestions.count, 1)

        model.aiSuggestionsEnabled = false

        XCTAssertTrue(model.tripSuggestions.isEmpty)
        let requestCount = provider.requests.count
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertEqual(provider.requests.count, requestCount)
    }

    func testDisablingFeatureReleasesInFlightSuggestionWorkImmediately() throws {
        let (model, _) = try makeModel()
        let tripID = UUID()
        let worker = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        model.suggestionBackfillTask = worker
        model.suggestionBackfillRerunRequested = true
        model.suggestionEngine.suggestionsInFlight[tripID] =
            model.suggestionEngine.suggestionGeneration

        model.aiSuggestionsEnabled = false

        XCTAssertTrue(worker.isCancelled)
        XCTAssertNil(model.suggestionBackfillTask)
        XCTAssertFalse(model.suggestionBackfillRerunRequested)
        XCTAssertTrue(model.suggestionEngine.suggestionsInFlight.isEmpty)
    }

    func testInactiveAndBackgroundTransitionsReleaseSuggestionWorkers() throws {
        let (model, _) = try makeModel()
        let tripID = UUID()

        let inactiveWorker = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        model.sceneIsActive = true
        model.suggestionBackfillTask = inactiveWorker
        model.suggestionEngine.suggestionsInFlight[tripID] =
            model.suggestionEngine.suggestionGeneration

        model.appDidBecomeInactive()

        XCTAssertTrue(inactiveWorker.isCancelled)
        XCTAssertNil(model.suggestionBackfillTask)
        XCTAssertTrue(model.suggestionEngine.suggestionsInFlight.isEmpty)

        let backgroundWorker = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        model.sceneIsActive = true
        model.suggestionBackfillTask = backgroundWorker
        model.suggestionEngine.suggestionsInFlight[tripID] =
            model.suggestionEngine.suggestionGeneration

        model.appEnteredBackground()

        XCTAssertTrue(backgroundWorker.isCancelled)
        XCTAssertNil(model.suggestionBackfillTask)
        XCTAssertTrue(model.suggestionEngine.suggestionsInFlight.isEmpty)
    }

    func testUnavailableProviderGeneratesNothing() async throws {
        let (model, provider) = try makeModel()
        provider.isAvailable = false
        try makeTrip(model: model)

        model.refresh()
        await model.suggestionBackfillTask?.value

        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(model.tripSuggestions.isEmpty)
        XCTAssertFalse(model.tripSuggestionsAvailable)
    }

    func testCalendarEvidenceFlagRequiresSystemGrantNotJustToggle() async throws {
        let (model, provider) = try makeModel()
        // The injected authorization source is denied, so the request must
        // not claim calendar evidence even when the app toggle is on.
        model.calendarSuggestionEvidenceEnabled = true
        try makeTrip(model: model)

        model.refresh()
        await model.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.first?.calendarEvidenceEnabled, false)
    }

    func testSuggestionDroppedWhenTripClassifiedDuringGeneration() async throws {
        let (model, provider) = try makeModel()
        let trip = try makeTrip(model: model)
        provider.beforeReturning = { [weak model] in
            guard let model, let current = model.trip(id: trip.id) else { return }
            // Classify through the store directly: going through
            // model.classify would re-enter refresh -> backfill.
            _ = try? model.tripStore.updateReview(
                tripID: current.id,
                update: ReviewUpdate(classification: .personal, reviewStatus: .readyToExport)
            )
        }

        model.refresh()
        await model.suggestionBackfillTask?.value

        XCTAssertNil(model.tripSuggestions[trip.id])
    }

    func testTenItemBackfillPrioritizesMissingSuggestionsBeforeStaleOnes() async throws {
        let (model, provider) = try makeModel()
        provider.isAvailable = false
        var created: [TripSummary] = []
        for offset in 0..<11 {
            created.append(try makeTrip(model: model, dayOffset: -offset))
        }

        let staleTrip = created[0]
        model.tripSuggestions[staleTrip.id] = TripClassificationSuggestion(
            tripID: staleTrip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date().addingTimeInterval(-25 * 60 * 60)
        )
        model.suggestionFingerprints[staleTrip.id] = model.suggestionFingerprint(for: staleTrip)
        model.suggestionRefreshNeeded.insert(staleTrip.id)

        provider.isAvailable = true
        model.scheduleSuggestionBackfill()
        await model.suggestionBackfillTask?.value

        XCTAssertEqual(provider.requests.count, 10)
        XCTAssertFalse(provider.requests.contains { $0.trip.id == staleTrip.id })
        XCTAssertNotNil(model.tripSuggestions[staleTrip.id])
        XCTAssertTrue(model.suggestionRefreshNeeded.contains(staleTrip.id))
    }

    func testUnclassifiedTripEditInvalidatesSuggestion() async throws {
        let (model, provider) = try makeModel()
        let trip = try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[trip.id])
        provider.isAvailable = false

        model.updateQuickNotes(try XCTUnwrap(model.trip(id: trip.id)), notes: "Changed evidence")

        XCTAssertNil(model.tripSuggestions[trip.id])
        XCTAssertNil(model.suggestionFingerprints[trip.id])
    }

    func testMergeInvalidatesSuggestionsForEverySourceTrip() async throws {
        let (model, provider) = try makeModel()
        let first = try makeTrip(model: model, dayOffset: -1)
        let second = try makeTrip(model: model)
        model.refresh()
        await model.suggestionBackfillTask?.value
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[first.id])
        XCTAssertNotNil(model.tripSuggestions[second.id])
        provider.isAvailable = false

        model.merge(tripIDs: [first.id, second.id])

        XCTAssertNil(model.tripSuggestions[first.id])
        XCTAssertNil(model.tripSuggestions[second.id])
        XCTAssertFalse(model.trips.contains { $0.id == first.id || $0.id == second.id })
    }

    func testGlobalSuggestionInputsStrictlyInvalidateDisplayedState() async throws {
        let permission = SuggestionPermissionTestBox(false)
        let (model, provider) = try makeModel(calendarFullAccessProvider: { permission.value })
        let trip = try makeTrip(model: model)
        provider.isAvailable = false

        installSuggestion(for: try XCTUnwrap(model.trip(id: trip.id)), in: model)
        model.saveBusinessPurposePresets(["Site visit"])
        XCTAssertTrue(model.tripSuggestions.isEmpty, "business-purpose presets")

        installSuggestion(for: try XCTUnwrap(model.trip(id: trip.id)), in: model)
        let card = CNMutableContact()
        card.givenName = "Private"
        let home = CNMutablePostalAddress()
        home.street = "111 Example St"
        home.city = "Brooklyn"
        card.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: home)]
        model.applyUserCard(card)
        XCTAssertTrue(model.tripSuggestions.isEmpty, "My Card configuration")

        installSuggestion(for: try XCTUnwrap(model.trip(id: trip.id)), in: model)
        model.contactSuggestionEvidenceEnabled.toggle()
        XCTAssertTrue(model.tripSuggestions.isEmpty, "evidence setting")

        installSuggestion(for: try XCTUnwrap(model.trip(id: trip.id)), in: model)
        let contactsAuthorized: Bool = switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: true
        default: false
        }
        model.lastSuggestionPermissionSnapshot = .init(
            calendarFullAccess: false,
            contactsAuthorized: contactsAuthorized
        )
        permission.value = true
        model.reconcileSuggestionPermissionsOnForeground()
        XCTAssertTrue(model.tripSuggestions.isEmpty, "permission change")
    }

    // MARK: - Helpers

    /// Reset regression: a worker cancelled mid-generation must not respawn
    /// from a pending rerun request — performReset awaits the cancelled
    /// worker, and a respawn inside that await outlives the reset and can
    /// write pre-reset suggestions after the cache wipe.
    func testCancelledBackfillWorkerNeverRespawnsFromRerunRequest() async throws {
        let (model, provider) = try makeModel()
        provider.beforeReturning = {
            // A refresh landed mid-generation and requested a rerun, then the
            // worker was cancelled (the reset path does exactly this).
            model.suggestionBackfillRerunRequested = true
            model.suggestionBackfillTask?.cancel()
        }
        try makeTrip(model: model, dayOffset: 0)
        try makeTrip(model: model, dayOffset: 1)
        await model.waitForSuggestionCacheHydration()
        try await drainBackfill(model)

        XCTAssertNil(model.suggestionBackfillTask)
        XCTAssertEqual(provider.requests.count, 1, "cancelled worker respawned and generated again")
    }

    func testResetInProgressBlocksBackfillScheduling() async throws {
        let (model, provider) = try makeModel()
        await model.waitForSuggestionCacheHydration()
        model.resetInProgress = true
        try makeTrip(model: model, dayOffset: 0)
        try await drainBackfill(model)

        XCTAssertNil(model.suggestionBackfillTask)
        XCTAssertTrue(provider.requests.isEmpty, "backfill ran during an active reset")
    }

    /// Yields until no backfill worker is active (bounded).
    private func drainBackfill(_ model: MileageAppModel) async throws {
        for _ in 0..<10_000 {
            if model.suggestionBackfillTask == nil { return }
            await Task.yield()
        }
        XCTFail("backfill worker never drained")
    }

    private func makeModel(
        calendarFullAccessProvider: @escaping @Sendable () -> Bool = { false }
    ) throws -> (MileageAppModel, FakeTripSuggestionProvider) {
        let defaults = try makeTestDefaults()
        let provider = FakeTripSuggestionProvider()
        let model = MileageAppModel(
            previewMode: true,
            preferences: Preferences(defaults: defaults),
            suggestionProvider: provider,
            calendarFullAccessProvider: calendarFullAccessProvider
        )
        return (model, provider)
    }

    private func installSuggestion(for trip: TripSummary, in model: MileageAppModel) {
        model.tripSuggestions[trip.id] = TripClassificationSuggestion(
            tripID: trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
        model.suggestionFingerprints[trip.id] = model.suggestionFingerprint(for: trip)
        model.suggestionRefreshNeeded.remove(trip.id)
    }

    @discardableResult
    private func makeTrip(
        model: MileageAppModel,
        dayOffset: Int = 0,
        classification: TripClassification? = nil,
        purpose: String = ""
    ) throws -> TripSummary {
        let tripStart = start.addingTimeInterval(TimeInterval(dayOffset * 86_400))
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: tripStart,
            endDate: tripStart.addingTimeInterval(1_800),
            distanceMiles: 12,
            origin: "111 Example St, Brooklyn",
            destination: "350 5th Ave, New York",
            // Coordinates mirror what automatic capture always records.
            resolvedRoute: ResolvedManualRoute(
                startCoordinate: Coordinate(latitude: 40.702, longitude: -73.988),
                endCoordinate: Coordinate(latitude: 40.74844, longitude: -73.98565)
            ),
            classification: classification,
            purpose: purpose,
            notes: "",
            tolls: 0,
            parking: 0
        ))
        model.refresh()
        return try XCTUnwrap(model.trip(id: created.id))
    }
}

private final class SuggestionPermissionTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

@MainActor
private final class FakeTripSuggestionProvider: TripSuggestionProviding {
    var isAvailable = true
    var supportsConfiguration = true
    private(set) var requests: [TripSuggestionRequest] = []
    /// Runs after the request is recorded, before the suggestion is returned —
    /// lets tests mutate state "while the model is generating".
    var beforeReturning: (() -> Void)?

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        requests.append(request)
        beforeReturning?()
        return TripClassificationSuggestion(
            tripID: request.trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
    }
}
