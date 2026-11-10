import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Copies managed-object attributes between compatible coordinators without
/// carrying persistent-store or CloudKit metadata into the destination.
/// Callers choose the entity set and predicates; this utility owns the common
/// queue confinement and attribute enumeration.
enum PersistenceStoreAttributeCopier {
    static func copyEntity(
        named entityName: String,
        predicate: NSPredicate?,
        from sourceContext: NSManagedObjectContext,
        to destinationContext: NSManagedObjectContext
    ) throws -> Int {
        let rows = try fetchAttributeRows(
            entityName: entityName,
            predicate: predicate,
            context: sourceContext
        )
        guard !rows.isEmpty else { return 0 }
        try destinationContext.performAndWait {
            for row in rows {
                let object = NSEntityDescription.insertNewObject(
                    forEntityName: entityName,
                    into: destinationContext
                )
                for (key, value) in row.values {
                    object.setValue(value, forKey: key)
                }
            }
            if destinationContext.hasChanges {
                try destinationContext.save()
            }
        }
        return rows.count
    }

    static func fetchUUIDs(
        entityName: String,
        key: String,
        predicate: NSPredicate?,
        context: NSManagedObjectContext
    ) throws -> [UUID] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = predicate
        request.includesPendingChanges = false
        return try context.fetch(request).compactMap { $0.value(forKey: key) as? UUID }
    }

    static func closeStores(_ persistence: PersistenceController) {
        let coordinator = persistence.container.persistentStoreCoordinator
        persistence.container.viewContext.reset()
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private static func fetchAttributeRows(
        entityName: String,
        predicate: NSPredicate?,
        context: NSManagedObjectContext
    ) throws -> [AttributeRow] {
        guard let entity = context.persistentStoreCoordinator?
            .managedObjectModel.entitiesByName[entityName] else {
            return []
        }
        let attributeNames = entity.attributesByName.keys.sorted()
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = predicate
        request.fetchBatchSize = 500
        request.includesPendingChanges = false
        return try context.fetch(request).map { object in
            var values: [String: Any] = [:]
            for name in attributeNames {
                if let value = object.value(forKey: name) {
                    values[name] = value
                }
            }
            return AttributeRow(values: values)
        }
    }
}

private struct AttributeRow: @unchecked Sendable {
    var values: [String: Any]
}
