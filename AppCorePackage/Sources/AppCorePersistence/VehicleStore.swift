import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public enum VehicleStoreError: Error, LocalizedError {
    case vehicleNotFound
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .vehicleNotFound:
            String(localized: "Vehicle not found.", bundle: .appCoreStrings)
        case .invalidName:
            String(localized: "A vehicle name can't be empty.", bundle: .appCoreStrings)
        }
    }
}

public struct VehicleRemovalResult: Equatable, Sendable {
    public var vehicleID: UUID
    public var reassignedTripIDs: [UUID]
    public var deletedOdometerCheckpointCount: Int
    public var deletedConnectionAliasCount: Int
    public var unlinkedBluetoothHintCount: Int
    public var primaryVehicleID: UUID?

    public init(
        vehicleID: UUID,
        reassignedTripIDs: [UUID],
        deletedOdometerCheckpointCount: Int,
        unlinkedBluetoothHintCount: Int,
        primaryVehicleID: UUID?,
        deletedConnectionAliasCount: Int = 0
    ) {
        self.vehicleID = vehicleID
        self.reassignedTripIDs = reassignedTripIDs
        self.deletedOdometerCheckpointCount = deletedOdometerCheckpointCount
        self.deletedConnectionAliasCount = deletedConnectionAliasCount
        self.unlinkedBluetoothHintCount = unlinkedBluetoothHintCount
        self.primaryVehicleID = primaryVehicleID
    }
}

/// CRUD for `Vehicle` profiles plus the synced "primary vehicle" pointer.
///
/// The iPhone/iPad app creates a default vehicle at onboarding/launch (see
/// `MileageAppModel.createDefaultVehicleIfNeeded`); Mac vehicles are imported or
/// added explicitly. The store itself never backfills rows: trips and odometer
/// checkpoints with a `nil` vehicleID belong to the primary vehicle (the first
/// one created). This keeps existing history rows untouched and CloudKit safe —
/// no row rewrite ever runs.
public final class VehicleStore {
    /// Synced pointer to the primary vehicle's UUID.
    public static let primaryPreferenceKey = "vehicles.primary.v1"

    private let context: NSManagedObjectContext
    private let primaryPreference: PreferenceStore

    public init(context: NSManagedObjectContext) {
        self.context = context
        primaryPreference = PreferenceStore(context: context, key: Self.primaryPreferenceKey)
    }

    // MARK: - Reads

    public func fetchVehicles(includeArchived: Bool = false) throws -> [Vehicle] {
        let entities = try fetchEntities(includeArchived: true)
        var preferredByID: [UUID: VehicleEntity] = [:]
        var idless: [VehicleEntity] = []
        for entity in entities {
            guard let id = entity.id else {
                idless.append(entity)
                continue
            }
            if let current = preferredByID[id] {
                if Self.prefers(entity, over: current) {
                    preferredByID[id] = entity
                }
            } else {
                preferredByID[id] = entity
            }
        }
        return (Array(preferredByID.values) + idless)
            .filter { includeArchived || !$0.isArchived }
            .sorted(by: Self.displayOrder)
            .map(\.asVehicle)
    }

    // MARK: - Writes

