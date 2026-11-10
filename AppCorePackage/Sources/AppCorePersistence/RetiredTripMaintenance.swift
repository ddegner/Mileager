import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Removes persisted state left by retired trip features.
///
/// Older app versions can continue syncing archived trips and the former
/// possible-duplicate attention reason, so this maintenance runs at launch and
/// after foreign imports. All work is performed on a private context.
public final class RetiredTripMaintenance: @unchecked Sendable {
    /// Kept only at the migration boundary so the retired duplicate policy does
    /// not remain part of active trip-review behavior.
    static let retiredPossibleDuplicateAttentionReason = "Possible duplicate found after sync"

    public struct Result: Equatable, Sendable {
        public var deletedArchivedTripRows: Int
        public var clearedRetiredAttentionRows: Int

        public init(
            deletedArchivedTripRows: Int,
            clearedRetiredAttentionRows: Int
        ) {
            self.deletedArchivedTripRows = deletedArchivedTripRows
            self.clearedRetiredAttentionRows = clearedRetiredAttentionRows
        }
    }

    private let persistence: PersistenceController

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    @discardableResult
    public func run() async throws -> Result {
        try await persistence.performBackgroundTask(name: "RetiredTripMaintenance") { context in
            try Self.run(in: context)
        }
    }

    @discardableResult
    static func run(in context: NSManagedObjectContext) throws -> Result {
        let deletedArchivedTripRows = try deleteArchivedTrips(in: context)
        let clearedRetiredAttentionRows = try clearRetiredDuplicateAttention(in: context)
        return Result(
            deletedArchivedTripRows: deletedArchivedTripRows,
            clearedRetiredAttentionRows: clearedRetiredAttentionRows
        )
    }

    /// Permanently deletes physical archived rows.
    ///
    /// Dependents are keyed by logical UUID rather than by a Core Data
    /// relationship. If an active physical revision of that UUID survives, its
    /// fees, samples, and enrichment attempts must survive with it. The cascade
    /// therefore runs only when every physical revision is archived.
    private static func deleteArchivedTrips(in context: NSManagedObjectContext) throws -> Int {
        let archivedRequest = TripEntity.fetchRequest()
        archivedRequest.predicate = NSPredicate(format: "isArchived == YES")
        let archivedRows = try context.fetch(archivedRequest)
        guard !archivedRows.isEmpty else { return 0 }

        var archivedByID: [UUID: [TripEntity]] = [:]
        for trip in archivedRows {
            guard let id = trip.id else {
                context.delete(trip)
                continue
            }
            archivedByID[id, default: []].append(trip)
        }

        for (id, archivedCopies) in archivedByID {
            let allCopiesRequest = TripEntity.fetchRequest()
            allCopiesRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let allCopies = try context.fetch(allCopiesRequest)
            if allCopies.contains(where: { !$0.isArchived }) {
                archivedCopies.forEach(context.delete)
            } else {
                try TripCascadeDelete.delete(allCopies, tripID: id, in: context)
            }
        }
        return archivedRows.count
    }

    /// Removes only the retired possible-duplicate reason, preserving every
    /// still-actionable capture reason and deriving the status from current
    /// classification policy.
    private static func clearRetiredDuplicateAttention(
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = TripEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "isArchived == NO"),
            NSPredicate(format: "attentionReasonsData != nil")
        ])
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var changedRows = 0

        for trip in try context.fetch(request) {
            let storedReasons = trip.attentionReasons(decoder: decoder)
            guard storedReasons.contains(retiredPossibleDuplicateAttentionReason) else {
                continue
            }

            let remainingStoredReasons = storedReasons.filter {
                $0 != retiredPossibleDuplicateAttentionReason
            }
            let actionableReasons: [String]
            if trip.classification == .notADrive {
                actionableReasons = []
            } else {
                actionableReasons = TripReviewPolicy.actionableAttentionReasons(
                    from: remainingStoredReasons
                )
            }

            trip.setAttentionReasons(actionableReasons, encoder: encoder)
            trip.needsAttention = !actionableReasons.isEmpty
            trip.reviewStatus = TripReviewPolicy.normalizedStatus(
                classification: trip.classification,
                businessPurpose: trip.businessPurpose,
                hasActionableAttention: !actionableReasons.isEmpty
            )
            changedRows += 1
        }
        return changedRows
    }
}
