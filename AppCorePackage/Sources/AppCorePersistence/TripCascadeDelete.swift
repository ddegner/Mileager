import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Cascade-deletes a trip and everything that hangs off it.
///
/// Trip deletion happens from the user's Delete Permanently action and from
/// retired-state maintenance. Core Data relationships do not span the
/// Cloud/Local store boundary here (raw samples and enrichment attempts are
/// Local-only and reference trips by UUID, not by relationship), so nothing
/// cascades on its own. Every logical-trip deletion must clear the same
/// dependents or fees, GPS samples, and enrichment attempts are orphaned.
///
/// Static and context-based so background maintenance can use it without
/// constructing a main-context `TripStore`.
enum TripCascadeDelete {
    /// Deletes `entities` plus every row keyed to `tripID`.
    ///
    /// `entities` is a list rather than a single object because CloudKit can
    /// deliver more than one row carrying the same logical trip ID; all of them
    /// have to go.
    static func delete(
        _ entities: [TripEntity],
        tripID: UUID,
        in context: NSManagedObjectContext
    ) throws {
        try clearLinkedFees(tripID: tripID, in: context)
        entities.forEach(context.delete)
        try deleteRawSamples(tripID: tripID, in: context)
        try deleteEnrichmentAttempts(tripID: tripID, in: context)
    }

    /// Every fee on the trip goes with it, imported tolls included.
    ///
    /// Imported tolls used to be unlinked rather than deleted, because the Mac's
    /// toll reconciliation screen could re-attach an orphan to another trip.
    /// That screen and its store API are gone (the E-ZPass CSV import was
    /// retired with the native Mac app), so an unlinked import would now be a
    /// permanently invisible, unreachable row: no UI lists it, nothing can
    /// re-link it, and the trip editor refuses to touch `.ezPassImport` fees.
    /// Deleting it with its trip is the only outcome the user can still reason
    /// about. Fees already attached to surviving trips are untouched.
    private static func clearLinkedFees(tripID: UUID, in context: NSManagedObjectContext) throws {
        let request = TripFeeEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        try context.fetch(request).forEach(context.delete)
    }

    private static func deleteRawSamples(tripID: UUID, in context: NSManagedObjectContext) throws {
        guard hasLocalStore(in: context) else { return }
        let request = RawSampleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        try context.fetch(request).forEach(context.delete)
    }

    private static func deleteEnrichmentAttempts(tripID: UUID, in context: NSManagedObjectContext) throws {
        guard hasLocalStore(in: context) else { return }
        let request = TripEnrichmentAttemptEntity.fetchRequest()
        request.predicate = NSPredicate(format: "tripID == %@", tripID as CVarArg)
        try context.fetch(request).forEach(context.delete)
    }

    /// Raw samples and enrichment attempts live in the device-only store. The
    /// Mac loads Cloud only, so touching them there would fault on a missing
    /// entity and fail the whole Cloud transaction.
    private static func hasLocalStore(in context: NSManagedObjectContext) -> Bool {
        PersistenceController.hasLoadedStore(
            configurationName: PersistenceController.localConfigurationName,
            in: context
        )
    }
}
