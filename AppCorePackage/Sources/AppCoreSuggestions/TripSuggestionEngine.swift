import AppCoreEnrichment
import AppCoreModels
import Foundation
import Observation

/// Calendar/contacts permission state as last observed, used to detect
/// changes made in the system Settings app while the app was backgrounded.
public struct SuggestionPermissionSnapshot: Equatable, Sendable {
    public var calendarFullAccess: Bool
    public var contactsAuthorized: Bool

    public init(calendarFullAccess: Bool, contactsAuthorized: Bool) {
        self.calendarFullAccess = calendarFullAccess
        self.contactsAuthorized = contactsAuthorized
    }
}

/// The shared AI trip-suggestion orchestrator: backfill scheduling, in-flight
/// and invalidation tracking, permission reconciliation, candidate selection,
/// the contact index, and (when a persister is injected) disk-cache hydration
/// and fingerprint bookkeeping. Both app models delegate here through
/// read-write forwarders, so this engine is the single source of truth for
/// suggestion state.
///
/// Semantics are the shipped iPhone implementation's, composed with the Mac's
/// race hardenings: generation-stamped in-flight tracking, attempted-version
/// retry memory (a failed generation is skipped until the trip changes,
/// Regenerate is tapped, or the app relaunches), generation-guarded late
/// permission callbacks, and a post-completion scene check before publishing.
@MainActor
@Observable
public final class TripSuggestionEngine {
    public struct Dependencies {
        public var provider: () -> (any TripSuggestionProviding)?
        /// Unclassified trips only — candidate selection, sweeping, and
        /// hydration never look at classified rows.
        public var unclassifiedTrips: () -> [TripSummary]
        /// Nearby drives are used only to infer a stop between reciprocal
        /// trips; no companion-trip details are sent to the model.
        public var nearbyTrips: () -> [TripSummary]
        public var fetchTrip: (UUID) throws -> TripSummary?
        public var businessPurposePresets: () -> [String]
        public var preferences: SuggestionPreferences
        public var localeIdentifier: () -> String
        public var calendarFullAccess: () -> Bool
        public var contactsAuthorized: () -> Bool
        /// Whether contacts permission is still undetermined (never prompted).
        public var contactsPermissionUndetermined: () -> Bool
        public var contactsPermissionRawValue: () -> Int
        public var calendarPermissionUndetermined: () -> Bool
        public var requestContactsAccess: () async -> Bool
        public var requestCalendarAccess: () async -> Bool
        public var contactIndexLoader: () async -> ContactAddressIndex
        public var sceneIsActive: () -> Bool
        /// UI-test runs generate without a real scene-activation event.
        public var bypassSceneGate: Bool
        /// Blocks backfill scheduling entirely (iPhone: a reset in progress).
        public var isSuspended: () -> Bool
        /// Blocks cache hydration (iPhone: before first unlock, so the
        /// placeholder store never creates the suggestions directory).
        public var isProtectedDataUnavailable: () -> Bool
        public var persister: (any SuggestionPersisting)?
        /// Reverts the calendar toggle when the system denies access, through
        /// whatever path the platform uses to write that preference.
        public var onCalendarAccessDenied: () -> Void

