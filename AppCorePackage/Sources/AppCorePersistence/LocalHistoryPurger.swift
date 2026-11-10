import CoreData
import Foundation
import SQLite3
import os

/// Deletes the Local store's persistent history, which nothing consumes.
///
/// History tracking stays enabled on the Local store (the App Intents stack
/// opens the same files with its own coordinator, and mixed store options are
/// a Core Data hazard), so capture writes it thousands of rows per drive.
/// Without a purge it grows without bound — a field device reached 1.4M
/// transactions / 3.8M change rows in ten weeks. The Cloud store's history is
/// never touched: `NSPersistentCloudKitContainer` owns its lifecycle, and
/// `PersistentHistoryMonitor` reads it for sync detection.
///
/// Deletion is sliced (one bounded background transaction per slice, with a
/// yield between slices) so the first purge of a large backlog never holds the
/// write lock long enough to starve the 1 Hz capture writes, which tolerate a
/// 5 s SQLite busy timeout. The loop is oldest-first and re-derives the oldest
/// transaction each pass, so an interrupted purge resumes for free on the next
/// launch. The store file does not shrink (no vacuum — rewriting the whole
/// file under lock would recreate the very contention this avoids); freed
/// pages are recycled, so the file simply stops growing.
@MainActor
public final class LocalHistoryPurger {
    /// Backstop against a pathological loop; a decade of backlog fits well
    /// under it at one-day slices.
    private static let maximumSlicesPerRun = 400

    private let sliceLength: TimeInterval
    private let interSliceDelay: Duration
    private let initialDelay: Duration
    private let logger = Logger(
        subsystem: "com.daviddegner.MileageTracker",
        category: "LocalHistoryPurger"
    )
    private weak var scheduledController: PersistenceController?
    private var purgeTask: Task<Void, Never>?

    public init(
        sliceLength: TimeInterval = 86_400,
        interSliceDelay: Duration = .milliseconds(100),
        initialDelay: Duration = .seconds(3)
    ) {
        self.sliceLength = sliceLength
        self.interSliceDelay = interSliceDelay
        self.initialDelay = initialDelay
    }

    /// Schedules one background purge per `PersistenceController` instance.
    /// Scheduling for a new controller (e.g. the post-unlock reload) cancels
    /// the prior task. Returns false when this controller is already covered.
    @discardableResult
    public func schedulePurgeIfNeeded(on persistence: PersistenceController) -> Bool {
        if scheduledController === persistence {
            return false
        }
        scheduledController = persistence
        purgeTask?.cancel()
        purgeTask = Task(priority: .utility) { [weak self, weak persistence] in
            guard let self else { return }
            do {
                try await Task.sleep(for: initialDelay)
            } catch {
                return
            }
            // Re-upgrade after the delay: a swapped-out controller (reset,
            // protected-data reload) must not be revived just to purge it.
            guard let persistence, scheduledController === persistence else { return }
            do {
                let slices = try await purgeAllLocalHistory(on: persistence)
                if slices > 0 {
                    logger.info("Purged Local-store history in \(slices) slice(s)")
                }
            } catch is CancellationError {
            } catch {
                // A purge failure must never surface as an app error; the next
                // launch retries from wherever this run stopped.
                logger.error(
                    "Local history purge failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return true
    }

    /// Deletes all Local-store history older than the moment this call starts,
    /// in slices. Returns the number of delete slices executed. No-ops (0)
    /// when the controller has no SQLite Local store (in-memory placeholders,
    /// cloud-only scope). Awaitable directly for tests.
    @discardableResult
    public func purgeAllLocalHistory(on persistence: PersistenceController) async throws -> Int {
        // Rows written after this point are left for the next run; otherwise
        // 1 Hz capture writes would keep the loop chasing a moving tail.
        let cutoff = Date()
        let worker = SliceWorker(persistence: persistence, sliceLength: sliceLength)
        var slices = 0
        while slices < Self.maximumSlicesPerRun {
            try Task.checkCancellation()
            guard try await worker.deleteOldestSlice(cutoff: cutoff) else {
                return slices
            }
            slices += 1
            try await Task.sleep(for: interSliceDelay)
        }
        logger.error("Local history purge stopped at the slice backstop; resuming next launch")
        return slices
    }
}

/// Runs the per-slice background work. Mirrors `RetiredTripMaintenance`'s
/// shape: the wrapper is `@unchecked Sendable` so a main-actor caller can
/// await work that only touches the controller's thread-safe
/// `performBackgroundTask` surface.
private final class SliceWorker: @unchecked Sendable {
    private let persistence: PersistenceController
    private let sliceLength: TimeInterval

    init(persistence: PersistenceController, sliceLength: TimeInterval) {
        self.persistence = persistence
        self.sliceLength = sliceLength
    }

    /// One bounded slice: find the oldest Local-store transaction before
    /// `cutoff` and delete up to `sliceLength` past it. Returns false when no
    /// such transaction remains (done).
    func deleteOldestSlice(cutoff: Date) async throws -> Bool {
        let sliceLength = self.sliceLength
        return try await persistence.performBackgroundTask(name: "LocalHistoryPurge") { context in
            // NSPersistentStore is not Sendable; re-derive it inside the block.
            guard let localStore = context.persistentStoreCoordinator?.persistentStores.first(where: {
                $0.configurationName == PersistenceController.localConfigurationName
            }), localStore.type == NSSQLiteStoreType,
                  let storeURL = localStore.url, storeURL.isFileURL else {
                return false
            }

            // Finding the oldest transaction through the history-fetch API is a
            // trap: NSPersistentHistoryChangeRequest ignores the attached fetch
            // request's fetchLimit and materializes the ENTIRE backlog —
            // gigabytes of transaction objects on a 1.4M-row field store, which
            // froze launch and got build 76 jetsammed on 2026-08-27. Read the
            // one number we need directly, the way SQLiteFetchIndexMaintenance
            // already reads these files.
            guard let oldestReference = Self.oldestTransactionTimestamp(at: storeURL) else {
                return false
            }
            let oldest = Date(timeIntervalSinceReferenceDate: oldestReference)
            guard oldest < cutoff else {
                return false
            }

            let deleteBefore = min(oldest.addingTimeInterval(sliceLength), cutoff)
            let deletion = NSPersistentHistoryChangeRequest.deleteHistory(before: deleteBefore)
            deletion.affectedStores = [localStore]
            _ = try context.execute(deletion)
            return true
        }
    }

    /// Reads `MIN(ZTIMESTAMP)` (Core Data reference-date seconds) from the
    /// history transaction table via a read-only SQLite connection. Returns
    /// nil — treated as "nothing to purge", never an error — when the store is
    /// unreadable, the table is absent, or it is empty.
    private static func oldestTransactionTimestamp(at storeURL: URL) -> Double? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_exec(database, "PRAGMA busy_timeout = 5000", nil, nil, nil)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT MIN(ZTIMESTAMP) FROM ATRANSACTION",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, 0)
    }
}
