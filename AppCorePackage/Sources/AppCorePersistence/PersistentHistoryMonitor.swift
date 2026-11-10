import CoreData
import Foundation
import os

/// Drains CloudKit persistent history and reports foreign changes — the sync
/// core shared by the iPhone's `SyncCoordinator` and the Mac's
/// `MacSyncCoordinator`, which keep only platform policy (enablement gating,
/// initial-import waiting, legacy-token migration) around this monitor.
///
/// `NSPersistentStoreRemoteChange` fires for local saves too, so notifications
/// are coalesced (1.5 s debounce) and checked against persistent history: only
/// transactions from a foreign author trigger `onForeignChange`. Foreign
/// transactions advance the saved token only after foreign maintenance
/// succeeds, so a failed pass retries the same CloudKit import later.
///
/// Token policy on history-fetch failure: a fetch after the saved token that
/// throws falls back to a full no-token replay, and the saved token is cleared
/// only after that replay succeeds — a transient store failure can never erase
/// progress. (This is the hardened Mac behavior; the pre-extraction iPhone
/// coordinator cleared the token before the replay was known to work.)
@MainActor
public final class PersistentHistoryMonitor {
    private let logger: Logger
    private let historyTokens: PersistentHistoryTokenStore
    private var remoteStoreChangeObserver: NSObjectProtocol?
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskNeedsRerun = false
    private var remoteChangeGeneration: UInt = 0
    private weak var observedPersistence: PersistenceController?
    private var onForeignChange: (@MainActor () -> Void)?
    private var onProcessingError: (@MainActor (Error) -> Void)?
    private let foreignMaintenance: @MainActor (PersistenceController) async throws -> Void
    private let maintenanceRetryDelays: [Duration]

    /// Test seam: SQLite cannot be made to throw from a history fetch on
    /// demand, and the token policy above is exactly about fetch failures.
    package var fetchHistoryOverride: (
        (NSPersistentHistoryToken?, NSManagedObjectContext) throws -> [NSPersistentHistoryTransaction]?
    )?

    public init(
        containerIdentifier: String,
        tokenKeyPrefix: String,
        defaults: UserDefaults = .standard,
        maintenanceRetryDelays: [Duration] = [
            .seconds(1),
            .seconds(3),
            .seconds(10)
        ],
        loggerCategory: String = "PersistentHistoryMonitor",
        foreignMaintenance: @escaping @MainActor (PersistenceController) async throws -> Void = { persistence in
            _ = try await RetiredTripMaintenance(persistence: persistence).run()
            _ = try await PreferenceDuplicateResolver(persistence: persistence).reconcile()
        }
    ) {
        logger = Logger(
            subsystem: "com.daviddegner.MileageTracker",
            category: loggerCategory
        )
        historyTokens = PersistentHistoryTokenStore(
            defaults: defaults,
            keyPrefix: tokenKeyPrefix,
            containerIdentifier: containerIdentifier
        )
        self.maintenanceRetryDelays = maintenanceRetryDelays
        self.foreignMaintenance = foreignMaintenance
    }

