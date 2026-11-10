import AppCore
import Contacts
import EventKit
import Foundation

// MARK: - AI classification suggestions
//
// The orchestration lives in the shared `TripSuggestionEngine`
// (AppCoreSuggestions); this extension wires the engine with real
// CNContactStore/EKEventStore closures, forwards the state the views and
// tests consume, and keeps the flows that are genuinely iPhone-shaped:
// the permission-prompt guards for automated runs, the My Card picker,
// and the accept path through `classify`.

@MainActor
extension MileageAppModel {
    func makeSuggestionEngine() -> TripSuggestionEngine {
        TripSuggestionEngine(dependencies: .init(
            provider: { [weak self] in self?.suggestionProvider },
            unclassifiedTrips: { [weak self] in
                self?.trips.filter { $0.classification == nil } ?? []
            },
            nearbyTrips: { [weak self] in self?.trips ?? [] },
            fetchTrip: { [weak self] id in try self?.tripStore.fetchTripIfExists(id: id) },
            businessPurposePresets: { [weak self] in self?.businessPurposePresets ?? [] },
            preferences: SuggestionPreferences(defaults: preferences.defaults),
            calendarFullAccess: calendarFullAccessProvider,
            contactsAuthorized: {
                switch CNContactStore.authorizationStatus(for: .contacts) {
                case .authorized, .limited: true
                default: false
                }
            },
            contactsPermissionUndetermined: {
                CNContactStore.authorizationStatus(for: .contacts) == .notDetermined
            },
            contactsPermissionRawValue: {
                Int(CNContactStore.authorizationStatus(for: .contacts).rawValue)
            },
            calendarPermissionUndetermined: {
                EKEventStore.authorizationStatus(for: .event) == .notDetermined
            },
            requestContactsAccess: {
                (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            },
            requestCalendarAccess: {
                (try? await EKEventStore().requestFullAccessToEvents()) ?? false
            },
            sceneIsActive: { [weak self] in self?.sceneIsActive ?? false },
            bypassSceneGate: isUITesting,
            isSuspended: { [weak self] in self?.resetInProgress ?? true },
            isProtectedDataUnavailable: { [weak self] in self?.isAwaitingProtectedData ?? true },
            persister: suggestionCacheStore,
            onCalendarAccessDenied: { [weak self] in
                self?.calendarSuggestionEvidenceEnabled = false
            }
        ))
    }

    // MARK: Forwarded state (the engine is the single source of truth)

    /// Advisory AI classification suggestions for unclassified trips, keyed by
    /// trip ID. A compact local cache hydrates these after the first real-store
    /// refresh; the provider then refreshes missing or stale entries.
    var tripSuggestions: [UUID: TripClassificationSuggestion] {
        get { suggestionEngine.tripSuggestions }
        set { suggestionEngine.tripSuggestions = newValue }
    }

    /// Set when the user enabled calendar evidence but the system permission
    /// is denied; Settings shows the open-Settings guidance row.
    var calendarEvidencePermissionDenied: Bool {
        get { suggestionEngine.calendarEvidencePermissionDenied }
        set { suggestionEngine.calendarEvidencePermissionDenied = newValue }
    }

    /// Set when the contacts permission (requested on Trip Suggestions
    /// enable) is denied; Settings shows the open-Settings guidance row.
    var contactsEvidencePermissionDenied: Bool {
        get { suggestionEngine.contactsEvidencePermissionDenied }
        set { suggestionEngine.contactsEvidencePermissionDenied = newValue }
    }

    var suggestionFingerprints: [UUID: String] {
        get { suggestionEngine.suggestionFingerprints }
        set { suggestionEngine.suggestionFingerprints = newValue }
    }

    var suggestionRefreshNeeded: Set<UUID> {
        get { suggestionEngine.suggestionRefreshNeeded }
        set { suggestionEngine.suggestionRefreshNeeded = newValue }
    }

    var suggestionBackfillTask: Task<Void, Never>? {
        get { suggestionEngine.suggestionBackfillTask }
        set { suggestionEngine.suggestionBackfillTask = newValue }
    }

    var suggestionBackfillRerunRequested: Bool {
        get { suggestionEngine.suggestionBackfillRerunRequested }
        set { suggestionEngine.suggestionBackfillRerunRequested = newValue }
    }

    var lastSuggestionPermissionSnapshot: SuggestionPermissionSnapshot? {
        get { suggestionEngine.lastSuggestionPermissionSnapshot }
        set { suggestionEngine.lastSuggestionPermissionSnapshot = newValue }
    }

    var hasHydratedSuggestionCache: Bool {
        get { suggestionEngine.hasHydratedSuggestionCache }
        set { suggestionEngine.hasHydratedSuggestionCache = newValue }
    }

    var suggestionCacheHydrationTask: Task<Void, Never>? {
        get { suggestionEngine.suggestionCacheHydrationTask }
        set { suggestionEngine.suggestionCacheHydrationTask = newValue }
    }

    // MARK: Forwarded operations

    func generateSuggestionIfNeeded(for tripID: UUID) async {
        await suggestionEngine.generateSuggestionIfNeeded(for: tripID)
    }

    func scheduleSuggestionBackfill() {
        suggestionEngine.scheduleSuggestionBackfill()
    }

    func scheduleSuggestionCacheHydrationIfNeeded() {
        suggestionEngine.scheduleSuggestionCacheHydrationIfNeeded()
    }

    func waitForSuggestionCacheHydration() async {
        await suggestionEngine.waitForSuggestionCacheHydration()
    }

    func waitForSuggestionCacheInvalidations() async {
        await suggestionEngine.waitForSuggestionCacheInvalidations()
    }

    func suggestionFingerprint(for trip: TripSummary) -> String {
        suggestionEngine.suggestionFingerprint(for: trip)
    }

    func regenerateSuggestions() {
        suggestionEngine.regenerateSuggestions()
    }

    func invalidateAllSuggestions() {
        suggestionEngine.invalidateAllSuggestions()
    }

    func invalidateSuggestionWork(clearSuggestions: Bool) {
        suggestionEngine.invalidateSuggestionWork(clearSuggestions: clearSuggestions)
    }

    func reconcileSuggestionPermissionsOnForeground() {
        suggestionEngine.reconcileSuggestionPermissionsOnForeground()
    }

    var calendarEvidenceUsableForSuggestions: Bool {
        suggestionEngine.calendarEvidenceUsable
    }

    var contactEvidenceUsableForSuggestions: Bool {
        suggestionEngine.contactEvidenceUsable
    }

    // MARK: Accept

    /// One-tap accept from the suggestion row: applies exactly what the band
    /// shows through the normal review write path (vehicle-trust learning
    /// included). The engine validates staleness first — a suggestion whose
    /// trip changed underneath it is silently skipped, keeping this API's
    /// non-throwing contract. An explicit empty purpose bypasses
    /// applyClassification's default-preset injection: the band made no
    /// purpose claim, so accept must not silently write one.
    func acceptSuggestion(for tripID: UUID) {
        guard let suggestion = suggestionEngine.validatedSuggestionForAccept(tripID: tripID),
              let trip = trip(id: tripID) else {
            return
        }
        classify(trip, as: suggestion.classification, purpose: suggestion.businessPurpose ?? "")
    }

    // MARK: Permission flows (iPhone-shaped wrappers)

    /// Runs the system contacts permission flow when Trip Suggestions turns
    /// on (David's call: ask at feature enable, not per evidence source).
    /// UI-test, preview, and hosted-unit-test runs must never hit the prompt.
    func requestContactsAccessForSuggestions() {
        guard !isUITesting, !MileageAppModel.isRunningHostedUnitTests else { return }
        suggestionEngine.requestContactsAccessForSuggestions()
    }

    /// Runs the system calendar permission flow after the user enables the
    /// Settings toggle. Denial reverts the toggle (via the engine's hook) so
    /// the UI never claims evidence it cannot read.
    func requestCalendarAccessForSuggestions() {
        guard !isUITesting, !MileageAppModel.isRunningHostedUnitTests else { return }
        suggestionEngine.requestCalendarAccessForSuggestions()
    }

    // MARK: My Card

    /// Stores the user's own card ("My Card" in Settings): name plus the
    /// home/work postal addresses used to annotate trip endpoints. A single
    /// unlabeled address is treated as home.
    func applyUserCard(_ contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
        preferences.userCardName = name.isEmpty ? nil : name
        userCardName = preferences.userCardName

        var home: CNPostalAddress?
        var work: CNPostalAddress?
        for labeled in contact.postalAddresses {
            switch labeled.label {
            case CNLabelHome: home = home ?? labeled.value
            case CNLabelWork: work = work ?? labeled.value
            default: break
            }
        }
        if home == nil, contact.postalAddresses.count == 1 {
            home = contact.postalAddresses[0].value
        }
        preferences.userHomeStreetLine = home?.street.components(separatedBy: .newlines).first
        preferences.userHomeCity = home?.city
        preferences.userWorkStreetLine = work?.street.components(separatedBy: .newlines).first
        preferences.userWorkCity = work?.city
        // Notes changed for every trip near home/work.
        regenerateSuggestions()
    }
}

/// Canned provider for UI tests (`--seed-trip-suggestions`), no model
/// involved. Seeders can register a per-trip fixture (the App Store
/// screenshot data does, with calendar evidence); any unclassified trip
/// without one falls back to a Business suggestion with a canned calendar
/// title so list/detail UI tests exercise the real citation presentation.
@MainActor
final class UITestTripSuggestionProvider: TripSuggestionProviding {
    /// A deterministic suggestion replayed for one seeded trip.
    struct Fixture {
        var classification: TripClassification
        var businessPurpose: String?
        var evidence: [TripSuggestionEvidenceItem]
    }

    private var fixtures: [UUID: Fixture] = [:]

    func register(_ fixture: Fixture, for tripID: UUID) {
        fixtures[tripID] = fixture
    }

    var isAvailable: Bool { true }

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        if let fixture = fixtures[request.trip.id] {
            return TripClassificationSuggestion(
                tripID: request.trip.id,
                classification: fixture.classification,
                businessPurpose: fixture.businessPurpose,
                evidence: fixture.evidence,
                generatedAt: Date()
            )
        }
        return TripClassificationSuggestion(
            tripID: request.trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            rationale: "A nearby work appointment",
            evidence: [.calendarEvent(title: "Planning with Jordan")],
            generatedAt: Date()
        )
    }
}
