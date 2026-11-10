import AppCoreModels
import DriveCaptureEngine
import CloudKit
import CoreData
import Foundation

public enum PersistenceMode: Equatable, Sendable {
    case localOnly
    case cloudKit(containerIdentifier: String)
}

public enum PersistenceStoreScope: Equatable, Sendable {
    case cloudAndLocal
    case cloudOnly
}

public enum PersistenceError: Error, LocalizedError {
    case failedToLoad([Error])
    case cloudKitStoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .failedToLoad(let errors):
            String(
                localized: "Persistent stores failed to load: \(errors.map(\.localizedDescription).joined(separator: "; "))",
                bundle: .appCoreStrings
            )
        case .cloudKitStoreUnavailable:
            String(
                localized: "CloudKit reset is unavailable for the current persistent store.",
                bundle: .appCoreStrings
            )
        }
    }
}

public final class PersistenceController {
    public static let cloudConfigurationName = "Cloud"
    public static let localConfigurationName = "Local"
    /// Transaction author tag for every save made by the app itself, so the
    /// remote-change observer can tell local saves apart from CloudKit imports
    /// in the persistent history.
    public static let appTransactionAuthor = "MileageTrackerApp"

    public let container: NSPersistentContainer

    static func managedObjectModelURL() -> URL? {
        if let momdURL = Bundle.module.url(forResource: "MileageTracker", withExtension: "momd") {
            return momdURL
        }
        if let currentVersion = currentManagedObjectModelVersionName(),
           let currentURL = managedObjectModelURL(versionName: currentVersion) {
            return currentURL
        }
        return Bundle.module.url(forResource: "MileageTrackerCheckpointOnly", withExtension: "mom")
            ?? Bundle.module.url(forResource: "MileageTrackerIndexed", withExtension: "mom")
            ?? Bundle.module.url(forResource: "MileageTracker", withExtension: "mom")
    }

    static func managedObjectModelURL(versionName: String) -> URL? {
        if let momdURL = Bundle.module.url(forResource: "MileageTracker", withExtension: "momd") {
            return momdURL.appendingPathComponent("\(versionName).mom")
        }
        return Bundle.module.url(forResource: versionName, withExtension: "mom")
    }

    private static func currentManagedObjectModelVersionName() -> String? {
        guard let versionInfoURL = Bundle.module.url(forResource: "VersionInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: versionInfoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["NSManagedObjectModel_CurrentVersionName"] as? String
    }

    static func loadManagedObjectModel() -> NSManagedObjectModel {
        let url = managedObjectModelURL()
        guard let url, let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("MileageTracker.xcdatamodeld is missing from the AppCore bundle")
        }
        return model
    }

    public init(
        mode: PersistenceMode = .localOnly,
        scope: PersistenceStoreScope = .cloudAndLocal,
        inMemory: Bool = false,
        storeDirectory: URL? = nil
    ) throws {
        let model = Self.loadManagedObjectModel()
        switch mode {
        case .localOnly:
            container = NSPersistentContainer(name: "MileageTracker", managedObjectModel: model)
        case .cloudKit:
            container = NSPersistentCloudKitContainer(name: "MileageTracker", managedObjectModel: model)
        }

        let descriptions = Self.makeStoreDescriptions(
            mode: mode,
            scope: scope,
            inMemory: inMemory,
            storeDirectory: storeDirectory
        )
        container.persistentStoreDescriptions = descriptions

        var loadErrors: [Error] = []
        container.loadPersistentStores { _, error in
            if let error {
                loadErrors.append(error)
            }
        }

        guard loadErrors.isEmpty else {
            throw PersistenceError.failedToLoad(loadErrors)
        }
        do {
            try SQLiteFetchIndexMaintenance.installMissingIndexes(
                for: container.persistentStoreCoordinator
            )
        } catch {
            throw PersistenceError.failedToLoad([error])
        }

        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.transactionAuthor = Self.appTransactionAuthor
        container.viewContext.name = "viewContext"
    }

