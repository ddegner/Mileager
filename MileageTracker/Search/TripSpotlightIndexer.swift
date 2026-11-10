import AppCore
import Foundation
import os

/// Keeps the Spotlight index in sync with the trip store so Siri and system
/// search can surface trips. Event-driven donations arrive via
/// `TripStoreChangeObserver`; manifest-diff reconciles cover paths that bypass
/// `TripStore` (CloudKit imports and retired-record maintenance) and heal missed
/// or failed donations. All operations are serialized on one task chain so a
/// reconcile can never interleave with an event donation.
@MainActor
final class TripSpotlightIndexer {
    private static let donationBatchSize = 200
    private static let reconcileDebounce: Duration = .seconds(2)
    /// Bump when the semantic shape or baked snippet text changes so an app
    /// update re-donates unchanged trips instead of leaving stale Spotlight
    /// records behind.
    private static let tripIndexContentVersion = "trip-v2-duration"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.localfirst.MileageTracker",
        category: "TripSpotlightIndexer"
    )

    private let index: any SpotlightIndexing
    private let isEnabled: () -> Bool
    /// Resolves a trip's vehicle name for the Siri/Spotlight projection. Default
    /// returns nil so tests and the pre-vehicle path donate without one.
    private let vehicleName: @MainActor (UUID?) -> String?
    private var manifest: TripIndexManifest
    private var monthManifest: MonthReportIndexManifest
    private var workChain: Task<Void, Never>?
    private var pendingReconcile: Task<Void, Never>?
    private var pendingMonthRefresh: Task<Void, Never>?

    /// Month-report donations aggregate every trip in a month, so refreshing
    /// them needs a full fetch plus the model's formatting state (unit, rate,
    /// currency); both arrive as closures once the stores are wired. While
    /// nil, month maintenance is off and only trips are donated.
    struct MonthReportSource {
        var fetchAll: @MainActor () throws -> [TripSummary]
        var project: @MainActor ([TripSummary]) -> [MonthlyMileageReportEntity]
    }

    var monthReportSource: MonthReportSource?
    /// Test seam; production keeps the coalescing window so bulk operations
    /// (merge, bulk classify) recompute months once. `.zero` enqueues
    /// synchronously so tests can drain deterministically.
    var monthRefreshDebounce: Duration = TripSpotlightIndexer.reconcileDebounce

    init(
        index: any SpotlightIndexing = SystemSpotlightIndex(),
        isEnabled: @escaping () -> Bool,
        vehicleName: @escaping @MainActor (UUID?) -> String? = { _ in nil },
        manifestURL: URL = TripIndexManifest.defaultFileURL(),
        monthManifestURL: URL = MonthReportIndexManifest.defaultFileURL()
    ) {
        self.index = index
        self.isEnabled = isEnabled
        self.vehicleName = vehicleName
        manifest = TripIndexManifest(fileURL: manifestURL)
        monthManifest = MonthReportIndexManifest(fileURL: monthManifestURL)
    }

    private func projectedEntity(_ trip: TripSummary) -> TripAppEntity {
        TripAppEntity(trip, vehicleName: vehicleName(trip.vehicleID))
    }

    /// Not-a-Drive trips stay out of system search; unclassified
    /// trips are included deliberately — "classify my last trip" is the
    /// headline Siri flow.
    static func shouldIndex(_ trip: TripSummary) -> Bool {
        trip.classification != .notADrive
    }

    func noteChange(_ change: TripChangeSet) {
        guard isEnabled(), !change.isEmpty else { return }
        var deletions = change.deletedIDs
        var donations: [TripSummary] = []
        for trip in change.upserted {
            if Self.shouldIndex(trip) {
                donations.append(trip)
            } else {
                deletions.append(trip.id)
            }
        }
        enqueue { [weak self] in
            await self?.apply(donations: donations, deletions: deletions)
        }
        scheduleMonthRefresh()
    }

    /// Any trip change can move a month's totals, and month donations need a
    /// full fetch, so refreshes coalesce behind a debounce instead of running
    /// per change set.
    private func scheduleMonthRefresh() {
        guard isEnabled(), monthReportSource != nil else { return }
        let refresh: @MainActor () -> Void = { [weak self] in
            self?.enqueue { [weak self] in
                guard let self, let source = self.monthReportSource else { return }
                guard let allTrips = try? source.fetchAll() else { return }
                await self.refreshMonthReports(allTrips: allTrips)
            }
        }
        if monthRefreshDebounce == .zero {
            refresh()
            return
        }
        pendingMonthRefresh?.cancel()
        pendingMonthRefresh = Task { [debounce = monthRefreshDebounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    /// Diffs the store against the manifest and repairs the index. Callers are
    /// responsible for never scheduling this while the store is unavailable
    /// (before first unlock) — an empty fallback store would read as "delete
    /// every donated trip".
    func scheduleReconcile(fetchAll: @escaping @MainActor () throws -> [TripSummary]) {
        guard isEnabled() else { return }
        pendingReconcile?.cancel()
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: Self.reconcileDebounce)
            guard !Task.isCancelled else { return }
            self?.enqueue { [weak self] in
                await self?.reconcile(fetchAll: fetchAll)
            }
        }
    }

    /// Forgets donation history and re-donates everything on the next
    /// reconcile. For content changes no trip row records — vehicle rename,
    /// primary-vehicle change — where `updatedAt` diffing can't see the
    /// staleness. Unit/locale changes are covered by the format stamp instead.
    func invalidateAndReconcile(fetchAll: @escaping @MainActor () throws -> [TripSummary]) {
        guard isEnabled() else { return }
        enqueue { [weak self] in
            self?.manifest.clear()
            self?.monthManifest.clear()
        }
        scheduleReconcile(fetchAll: fetchAll)
    }

    func setEnabled(_ enabled: Bool, fetchAll: @escaping @MainActor () throws -> [TripSummary]) {
        if enabled {
            enqueue { [weak self] in
                await self?.reconcile(fetchAll: fetchAll)
            }
        } else {
            pendingReconcile?.cancel()
            pendingMonthRefresh?.cancel()
            enqueue { [weak self] in
                await self?.eraseIndex()
            }
        }
    }

    /// Refresh specific system-index entries. A failed fetch is not a deletion.
    func reindex(ids: [UUID], fetch: @escaping @MainActor (UUID) throws -> TripSummary?) {
        guard isEnabled() else { return }
        enqueue { [weak self] in
            guard let self, self.isEnabled() else { return }
            var donations: [TripSummary] = []
            var deletions: [UUID] = []
            for id in ids {
                do {
                    if let trip = try fetch(id), Self.shouldIndex(trip) {
                        donations.append(trip)
                    } else {
                        deletions.append(id)
                    }
                } catch {
                    Self.logger.error("Reindex fetch failed: \(error.localizedDescription)")
                }
            }
            await self.apply(donations: donations, deletions: deletions)
        }
    }

    /// Spotlight may have lost entries that our manifest still considers current.
    func reindexAll(fetchAll: @escaping @MainActor () throws -> [TripSummary]) {
        guard isEnabled() else { return }
        enqueue { [weak self] in
            guard let self, self.isEnabled(), let trips = try? fetchAll() else { return }
            let indexable = trips.filter(Self.shouldIndex)
            let ids = Set(indexable.map(\.id))
            let removed = Set(self.manifest.entries.keys).subtracting(ids)
                .union(trips.filter { !Self.shouldIndex($0) }.map(\.id))
            await self.apply(donations: indexable, deletions: Array(removed))
        }
    }

    /// System reindex callbacks must finish their queued donation work.
    func drain() async { await drainForTesting() }

    /// Awaits all queued work; used by tests.
    func drainForTesting() async {
        while let chain = workChain {
            await chain.value
            if workChain == chain {
                workChain = nil
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = workChain
        workChain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Ensures the manifest's format stamp matches the current unit/locale.
    /// On mismatch every recorded donation was formatted with stale settings,
    /// so the records are dropped and the next reconcile re-donates them.
    private func adoptCurrentFormatStamp() {
        let stamp = Self.currentFormatStamp()
        if manifest.formatStamp != stamp {
            manifest.resetForFormatChange(stamp)
        }
    }

    private func apply(donations: [TripSummary], deletions: [UUID]) async {
        adoptCurrentFormatStamp()
        // Deletions first: a merge emits its source deletions alongside the
        // merged upsert, and the old rows must not outlive the new one.
        if !deletions.isEmpty {
            do {
                try await index.delete(ids: deletions)
                manifest.recordDeleted(deletions)
            } catch {
                Self.logger.error("Spotlight delete failed: \(error.localizedDescription)")
            }
        }
        for batch in donations.chunked(into: Self.donationBatchSize) {
            do {
                try await index.index(batch.map(projectedEntity))
                manifest.recordDonated(batch.map { ($0.id, $0.updatedAt) })
            } catch {
                Self.logger.error("Spotlight donation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fingerprint of the semantic schema plus everything baked into donated
    /// snippet text besides the trip itself. When it changes, every donated
    /// item is stale even though no trip's `updatedAt` moved.
    static func currentFormatStamp() -> String {
        "\(tripIndexContentVersion)|\(TripAppEntity.displayUnit.rawValue)|\(Locale.current.identifier)"
    }

    private func reconcile(fetchAll: @MainActor () throws -> [TripSummary]) async {
        guard isEnabled() else { return }
        let allTrips: [TripSummary]
        do {
            allTrips = try fetchAll()
        } catch {
            // A store that cannot be read must not be mistaken for an empty
            // one; leave the index alone and let the next reconcile retry.
            Self.logger.error("Reconcile fetch failed: \(error.localizedDescription)")
            return
        }
        adoptCurrentFormatStamp()
        let indexable = allTrips.filter(Self.shouldIndex)
        let indexableIDs = Set(indexable.map(\.id))
        let stale = indexable.filter { !manifest.isCurrent(id: $0.id, updatedAt: $0.updatedAt) }
        let removedIDs = manifest.entries.keys.filter { !indexableIDs.contains($0) }
        await apply(donations: stale, deletions: Array(removedIDs))
        await refreshMonthReports(allTrips: allTrips)
    }

    /// Projects month-report entities from the full trip set and diffs their
    /// content digests against the month manifest, so only months whose
    /// donated text changed get re-donated and vanished months get deleted.
    private func refreshMonthReports(allTrips: [TripSummary]) async {
        guard let source = monthReportSource else { return }
        let reports = source.project(allTrips)
        let currentIDs = Set(reports.map(\.id))
        let removed = monthManifest.digests.keys.filter { !currentIDs.contains($0) }
        if !removed.isEmpty {
            do {
                try await index.delete(reportIDs: removed)
                monthManifest.recordDeleted(removed)
            } catch {
                Self.logger.error("Spotlight month delete failed: \(error.localizedDescription)")
            }
        }
        let stale = reports.filter { !monthManifest.isCurrent(id: $0.id, digest: $0.indexDigest) }
        if !stale.isEmpty {
            do {
                try await index.index(reports: stale)
                monthManifest.recordDonated(stale.map { ($0.id, $0.indexDigest) })
            } catch {
                Self.logger.error("Spotlight month donation failed: \(error.localizedDescription)")
            }
        }
    }

    private func eraseIndex() async {
        do {
            try await index.deleteAll()
            manifest.clear()
            monthManifest.clear()
        } catch {
            Self.logger.error("Spotlight erase failed: \(error.localizedDescription)")
        }
    }
}

extension TripSpotlightIndexer: TripStoreChangeObserver {
    nonisolated func tripStoreDidChange(_ change: TripChangeSet) {
        Task { @MainActor in
            self.noteChange(change)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