        public init(
            provider: @escaping () -> (any TripSuggestionProviding)?,
            unclassifiedTrips: @escaping () -> [TripSummary],
            nearbyTrips: @escaping () -> [TripSummary] = { [] },
            fetchTrip: @escaping (UUID) throws -> TripSummary?,
            businessPurposePresets: @escaping () -> [String],
            preferences: SuggestionPreferences,
            localeIdentifier: @escaping () -> String = { Locale.current.identifier },
            calendarFullAccess: @escaping () -> Bool,
            contactsAuthorized: @escaping () -> Bool,
            contactsPermissionUndetermined: @escaping () -> Bool,
            contactsPermissionRawValue: @escaping () -> Int,
            calendarPermissionUndetermined: @escaping () -> Bool,
            requestContactsAccess: @escaping () async -> Bool,
            requestCalendarAccess: @escaping () async -> Bool,
            contactIndexLoader: @escaping () async -> ContactAddressIndex = {
                await Task.detached { ContactAddressIndex.load() }.value
            },
            sceneIsActive: @escaping () -> Bool,
            bypassSceneGate: Bool = false,
            isSuspended: @escaping () -> Bool = { false },
            isProtectedDataUnavailable: @escaping () -> Bool = { false },
            persister: (any SuggestionPersisting)? = nil,
            onCalendarAccessDenied: @escaping () -> Void = {}
        ) {
            self.provider = provider
            self.unclassifiedTrips = unclassifiedTrips
            self.nearbyTrips = nearbyTrips
            self.fetchTrip = fetchTrip
            self.businessPurposePresets = businessPurposePresets
            self.preferences = preferences
            self.localeIdentifier = localeIdentifier
            self.calendarFullAccess = calendarFullAccess
            self.contactsAuthorized = contactsAuthorized
            self.contactsPermissionUndetermined = contactsPermissionUndetermined
            self.contactsPermissionRawValue = contactsPermissionRawValue
            self.calendarPermissionUndetermined = calendarPermissionUndetermined
            self.requestContactsAccess = requestContactsAccess
            self.requestCalendarAccess = requestCalendarAccess
            self.contactIndexLoader = contactIndexLoader
            self.sceneIsActive = sceneIsActive
            self.bypassSceneGate = bypassSceneGate
            self.isSuspended = isSuspended
            self.isProtectedDataUnavailable = isProtectedDataUnavailable
            self.persister = persister
            self.onCalendarAccessDenied = onCalendarAccessDenied
        }
    }

    public static let freshnessInterval: TimeInterval = 24 * 60 * 60
    public static let backfillBatchLimit = 10

    @ObservationIgnored private let dependencies: Dependencies

    // Observed: the suggestion band renders from these.
    public var tripSuggestions: [UUID: TripClassificationSuggestion] = [:]
    public var contactsEvidencePermissionDenied = false
    public var calendarEvidencePermissionDenied = false

