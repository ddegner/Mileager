import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

/// Persists Core Data history tokens only within the store generation and
/// CloudKit container that created them. A token is opaque and cannot be
/// reused safely after a store replacement or by an alternate container.
public struct PersistentHistoryTokenStore {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let containerIdentifier: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String,
        containerIdentifier: String
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.containerIdentifier = containerIdentifier
    }

    public func token(for persistence: PersistenceController) -> NSPersistentHistoryToken? {
        guard let key = defaultsKey(for: persistence),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSPersistentHistoryToken.self,
            from: data
        )
    }

    public func save(_ token: NSPersistentHistoryToken, for persistence: PersistenceController) {
        guard let key = defaultsKey(for: persistence),
              let data = try? NSKeyedArchiver.archivedData(
                  withRootObject: token,
                  requiringSecureCoding: true
              ) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    public func clear(for persistence: PersistenceController) {
        guard let key = defaultsKey(for: persistence) else { return }
        defaults.removeObject(forKey: key)
    }

    public func defaultsKey(for persistence: PersistenceController) -> String? {
        guard let storeUUID = Self.cloudStoreUUID(for: persistence) else {
            return nil
        }
        return "\(keyPrefix).\(containerIdentifier).\(storeUUID)"
    }

    public static func cloudStoreUUID(for persistence: PersistenceController) -> String? {
        persistence.container.persistentStoreCoordinator.persistentStores
            .first(where: { $0.configurationName == PersistenceController.cloudConfigurationName })?
            .metadata[NSStoreUUIDKey] as? String
    }
}