    /// Calls `onForeignChange` on the main actor when the store reports a
    /// change that came from outside the app (a CloudKit import, not one of
    /// our own saves). Re-observing (e.g. after the locked-launch store is
    /// swapped for the real one) drops the prior observer and any scheduled
    /// pass so a dead observer can never fire for the old store.
    public func observe(
        on persistence: PersistenceController,
        onForeignChange: @MainActor @escaping () -> Void,
        onProcessingError: (@MainActor (Error) -> Void)? = nil
    ) {
        remoteChangeGeneration &+= 1
        stopObserving()
        observedPersistence = persistence
        self.onForeignChange = onForeignChange
        self.onProcessingError = onProcessingError
        remoteStoreChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRemoteProcessing()
            }
        }
    }

    public func stopObserving() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingTaskNeedsRerun = false
        if let remoteStoreChangeObserver {
            NotificationCenter.default.removeObserver(remoteStoreChangeObserver)
            self.remoteStoreChangeObserver = nil
        }
    }

    /// Drains history without waiting for a push. Launch and foreground
    /// activation use this as the missed-silent-push fallback.
    public func checkForRemoteChanges() {
        scheduleRemoteProcessing(delay: false)
    }

    private func scheduleRemoteProcessing(delay: Bool = true) {
        guard pendingTask == nil else {
            pendingTaskNeedsRerun = true
            return
        }
        let generation = remoteChangeGeneration
        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if remoteChangeGeneration == generation {
                    pendingTask = nil
                }
            }
            var nextDelay: Duration? = delay ? .seconds(1.5) : nil
            var maintenanceRetryIndex = 0
            repeat {
                guard remoteChangeGeneration == generation else { return }
                pendingTaskNeedsRerun = false
                if let delay = nextDelay {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    nextDelay = nil
                }
                guard !Task.isCancelled,
                      remoteChangeGeneration == generation,
                      let persistence = observedPersistence else { return }
                switch await processingResult(in: persistence) {
                case .processedForeignTransactions:
                    maintenanceRetryIndex = 0
                    guard !Task.isCancelled, remoteChangeGeneration == generation else { return }
                    onForeignChange?()
                case .noForeignTransactions:
                    maintenanceRetryIndex = 0
                case .maintenanceFailed:
                    guard maintenanceRetryIndex < maintenanceRetryDelays.count else {
                        continue
                    }
                    nextDelay = maintenanceRetryDelays[maintenanceRetryIndex]
                    maintenanceRetryIndex += 1
                    pendingTaskNeedsRerun = true
                }
            } while pendingTaskNeedsRerun
                && !Task.isCancelled
                && remoteChangeGeneration == generation
        }
    }

    /// Processes remote history once, outside the observer path (startup
    /// drains). Foreign transactions only advance the saved token after
    /// foreign maintenance succeeds.
    @discardableResult
    public func processForeignTransactions(in persistence: PersistenceController) async -> Bool {
        await processingResult(in: persistence) == .processedForeignTransactions
    }

    private enum ProcessingResult: Equatable {
        case noForeignTransactions
        case processedForeignTransactions
        case maintenanceFailed
    }

    private func processingResult(in persistence: PersistenceController) async -> ProcessingResult {
        guard let inspection = inspectTransactions(in: persistence) else {
            return .noForeignTransactions
        }
        guard inspection.hasForeignTransactions else {
            historyTokens.save(inspection.newestToken, for: persistence)
            return .noForeignTransactions
        }
        do {
            try await foreignMaintenance(persistence)
            historyTokens.save(inspection.newestToken, for: persistence)
        } catch {
            logger.error(
                "Persistent-history reconciliation failed; token retained for retry: \(error.localizedDescription, privacy: .public)"
            )
            onProcessingError?(error)
            return .maintenanceFailed
        }
        return .processedForeignTransactions
    }

    private struct HistoryInspection {
        var hasForeignTransactions: Bool
        var newestToken: NSPersistentHistoryToken
    }

    private func inspectTransactions(in persistence: PersistenceController) -> HistoryInspection? {
        let context = persistence.container.viewContext
        let savedToken = historyTokens.token(for: persistence)
        let transactions: [NSPersistentHistoryTransaction]?
        do {
            transactions = try fetchTransactions(after: savedToken, in: context)
        } catch {
            logger.error(
                "Persistent-history fetch failed after saved token: \(error.localizedDescription, privacy: .public)"
            )
            guard savedToken != nil else {
                onProcessingError?(error)
                return nil
            }
            do {
                let replay = try fetchTransactions(after: nil, in: context)
                // Clear the token only after a no-token replay succeeds. A
                // transient store failure therefore cannot erase progress.
                // Foreign maintenance is idempotent, and the new token is
                // committed only after it succeeds, so the replay is safe.
                historyTokens.clear(for: persistence)
                transactions = replay
            } catch {
                logger.error(
                    "Persistent-history replay without token also failed: \(error.localizedDescription, privacy: .public)"
                )
                onProcessingError?(error)
                return nil
            }
        }
        guard let transactions,
              !transactions.isEmpty,
              let newestToken = transactions.last?.token else {
            return nil
        }
        return HistoryInspection(
            hasForeignTransactions: transactions.contains {
                $0.author != PersistenceController.appTransactionAuthor
            },
            newestToken: newestToken
        )
    }

    private func fetchTransactions(
        after token: NSPersistentHistoryToken?,
        in context: NSManagedObjectContext
    ) throws -> [NSPersistentHistoryTransaction]? {
        if let fetchHistoryOverride {
            return try fetchHistoryOverride(token, context)
        }
        // Only the Cloud store's history matters here — foreign transactions
        // are CloudKit imports, and they land in the Cloud store. The Local
        // store is written thousands of times per drive, so an unscoped fetch
        // walks millions of irrelevant capture-churn rows on this (main-queue)
        // context; with no saved token that full replay could take minutes and
        // was the field launch-freeze bug.
        guard let cloudStore = context.persistentStoreCoordinator?.persistentStores.first(where: {
            $0.configurationName == PersistenceController.cloudConfigurationName
        }), cloudStore.type == NSSQLiteStoreType else {
            // No SQLite cloud store (the locked-launch in-memory placeholder,
            // previews): in-memory stores record no history, so there is
            // nothing to drain. Never fall back to an unscoped fetch.
            return []
        }
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        request.affectedStores = [cloudStore]
        guard let result = try context.execute(request) as? NSPersistentHistoryResult else {
            return nil
        }
        return result.result as? [NSPersistentHistoryTransaction]
    }
}