    public func makeBackgroundContext(
        name: String,
        transactionAuthor: String = PersistenceController.appTransactionAuthor
    ) -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.name = name
        context.transactionAuthor = transactionAuthor
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.automaticallyMergesChangesFromParent = true
        return context
    }

    public func performBackgroundTask<T: Sendable>(
        name: String,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        let context = makeBackgroundContext(name: name)
        return try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let result = try block(context)
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume(returning: result)
                } catch {
                    if context.hasChanges {
                        context.rollback()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllData() throws {
        let context = container.viewContext
        let coordinator = container.persistentStoreCoordinator
        let loadedEntityNames = Set(coordinator.persistentStores.flatMap { store in
            container.managedObjectModel.entities(forConfigurationName: store.configurationName) ?? []
        }.compactMap(\.name))
        for entityName in loadedEntityNames {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            for object in try context.fetch(request) {
                context.delete(object)
            }
        }
        if context.hasChanges {
            try context.save()
        }
        context.reset()
    }

    public func hasLoadedStore(configurationName: String) -> Bool {
        Self.hasLoadedStore(configurationName: configurationName, in: container.viewContext)
    }

    static func hasLoadedStore(
        configurationName: String,
        in context: NSManagedObjectContext
    ) -> Bool {
        context.persistentStoreCoordinator?.persistentStores.contains {
            $0.configurationName == configurationName
        } ?? false
    }

    @MainActor
    public func purgeCloudKitData(containerIdentifier: String) async throws {
        guard let cloudContainer = container as? NSPersistentCloudKitContainer,
              let cloudStore = container.persistentStoreCoordinator.persistentStores.first(where: {
                  $0.configurationName == Self.cloudConfigurationName
              }) else {
            throw PersistenceError.cloudKitStoreUnavailable
        }

        for zoneID in try await Self.cloudKitZoneIDs(containerIdentifier: containerIdentifier) {
            do {
                try await Self.purgeCloudKitZone(zoneID, container: cloudContainer, store: cloudStore)
            } catch {
                guard Self.isZoneNotFound(error) else { throw error }
            }
        }
    }

    private static func makeStoreDescriptions(
        mode: PersistenceMode,
        scope: PersistenceStoreScope,
        inMemory: Bool,
        storeDirectory: URL?
    ) -> [NSPersistentStoreDescription] {
        let cloudDescription = NSPersistentStoreDescription()
        cloudDescription.configuration = cloudConfigurationName
        cloudDescription.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        cloudDescription.url = inMemory ? URL(fileURLWithPath: "/dev/null/cloud-\(UUID().uuidString)") : storeURL(
            named: "MileageTracker.sqlite",
            storeDirectory: storeDirectory
        )
        cloudDescription.shouldMigrateStoreAutomatically = true
        cloudDescription.shouldInferMappingModelAutomatically = true
        cloudDescription.shouldAddStoreAsynchronously = false
        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if case .cloudKit(let containerIdentifier) = mode {
            cloudDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: containerIdentifier
            )
        }

        let localDescription = NSPersistentStoreDescription()
        localDescription.configuration = localConfigurationName
        localDescription.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        localDescription.url = inMemory ? URL(fileURLWithPath: "/dev/null/local-\(UUID().uuidString)") : storeURL(
            named: "MileageTrackerRaw.sqlite",
            storeDirectory: storeDirectory
        )
        localDescription.shouldMigrateStoreAutomatically = true
        localDescription.shouldInferMappingModelAutomatically = true
        localDescription.shouldAddStoreAsynchronously = false
        localDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        localDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if !inMemory {
            applyFileProtection(to: cloudDescription)
            applyFileProtection(to: localDescription)
        }

        switch scope {
        case .cloudAndLocal:
            return [cloudDescription, localDescription]
        case .cloudOnly:
            return [cloudDescription]
        }
    }

    /// Pins both stores to Data Protection Class C
    /// (`completeUntilFirstUserAuthentication`). Drive capture relaunches the
    /// app and writes location samples and trip completions to both stores
    /// while the device is LOCKED, so `.complete` and `.completeUnlessOpen`
    /// would fail to open the stores on those cold background launches.
    /// Class C is the ceiling; it is set explicitly so the guarantee is
    /// documented and pinned rather than inherited from the platform default.
    /// Remaining floor: a location relaunch before the first unlock after a
    /// reboot still cannot open the stores under any class above `.none`.
    private static func applyFileProtection(to description: NSPersistentStoreDescription) {
        #if os(iOS)
        description.setOption(
            FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
            forKey: NSPersistentStoreFileProtectionKey
        )
        #endif
    }

    private static func storeURL(named fileName: String, storeDirectory: URL?) -> URL {
        if let storeDirectory {
            try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            return storeDirectory.appendingPathComponent(fileName)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MileageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private static func cloudKitZoneIDs(containerIdentifier: String) async throws -> [CKRecordZone.ID] {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let defaultZoneName = CKRecordZone.default().zoneID.zoneName
        let knownCoreDataZone = CKRecordZone.ID(
            zoneName: "com.apple.coredata.cloudkit.zone",
            ownerName: CKCurrentUserDefaultName
        )
        let fetchedZones = try await database.allRecordZones()
        let candidates = fetchedZones
            .map(\.zoneID)
            .filter { $0.zoneName != defaultZoneName } + [knownCoreDataZone]
        var seen = Set<String>()
        return candidates.filter { zoneID in
            seen.insert("\(zoneID.ownerName):\(zoneID.zoneName)").inserted
        }
    }

    @MainActor
    private static func purgeCloudKitZone(
        _ zoneID: CKRecordZone.ID,
        container: NSPersistentCloudKitContainer,
        store: NSPersistentStore
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.purgeObjectsAndRecordsInZone(with: zoneID, in: store) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func isZoneNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain && nsError.code == CKError.Code.zoneNotFound.rawValue
    }
}
