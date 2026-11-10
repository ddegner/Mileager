import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public struct FirstSyncRecoverySnapshot: Sendable {
    public var directoryURL: URL
    public var storeFileURLs: [URL]
    public var manifestData: Data
    public var generatedAt: Date
    public var rowCounts: [String: Int]

    public init(
        directoryURL: URL,
        storeFileURLs: [URL],
        manifestData: Data,
        generatedAt: Date,
        rowCounts: [String: Int]
    ) {
        self.directoryURL = directoryURL
        self.storeFileURLs = storeFileURLs
        self.manifestData = manifestData
        self.generatedAt = generatedAt
        self.rowCounts = rowCounts
    }
}

public enum FirstSyncRecoverySnapshotError: Error, LocalizedError {
    case noLoadedStores
    case missingStoreFiles
    case sourceChangedDuringSnapshot

    public var errorDescription: String? {
        switch self {
        case .noLoadedStores:
            String(
                localized: "The local mileage data is not available for a recovery copy.",
                bundle: .appCoreStrings
            )
        case .missingStoreFiles:
            String(
                localized: "The recovery copy could not be created.",
                bundle: .appCoreStrings
            )
        case .sourceChangedDuringSnapshot:
            String(
                localized: "Mileage data changed while the recovery copy was being created. Try again.",
                bundle: .appCoreStrings
            )
        }
    }
}

/// Creates a device-local, CloudKit-free copy immediately before a local-only
/// iPhone library is attached to production CloudKit. Every entity belonging
/// to a currently loaded store is copied, including raw samples, while hidden
/// persistent-store and CloudKit metadata are deliberately omitted.
public enum FirstSyncRecoverySnapshotExporter {
    public static let manifestFileName = "FirstSyncRecoveryManifest.json"

    public static func makeSnapshot(
        from sourceContainer: NSPersistentContainer,
        destinationRootURL: URL,
        generatedAt: Date = Date()
    ) async throws -> FirstSyncRecoverySnapshot {
        try await makeSnapshot(
            from: sourceContainer,
            destinationRootURL: destinationRootURL,
            generatedAt: generatedAt,
            beforeCopyEntity: { _ in }
        )
    }

    static func makeSnapshot(
        from sourceContainer: NSPersistentContainer,
        destinationRootURL: URL,
        generatedAt: Date = Date(),
        beforeCopyEntity: @escaping @Sendable (String) throws -> Void
    ) async throws -> FirstSyncRecoverySnapshot {
        let sourceContext = sourceContainer.newBackgroundContext()
        return try await withCheckedThrowingContinuation { continuation in
            sourceContext.perform {
                do {
                    continuation.resume(returning: try makeSnapshotOnContextQueue(
                        sourceContainer: sourceContainer,
                        sourceContext: sourceContext,
                        destinationRootURL: destinationRootURL,
                        generatedAt: generatedAt,
                        beforeCopyEntity: beforeCopyEntity
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeSnapshotOnContextQueue(
        sourceContainer: NSPersistentContainer,
        sourceContext: NSManagedObjectContext,
        destinationRootURL: URL,
        generatedAt: Date,
        beforeCopyEntity: @Sendable (String) throws -> Void
    ) throws -> FirstSyncRecoverySnapshot {
        let coordinator = sourceContainer.persistentStoreCoordinator
        guard !coordinator.persistentStores.isEmpty else {
            throw FirstSyncRecoverySnapshotError.noLoadedStores
        }
        let model = coordinator.managedObjectModel
        let entityNames = Set(coordinator.persistentStores.flatMap { store in
            model.entities(forConfigurationName: store.configurationName) ?? []
        }.compactMap(\.name)).sorted()
        guard !entityNames.isEmpty else {
            throw FirstSyncRecoverySnapshotError.noLoadedStores
        }
        let sourceHistoryToken = coordinator.currentPersistentHistoryToken(
            fromStores: coordinator.persistentStores
        )
        if coordinator.persistentStores.allSatisfy({ $0.type == NSSQLiteStoreType }) {
            try sourceContext.setQueryGenerationFrom(.current)
        }

        try FileManager.default.createDirectory(
            at: destinationRootURL,
            withIntermediateDirectories: true
        )
        let snapshotDirectory = destinationRootURL.appendingPathComponent(
            "snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )

        do {
            let destination = try PersistenceController(
                mode: .localOnly,
                storeDirectory: snapshotDirectory
            )
            let destinationContext = destination.container.newBackgroundContext()
            destinationContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
            var rowCounts: [String: Int] = [:]
            for entityName in entityNames {
                try beforeCopyEntity(entityName)
                rowCounts[entityName] = try PersistenceStoreAttributeCopier.copyEntity(
                    named: entityName,
                    predicate: nil,
                    from: sourceContext,
                    to: destinationContext
                )
            }

            destinationContext.performAndWait { destinationContext.reset() }
            PersistenceStoreAttributeCopier.closeStores(destination)

            let storeFileURLs = try FileManager.default.contentsOfDirectory(
                at: snapshotDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                url.lastPathComponent.hasPrefix("MileageTracker")
                    && (url.pathExtension == "sqlite"
                        || url.lastPathComponent.hasSuffix("-wal")
                        || url.lastPathComponent.hasSuffix("-shm"))
            }
            guard storeFileURLs.contains(where: { $0.pathExtension == "sqlite" }) else {
                throw FirstSyncRecoverySnapshotError.missingStoreFiles
            }

            let manifest = FirstSyncRecoveryManifest(
                formatVersion: 1,
                generatedAt: generatedAt,
                rowCounts: rowCounts,
                entityNames: entityNames,
                note: "Complete device-local mileage recovery copy created before enabling iCloud Sync. CloudKit metadata is not included."
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: snapshotDirectory.appendingPathComponent(manifestFileName),
                options: .atomic
            )

            let currentHistoryToken = coordinator.currentPersistentHistoryToken(
                fromStores: coordinator.persistentStores
            )
            guard historyTokensMatch(sourceHistoryToken, currentHistoryToken) else {
                throw FirstSyncRecoverySnapshotError.sourceChangedDuringSnapshot
            }

            removeOlderSnapshots(in: destinationRootURL, keeping: snapshotDirectory)
            return FirstSyncRecoverySnapshot(
                directoryURL: snapshotDirectory,
                storeFileURLs: storeFileURLs.sorted { $0.lastPathComponent < $1.lastPathComponent },
                manifestData: manifestData,
                generatedAt: generatedAt,
                rowCounts: rowCounts
            )
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
    }

    private static func historyTokensMatch(
        _ lhs: NSPersistentHistoryToken?,
        _ rhs: NSPersistentHistoryToken?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isEqual(rhs)
        default: false
        }
    }

    private static func removeOlderSnapshots(in root: URL, keeping snapshot: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let snapshotPath = snapshot.standardizedFileURL.path
        for url in contents where url.standardizedFileURL.path != snapshotPath {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct FirstSyncRecoveryManifest: Codable {
    var formatVersion: Int
    var generatedAt: Date
    var rowCounts: [String: Int]
    var entityNames: [String]
    var note: String
}