    // Bookkeeping the UI never renders directly.
    @ObservationIgnored public var suggestionFingerprints: [UUID: String] = [:]
    @ObservationIgnored public var suggestionRefreshNeeded: Set<UUID> = []
    @ObservationIgnored public var suggestionsInFlight: [UUID: UInt] = [:]
    @ObservationIgnored private var suggestionProviderTasks: [UUID: Task<TripClassificationSuggestion?, Never>] = [:]
    @ObservationIgnored public private(set) var suggestionGeneration: UInt = 0
    @ObservationIgnored public var suggestionBackfillTask: Task<Void, Never>?
    @ObservationIgnored public var suggestionBackfillRerunRequested = false
    @ObservationIgnored public var suggestionBackfillAttemptedVersions: [UUID: Date] = [:]
    @ObservationIgnored private var suggestionBackfillWorkerID: UUID?
    @ObservationIgnored public var lastSuggestionPermissionSnapshot: SuggestionPermissionSnapshot?
    @ObservationIgnored public var hasHydratedSuggestionCache = false
    @ObservationIgnored public var suggestionCacheHydrationTask: Task<Void, Never>?
    @ObservationIgnored public var suggestionContactIndex: ContactAddressIndex?
    @ObservationIgnored private var suggestionCacheInvalidationGeneration: UInt = 0
    @ObservationIgnored private var suggestionCacheDiskMutationGeneration: UInt = 0
    @ObservationIgnored private var suggestionCacheInvalidationTask: Task<Void, Never>?
    @ObservationIgnored private var contactsPermissionGeneration: UInt = 0
    @ObservationIgnored private var calendarPermissionGeneration: UInt = 0

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        if dependencies.persister == nil {
            hasHydratedSuggestionCache = true
        }
    }

    private var preferences: SuggestionPreferences { dependencies.preferences }

    // MARK: - Evidence availability

    /// Calendar evidence is only usable once the user opted in *and* the
    /// system granted full event access.
    public var calendarEvidenceUsable: Bool {
        preferences.calendarEvidenceEnabled && dependencies.calendarFullAccess()
    }

    /// Contact evidence is usable when the toggle is on and there is either
    /// system contacts access or the user's own card picked in Settings (the
    /// picker needs no permission).
    public var contactEvidenceUsable: Bool {
        preferences.contactEvidenceEnabled
            && (dependencies.contactsAuthorized()
                || preferences.userHomeStreetLine != nil
                || preferences.userWorkStreetLine != nil)
    }

    // MARK: - Generation

    /// Generates and caches a suggestion for one trip. Silently does nothing
    /// unless the feature is on, the provider is available, and the trip is
    /// still unclassified with no fresh suggestion cached or in flight. A
    /// stale disk-hydrated suggestion remains visible if generation fails.
    public func generateSuggestionIfNeeded(for tripID: UUID) async {
        await generateSuggestionIfNeeded(for: tripID, generation: suggestionGeneration)
    }

    private func generateSuggestionIfNeeded(for tripID: UUID, generation: UInt) async {
        guard preferences.aiSuggestionsEnabled,
              suggestionGeneration == generation,
              let provider = dependencies.provider(), provider.isAvailable,
              tripSuggestions[tripID] == nil || suggestionRefreshNeeded.contains(tripID),
              suggestionsInFlight[tripID] == nil else {
            return
        }

        suggestionsInFlight[tripID] = generation
        defer {
            if suggestionsInFlight[tripID] == generation {
                suggestionsInFlight[tripID] = nil
                suggestionProviderTasks[tripID] = nil
            }
        }

        // A prior invalidation owns the disk namespace until its deletion has
        // completed. Waiting here makes remove-then-regenerate deterministic:
        // a successful new save can never be erased by the older task.
        await waitForSuggestionCacheInvalidations()
        guard preferences.aiSuggestionsEnabled, provider.isAvailable, !Task.isCancelled,
              suggestionGeneration == generation,
              tripSuggestions[tripID] == nil || suggestionRefreshNeeded.contains(tripID),
              let trip = try? dependencies.fetchTrip(tripID),
              trip.classification == nil else {
            return
        }
        let invalidationGeneration = suggestionCacheInvalidationGeneration

        let originContactEvidence = await contactEvidence(for: trip.startAddressComponents)
        let destinationContactEvidence = await contactEvidence(for: trip.endAddressComponents)
        // Contact enumeration runs in a detached task and may not observe this
        // worker's cancellation. Re-check every execution gate after those
        // suspension points so an old/background generation cannot start a
        // model request alongside its foreground replacement.
        guard preferences.aiSuggestionsEnabled, provider.isAvailable, !Task.isCancelled,
              suggestionGeneration == generation,
              dependencies.sceneIsActive() || dependencies.bypassSceneGate else {
            return
        }
        let fingerprint = suggestionFingerprint(for: trip)
        let pairedDriveStop = calendarEvidenceUsable
            ? PairedDriveStopFinder.stop(for: trip, among: dependencies.nearbyTrips()) : nil
        let request = TripSuggestionRequest(
            trip: trip,
            businessPurposePresets: dependencies.businessPurposePresets(),
            calendarEvidenceEnabled: calendarEvidenceUsable,
            localeIdentifier: dependencies.localeIdentifier(),
            pairedDriveStop: pairedDriveStop,
            originContactNote: originContactEvidence.note,
            destinationContactNote: destinationContactEvidence.note,
            destinationIsWorkplace: destinationContactEvidence.isWorkplace,
            contactEvidenceEnabled: contactEvidenceUsable,
            originEndpointIdentity: originContactEvidence.identity,
            destinationEndpointIdentity: destinationContactEvidence.identity
        )
        // Own the provider task even for direct per-trip callers. An evidence
        // opt-out must cancel a request suspended before its cloud send, not
        // merely prevent its eventual result from reaching the UI.
        let providerTask = Task { await provider.suggestion(for: request) }
        suggestionProviderTasks[tripID] = providerTask
        let result = await withTaskCancellationHandler {
            await providerTask.value
        } onCancel: {
            providerTask.cancel()
        }
        guard let suggestion = result, suggestion.tripID == tripID else {
            // A stale cache hit intentionally survives a transient model
            // failure or a low-confidence result.
            return
        }
        // An evidence/config invalidation can arrive while the provider is
        // running. Drain its deletion and then re-check both the generation
        // tokens and the live trip before publishing or saving. A result
        // completing after the scene deactivated is discarded too — it was
        // generated for a session the user already left.
        await waitForSuggestionCacheInvalidations()
        guard preferences.aiSuggestionsEnabled, !Task.isCancelled,
              suggestionGeneration == generation,
              invalidationGeneration == suggestionCacheInvalidationGeneration,
              dependencies.sceneIsActive() || dependencies.bypassSceneGate,
              let current = try? dependencies.fetchTrip(tripID),
              current.classification == nil,
              current.updatedAt == trip.updatedAt,
              suggestionFingerprint(for: current) == fingerprint else {
            return
        }
        tripSuggestions[tripID] = suggestion
        suggestionFingerprints[tripID] = fingerprint
        suggestionRefreshNeeded.remove(tripID)
        await dependencies.persister?.save(
            suggestion,
            fingerprint: fingerprint,
            tripUpdatedAt: current.updatedAt
        )
    }

    // MARK: - Backfill scheduling

    /// Sweeps stale cache entries, then serially generates suggestions for
    /// unclassified trips that don't have one. Cheap to call repeatedly —
    /// launch, foreground, and every trip mutation all schedule it.
    public func scheduleSuggestionBackfill() {
        guard !dependencies.isSuspended() else { return }

        // Synchronous sweep so classified/deleted/merged/edited trips drop
        // their suggestion row in the same UI update as the list change.
        sweepInvalidSuggestionState()

        // A cold-launch refresh can be triggered by startup, scene activation,
        // and CloudKit in quick succession. None may start generation until the
        // single disk hydration pass has resolved.
        guard hasHydratedSuggestionCache else { return }

        guard preferences.aiSuggestionsEnabled,
              let provider = dependencies.provider(), provider.isAvailable else {
            return
        }
        // Foreground only: background model requests are unreliable, and the
        // next foreground refresh reschedules anyway.
        guard dependencies.sceneIsActive() || dependencies.bypassSceneGate else { return }
        // Never cancel a running worker: schedule requests fire repeatedly
        // around launch, and each real on-device generation takes seconds —
        // cancel-and-restart starved them all with CancellationErrors. A
        // request that arrives mid-run is honored by the worker rescheduling
        // itself on exit (fresh attempted-set), which is what makes
        // regenerateSuggestions() reach trips this worker already visited.
        guard suggestionBackfillTask == nil else {
            suggestionBackfillRerunRequested = true
            return
        }
        guard nextBackfillCandidate(excluding: []) != nil else { return }

        let workerID = UUID()
        let generation = suggestionGeneration
        suggestionBackfillWorkerID = workerID
        suggestionBackfillTask = Task { [weak self] in
            provider.prewarm()
            // One at a time: the on-device model serves one request per
            // session, and suggestions are not latency-critical. Attempted
            // versions are remembered across runs so a failed generation
            // (guardrail, rate limit) is skipped until the trip changes,
            // Regenerate is tapped, or the app relaunches.
            var attempted: Set<UUID> = []
            while !Task.isCancelled, attempted.count < Self.backfillBatchLimit {
                guard let self,
                      self.suggestionGeneration == generation,
                      self.suggestionBackfillWorkerID == workerID,
                      let tripID = self.nextBackfillCandidate(excluding: attempted) else {
                    break
                }
                attempted.insert(tripID)
                if let sourceVersion = self.dependencies.unclassifiedTrips()
                    .first(where: { $0.id == tripID })?.updatedAt {
                    self.suggestionBackfillAttemptedVersions[tripID] = sourceVersion
                }
                await self.generateSuggestionIfNeeded(for: tripID, generation: generation)
            }
            guard let self else { return }
            // Invalidation cancels and detaches the old worker immediately.
            // Only its current owner may clear the handle; a late cancelled
            // worker must not clear the replacement's handle.
            guard self.suggestionBackfillWorkerID == workerID else { return }
            self.suggestionBackfillTask = nil
            self.suggestionBackfillWorkerID = nil
            // A cancelled worker must never respawn: a reset cancels and
            // awaits this task, and a reschedule from inside that await would
            // outlive the handle the reset is about to nil.
            if !Task.isCancelled, self.suggestionBackfillRerunRequested {
                self.suggestionBackfillRerunRequested = false
                self.scheduleSuggestionBackfill()
            }
        }
    }

    private func nextBackfillCandidate(excluding attempted: Set<UUID>) -> UUID? {
        let eligible = dependencies.unclassifiedTrips().filter {
            !attempted.contains($0.id)
                && suggestionsInFlight[$0.id] == nil
                && suggestionBackfillAttemptedVersions[$0.id] != $0.updatedAt
        }
        // Missing suggestions are more noticeable than an old suggestion that
        // is already on screen, so spend the batch on them first.
        if let missing = eligible
            .filter({ tripSuggestions[$0.id] == nil })
            .max(by: { $0.startDate < $1.startDate }) {
            return missing.id
        }
        return eligible
            .filter { suggestionRefreshNeeded.contains($0.id) }
            .max(by: { $0.startDate < $1.startDate })?
            .id
    }

    // MARK: - Cache hydration

    /// Starts exactly one cache read once persistence is readable. Without a
    /// persister the engine is born hydrated and this is a no-op.
    public func scheduleSuggestionCacheHydrationIfNeeded() {
        guard !dependencies.isProtectedDataUnavailable(),
              !hasHydratedSuggestionCache,
              suggestionCacheHydrationTask == nil else {
            return
        }
        guard let persister = dependencies.persister else {
            hasHydratedSuggestionCache = true
            return
        }

        let expectedFingerprints = preferences.aiSuggestionsEnabled
            ? Dictionary(uniqueKeysWithValues: dependencies.unclassifiedTrips().map { trip in
                (trip.id, suggestionFingerprint(for: trip))
            })
            : [:]
        let invalidationGeneration = suggestionCacheInvalidationGeneration
        suggestionCacheHydrationTask = Task { [weak self] in
            let hits = await persister.load(matching: expectedFingerprints)
            guard let self else { return }
            defer { self.suggestionCacheHydrationTask = nil }
            guard !Task.isCancelled else { return }

            var rejectedFingerprints: [UUID: String] = [:]
            if self.preferences.aiSuggestionsEnabled,
               invalidationGeneration == self.suggestionCacheInvalidationGeneration {
                let unclassified = Dictionary(
                    uniqueKeysWithValues: self.dependencies.unclassifiedTrips().map { ($0.id, $0) }
                )
                for (tripID, hit) in hits {
                    guard let current = unclassified[tripID],
                          self.suggestionFingerprint(for: current) == hit.fingerprint else {
                        rejectedFingerprints[tripID] = hit.fingerprint
                        continue
                    }
                    self.tripSuggestions[tripID] = hit.suggestion
                    self.suggestionFingerprints[tripID] = hit.fingerprint
                    if hit.freshness == .stale {
                        self.suggestionRefreshNeeded.insert(tripID)
                    }
                }
            } else {
                rejectedFingerprints = hits.mapValues(\.fingerprint)
            }
            if !rejectedFingerprints.isEmpty {
                self.enqueueCacheRemoval(entriesMatching: rejectedFingerprints, persister: persister)
            }

            self.hasHydratedSuggestionCache = true
            self.scheduleSuggestionBackfill()
        }
    }

    public func waitForSuggestionCacheHydration() async {
        guard !dependencies.isProtectedDataUnavailable() else { return }
        scheduleSuggestionCacheHydrationIfNeeded()
        await suggestionCacheHydrationTask?.value
    }

    // MARK: - Sweeping and invalidation

    private func sweepInvalidSuggestionState() {
        let unclassifiedTrips = Dictionary(
            uniqueKeysWithValues: dependencies.unclassifiedTrips().map { ($0.id, $0) }
        )
        suggestionBackfillAttemptedVersions = suggestionBackfillAttemptedVersions.filter {
            unclassifiedTrips[$0.key]?.updatedAt == $0.value
        }
        let trackedIDs = Set(tripSuggestions.keys)
            .union(suggestionFingerprints.keys)
            .union(suggestionRefreshNeeded)
        var invalidIDs: Set<UUID> = []
        for tripID in trackedIDs {
            guard let trip = unclassifiedTrips[tripID],
                  let suggestion = tripSuggestions[tripID], suggestion.tripID == tripID,
                  suggestionFingerprints[tripID] == suggestionFingerprint(for: trip) else {
                invalidIDs.insert(tripID)
                continue
            }
            if Date().timeIntervalSince(suggestion.generatedAt) > Self.freshnessInterval {
                suggestionRefreshNeeded.insert(tripID)
            }
        }
        guard !invalidIDs.isEmpty else { return }
        for tripID in invalidIDs {
            tripSuggestions[tripID] = nil
            suggestionFingerprints[tripID] = nil
            suggestionRefreshNeeded.remove(tripID)
        }
        if let persister = dependencies.persister {
            enqueueCacheRemoval(tripIDs: invalidIDs, persister: persister)
        }
    }

    public func suggestionFingerprint(for trip: TripSummary) -> String {
        SuggestionFingerprint.make(
            trip: trip,
            localeIdentifier: dependencies.localeIdentifier(),
            businessPurposePresets: dependencies.businessPurposePresets(),
            calendarEvidenceEnabled: preferences.calendarEvidenceEnabled,
            calendarPermissionGranted: dependencies.calendarFullAccess(),
            contactEvidenceEnabled: preferences.contactEvidenceEnabled,
            contactsPermissionRawValue: dependencies.contactsPermissionRawValue(),
            userCardName: preferences.userCardName,
            userHomeStreetLine: preferences.userHomeStreetLine,
            userHomeCity: preferences.userHomeCity,
            userWorkStreetLine: preferences.userWorkStreetLine,
            userWorkCity: preferences.userWorkCity,
            privateCloudComputeEnabled: preferences.privateCloudComputeEnabled,
            pairedDriveStop: calendarEvidenceUsable
                ? PairedDriveStopFinder.stop(for: trip, among: dependencies.nearbyTrips()) : nil
        )
    }

    /// Drops every cached suggestion and regenerates — for evidence-source
    /// changes that invalidate what the model already produced.
    public func regenerateSuggestions() {
        invalidateAllSuggestions()
        scheduleSuggestionBackfill()
    }

    /// Synchronously clears every displayed/tracked suggestion and schedules
    /// the disposable disk namespace for deletion. The generation counters
    /// also prevent an already-running hydration pass or an in-flight
    /// generation from publishing old inputs.
    public func invalidateAllSuggestions() {
        suggestionCacheInvalidationGeneration &+= 1
        suggestionGeneration &+= 1
        cancelSuggestionWorkers()
        tripSuggestions = [:]
        suggestionFingerprints = [:]
        suggestionRefreshNeeded = []
        suggestionBackfillAttemptedVersions = [:]
        if let persister = dependencies.persister {
            enqueueCacheRemovalAll(persister: persister)
        }
    }

    /// Discards in-flight suggestion work without touching what's on screen
    /// (or clearing it too) — the scene-deactivation and disable paths.
    public func invalidateSuggestionWork(clearSuggestions: Bool) {
        if clearSuggestions {
            invalidateAllSuggestions()
        } else {
            suggestionGeneration &+= 1
            cancelSuggestionWorkers()
        }
    }

    private func cancelSuggestionWorkers() {
        suggestionBackfillTask?.cancel()
        suggestionBackfillTask = nil
        suggestionBackfillWorkerID = nil
        suggestionBackfillRerunRequested = false
        for task in suggestionProviderTasks.values { task.cancel() }
        suggestionProviderTasks = [:]
        suggestionsInFlight = [:]
        suggestionBackfillAttemptedVersions = [:]
    }

    public func waitForSuggestionCacheInvalidations() async {
        while let pending = suggestionCacheInvalidationTask {
            let generation = suggestionCacheDiskMutationGeneration
            await pending.value
            guard generation == suggestionCacheDiskMutationGeneration else {
                continue
            }
            suggestionCacheInvalidationTask = nil
        }
    }

    private func enqueueCacheRemoval(tripIDs: Set<UUID>, persister: any SuggestionPersisting) {
        let previous = suggestionCacheInvalidationTask
        suggestionCacheDiskMutationGeneration &+= 1
        suggestionCacheInvalidationTask = Task {
            await previous?.value
            await persister.remove(tripIDs: tripIDs)
        }
    }

    private func enqueueCacheRemoval(
        entriesMatching fingerprints: [UUID: String],
        persister: any SuggestionPersisting
    ) {
        let previous = suggestionCacheInvalidationTask
        suggestionCacheDiskMutationGeneration &+= 1
        suggestionCacheInvalidationTask = Task {
            await previous?.value
            await persister.remove(entriesMatching: fingerprints)
        }
    }

    private func enqueueCacheRemovalAll(persister: any SuggestionPersisting) {
        let previous = suggestionCacheInvalidationTask
        suggestionCacheDiskMutationGeneration &+= 1
        suggestionCacheInvalidationTask = Task {
            await previous?.value
            try? await persister.removeAll()
        }
    }

    // MARK: - Accept

    /// The staleness-validated lookup both accept flows share: returns the
    /// suggestion only while the trip is still unclassified and its current
    /// fingerprint matches the one the suggestion was generated under. On a
    /// mismatch the stale row is dropped so the band never re-offers it.
    public func validatedSuggestionForAccept(tripID: UUID) -> TripClassificationSuggestion? {
        guard let suggestion = tripSuggestions[tripID] else { return nil }
        guard let current = try? dependencies.fetchTrip(tripID),
              current.classification == nil,
              suggestionFingerprints[tripID] == suggestionFingerprint(for: current) else {
            tripSuggestions[tripID] = nil
            suggestionFingerprints[tripID] = nil
            suggestionRefreshNeeded.remove(tripID)
            return nil
        }
        return suggestion
    }

    // MARK: - Permissions

    /// Supersedes permission callbacks only when the feature or an evidence
    /// source actually changes. Scene inactivity is also produced by the
    /// system permission sheet itself, so ordinary worker cancellation must
    /// not invalidate these generations.
    public func invalidateSuggestionPermissionRequests() {
        contactsPermissionGeneration &+= 1
        calendarPermissionGeneration &+= 1
    }

    /// Detects permission changes made in the system Settings app while
    /// backgrounded (grant or revoke): cached suggestions were generated
    /// under the old permissions, so a change invalidates them.
    public func reconcileSuggestionPermissionsOnForeground() {
        let snapshot = SuggestionPermissionSnapshot(
            calendarFullAccess: dependencies.calendarFullAccess(),
            contactsAuthorized: dependencies.contactsAuthorized()
        )
        defer { lastSuggestionPermissionSnapshot = snapshot }
        guard let previous = lastSuggestionPermissionSnapshot, previous != snapshot else { return }
        if previous.contactsAuthorized != snapshot.contactsAuthorized {
            suggestionContactIndex = nil
            contactsEvidencePermissionDenied = preferences.aiSuggestionsEnabled
                && !snapshot.contactsAuthorized
                && !dependencies.contactsPermissionUndetermined()
        }
        if previous.calendarFullAccess != snapshot.calendarFullAccess {
            calendarEvidencePermissionDenied = preferences.calendarEvidenceEnabled
                && !snapshot.calendarFullAccess
        }
        regenerateSuggestions()
    }

    /// Runs the platform's contacts permission flow when Trip Suggestions
    /// turns on. Late callbacks are generation-guarded: a result arriving
    /// after the user re-toggled the feature or evidence source is ignored.
    public func requestContactsAccessForSuggestions() {
        contactsPermissionGeneration &+= 1
        let generation = contactsPermissionGeneration
        if dependencies.contactsAuthorized() {
            contactsEvidencePermissionDenied = false
            return
        }
        guard dependencies.contactsPermissionUndetermined() else {
            contactsEvidencePermissionDenied = true
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.dependencies.requestContactsAccess()
            guard self.contactsPermissionGeneration == generation,
                  self.preferences.aiSuggestionsEnabled,
                  self.preferences.contactEvidenceEnabled else { return }
            self.contactsEvidencePermissionDenied = !granted
            if granted {
                // Suggestions generated while the prompt was up carry no
                // contact notes; the grant invalidates them.
                self.suggestionContactIndex = nil
                self.regenerateSuggestions()
            }
        }
    }

    /// Runs the platform's calendar permission flow after the user enables
    /// the evidence toggle. Denial reverts the toggle (via the injected hook)
    /// so the UI never claims evidence it cannot read.
    public func requestCalendarAccessForSuggestions() {
        calendarPermissionGeneration &+= 1
        let generation = calendarPermissionGeneration
        if dependencies.calendarFullAccess() {
            calendarEvidencePermissionDenied = false
            return
        }
        guard dependencies.calendarPermissionUndetermined() else {
            calendarEvidencePermissionDenied = true
            dependencies.onCalendarAccessDenied()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.dependencies.requestCalendarAccess()
            guard self.calendarPermissionGeneration == generation,
                  self.preferences.aiSuggestionsEnabled,
                  self.preferences.calendarEvidenceEnabled else { return }
            self.calendarEvidencePermissionDenied = !granted
            if granted {
                // Suggestions generated while the prompt was up are
                // calendar-free; the grant invalidates them.
                self.regenerateSuggestions()
            } else {
                self.dependencies.onCalendarAccessDenied()
            }
        }
    }

    // MARK: - Contact notes

    struct EndpointContactEvidence: Equatable, Sendable {
        var note: String?
        var isWorkplace: Bool
        var identity: TripSuggestionEndpointIdentity = .other

        static let none = EndpointContactEvidence(note: nil, isWorkplace: false)
    }

    /// Prompt note identifying an endpoint: the user's own home/work (from
    /// the My Card pick) first, then any contact whose postal address matches.
    public func contactNote(for components: TripEndpointAddressComponents?) async -> String? {
        await contactEvidence(for: components).note
    }

    func contactEvidence(for components: TripEndpointAddressComponents?) async -> EndpointContactEvidence {
        guard preferences.aiSuggestionsEnabled,
              preferences.contactEvidenceEnabled,
              let components else { return .none }
        guard let key = ContactAddressIndex.key(streetLine: components.streetLine, city: components.city) else {
            return .none
        }
        if key == ContactAddressIndex.key(
            streetLine: preferences.userHomeStreetLine,
            city: preferences.userHomeCity
        ) {
            return EndpointContactEvidence(
                note: "the user's home address", isWorkplace: false, identity: .userHome
            )
        }
        if key == ContactAddressIndex.key(
            streetLine: preferences.userWorkStreetLine,
            city: preferences.userWorkCity
        ) {
            return EndpointContactEvidence(
                note: "the user's work address", isWorkplace: true, identity: .userWorkplace
            )
        }
        guard dependencies.contactsAuthorized() else { return .none }
        if suggestionContactIndex == nil {
            // Enumerating the address book blocks; build off-main once per
            // launch.
            suggestionContactIndex = await dependencies.contactIndexLoader()
        }
        guard let match = suggestionContactIndex?.match(for: components) else { return .none }
        return EndpointContactEvidence(note: match.note, isWorkplace: match.isWorkplace)
    }
}
