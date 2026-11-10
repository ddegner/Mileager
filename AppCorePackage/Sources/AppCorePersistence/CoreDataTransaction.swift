import AppCoreModels
import DriveCaptureEngine
import CoreData

extension NSManagedObjectContext {
    /// Runs `work`, saves iff the context has changes, and rolls back on
    /// error so a failed mutation never leaks partial state into later saves.
    ///
    /// TripStore deliberately keeps its own private variant: it captures the
    /// pending change set before saving and notifies its change observer.
    @discardableResult
    func saveTransaction<T>(_ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            if hasChanges {
                try save()
            }
            return result
        } catch {
            if hasChanges {
                rollback()
            }
            throw error
        }
    }
}