    @discardableResult
    public func createVehicle(
        name: String,
        colorHex: String? = nil,
        symbolName: String? = nil
    ) throws -> Vehicle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VehicleStoreError.invalidName }
        return try context.saveTransaction {
            let now = Date()
            let existing = try fetchEntities(includeArchived: true)
            let entity = VehicleEntity.insert(into: context)
            entity.id = UUID()
            entity.name = trimmed
            entity.colorHex = colorHex
            entity.symbolName = symbolName
            entity.createdAt = now
            entity.updatedAt = now
            entity.sortOrder = Int64((existing.map { $0.sortOrder }.max() ?? -1) + 1)
            entity.isArchived = false
            // The first active vehicle becomes primary so nil-vehicle history is
            // displayed under it.
            if existing.allSatisfy({ $0.isArchived }) {
                try writePrimary(entity.id)
            }
            return entity.asVehicle
        }
    }

    @discardableResult
    public func renameVehicle(id: UUID, name: String) throws -> Vehicle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VehicleStoreError.invalidName }
        return try context.saveTransaction {
            let entity = try preferredEntityCollapsingDuplicates(id: id)
            entity.name = trimmed
            entity.updatedAt = Date()
            return entity.asVehicle
        }
    }

    @discardableResult
    public func updateAppearance(id: UUID, colorHex: String?, symbolName: String?) throws -> Vehicle {
        try context.saveTransaction {
            let entity = try preferredEntityCollapsingDuplicates(id: id)
            entity.colorHex = colorHex
            entity.symbolName = symbolName
            entity.updatedAt = Date()
            return entity.asVehicle
        }
    }

    @discardableResult
    public func setArchived(id: UUID, archived: Bool) throws -> Vehicle {
        try context.saveTransaction {
            let entity = try preferredEntityCollapsingDuplicates(id: id)
            entity.isArchived = archived
            entity.updatedAt = Date()
            if archived, try readPrimary() == id {
                // Hand primary off to the next active vehicle, if any.
                let nextPrimary = try fetchEntities(includeArchived: false)
                    .first { $0.id != id }?.id
                try writePrimary(nextPrimary)
            }
            return entity.asVehicle
        }
    }

    public func setSortOrder(ids: [UUID]) throws {
        try context.saveTransaction {
            for (index, id) in ids.enumerated() {
                guard let entity = try? preferredEntityCollapsingDuplicates(id: id) else { continue }
                entity.sortOrder = Int64(index)
                entity.updatedAt = Date()
            }
        }
    }

    /// Compatibility entry point for vehicle deletion. All associated cleanup is
    /// intentionally part of the same transaction; profile-only deletion is not
    /// exposed because it can strand trips, readings, or local device mappings.
    public func deleteVehicle(id: UUID) throws {
        _ = try deleteVehicleAndAssociatedData(id: id)
    }

    /// Removes a vehicle and every reference that cannot survive its deletion in
    /// one Core Data save. Trips become unassigned, this vehicle's physical
    /// odometer readings are deleted, and device-local Bluetooth mappings are
    /// unlinked when the Local store is loaded.
    @discardableResult
    public func deleteVehicleAndAssociatedData(id: UUID) throws -> VehicleRemovalResult {
        try deleteVehicleAndAssociatedData(id: id, beforeSave: {})
    }

    @discardableResult
    func deleteVehicleAndAssociatedData(
        id: UUID,
        beforeSave: () throws -> Void
    ) throws -> VehicleRemovalResult {
        try context.saveTransaction {
            let vehicleEntities = try fetchEntities(id: id)
            guard !vehicleEntities.isEmpty else { throw VehicleStoreError.vehicleNotFound }
            let now = Date()

            let tripRequest = TripEntity.fetchRequest()
            tripRequest.predicate = NSPredicate(format: "vehicleID == %@", id as CVarArg)
            let trips = try context.fetch(tripRequest)
            for trip in trips {
                trip.vehicleID = nil
                trip.vehicleAssignmentSource = nil
                trip.updatedAt = now
            }
            let reassignedTripIDs = Set(trips.compactMap(\.id))
                .sorted { $0.uuidString < $1.uuidString }

            let odometerRequest = OdometerCheckpointEntity.fetchRequest()
            odometerRequest.predicate = NSPredicate(format: "vehicleID == %@", id as CVarArg)
            let odometerCheckpoints = try context.fetch(odometerRequest)
            let deletedOdometerCheckpointCount = Set(odometerCheckpoints.compactMap(\.id)).count
            odometerCheckpoints.forEach(context.delete)

            let aliasRequest = VehicleConnectionAliasEntity.fetchRequest()
            aliasRequest.predicate = NSPredicate(format: "vehicleID == %@", id as CVarArg)
            let aliases = try context.fetch(aliasRequest)
            let aliasIDs = Set(aliases.compactMap(\.id))
            let deletedConnectionAliasCount = aliasIDs.count
            aliases.forEach(context.delete)

            var unlinkedBluetoothHintCount = 0
            if PersistenceController.hasLoadedStore(
                configurationName: PersistenceController.localConfigurationName,
                in: context
            ) {
                let hints = try context.fetch(BluetoothHintEntity.fetchRequest()).filter { hint in
                    hint.vehicleID == id
                        || hint.connectionAliasID.map(aliasIDs.contains) == true
                }
                unlinkedBluetoothHintCount = Set(hints.map(\.identifierHash)).count
                for hint in hints {
                    hint.vehicleID = nil
                    hint.connectionAliasID = nil
                    hint.mappingDispositionRaw = VehicleConnectionMappingDisposition.unreviewed.rawValue
                    hint.mappingUpdatedAt = now
                }
            }

            vehicleEntities.forEach(context.delete)
            let primaryVehicleID: UUID?
            if try readPrimary() == id {
                primaryVehicleID = try fetchEntities(includeArchived: false)
                    .first { $0.id != id }?.id
                try writePrimary(primaryVehicleID)
            } else {
                primaryVehicleID = try readPrimary()
            }

            try beforeSave()
            return VehicleRemovalResult(
                vehicleID: id,
                reassignedTripIDs: reassignedTripIDs,
                deletedOdometerCheckpointCount: deletedOdometerCheckpointCount,
                unlinkedBluetoothHintCount: unlinkedBluetoothHintCount,
                primaryVehicleID: primaryVehicleID,
                deletedConnectionAliasCount: deletedConnectionAliasCount
            )
        }
    }

    // MARK: - Primary vehicle

    /// The primary vehicle's UUID, validated to still exist (returns nil if the
    /// row was deleted on another device before sync).
    public func primaryVehicleID() throws -> UUID? {
        guard let stored = try readPrimary() else { return nil }
        guard let vehicle = try fetchVehicles(includeArchived: true).first(where: { $0.id == stored }) else {
            return nil
        }
        return vehicle.isArchived ? nil : stored
    }

    // MARK: - Private

    private func preferredEntityCollapsingDuplicates(id: UUID) throws -> VehicleEntity {
        let entities = try fetchEntities(id: id)
        guard let entity = entities.first else {
            throw VehicleStoreError.vehicleNotFound
        }
        for duplicate in entities.dropFirst() {
            context.delete(duplicate)
        }
        return entity
    }

    private func fetchEntities(id: UUID) throws -> [VehicleEntity] {
        let request = VehicleEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).sorted {
            Self.prefers($0, over: $1)
        }
    }

    private func fetchEntities(includeArchived: Bool) throws -> [VehicleEntity] {
        let request = VehicleEntity.fetchRequest()
        if !includeArchived {
            request.predicate = NSPredicate(format: "isArchived == NO")
        }
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return try context.fetch(request)
    }

    private static func prefers(_ lhs: VehicleEntity, over rhs: VehicleEntity) -> Bool {
        let lhsUpdated = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsUpdated = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        if lhsUpdated != rhsUpdated { return lhsUpdated > rhsUpdated }
        let lhsCreated = lhs.createdAt ?? .distantPast
        let rhsCreated = rhs.createdAt ?? .distantPast
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
        return lhs.objectID.uriRepresentation().absoluteString
            < rhs.objectID.uriRepresentation().absoluteString
    }

    private static func displayOrder(_ lhs: VehicleEntity, _ rhs: VehicleEntity) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        let lhsCreated = lhs.createdAt ?? .distantFuture
        let rhsCreated = rhs.createdAt ?? .distantFuture
        if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
        return (lhs.id?.uuidString ?? lhs.objectID.uriRepresentation().absoluteString)
            < (rhs.id?.uuidString ?? rhs.objectID.uriRepresentation().absoluteString)
    }

    private func readPrimary() throws -> UUID? {
        let stored: PrimaryVehiclePreference? = try primaryPreference.read()
        return stored?.vehicleID
    }

    private func writePrimary(_ id: UUID?) throws {
        try primaryPreference.writeWithoutSaving(PrimaryVehiclePreference(vehicleID: id))
    }
}

private struct PrimaryVehiclePreference: Codable {
    var vehicleID: UUID?
}
