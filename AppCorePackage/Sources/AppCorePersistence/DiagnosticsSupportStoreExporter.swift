import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public struct DiagnosticsSupportExportMetadata: Codable, Equatable, Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var bundleIdentifier: String
    public var backgroundRefreshAvailable: Bool
    public var lowPowerModeEnabled: Bool
    public var detailedDiagnosticsEnabled: Bool?
    public var diagnosticSampleRetentionDays: Int?

    public init(
        appVersion: String = "unknown",
        buildNumber: String = "unknown",
        bundleIdentifier: String = "unknown",
        backgroundRefreshAvailable: Bool = false,
        lowPowerModeEnabled: Bool = false,
        detailedDiagnosticsEnabled: Bool? = nil,
        diagnosticSampleRetentionDays: Int? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.bundleIdentifier = bundleIdentifier
        self.backgroundRefreshAvailable = backgroundRefreshAvailable
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.detailedDiagnosticsEnabled = detailedDiagnosticsEnabled
        self.diagnosticSampleRetentionDays = diagnosticSampleRetentionDays
    }
}

public struct DiagnosticsSupportStoreBundle: Sendable {
    public var directoryURL: URL
    public var storeFileURLs: [URL]
    public var manifestData: Data
    public var supportQuestionsText: String
    public var selectedDays: Int
    public var startDate: Date
    public var endDate: Date
    public var rowCounts: [String: Int]

    public init(
        directoryURL: URL,
        storeFileURLs: [URL],
        manifestData: Data,
        supportQuestionsText: String,
        selectedDays: Int,
        startDate: Date,
        endDate: Date,
        rowCounts: [String: Int]
    ) {
        self.directoryURL = directoryURL
        self.storeFileURLs = storeFileURLs
        self.manifestData = manifestData
        self.supportQuestionsText = supportQuestionsText
        self.selectedDays = selectedDays
        self.startDate = startDate
        self.endDate = endDate
        self.rowCounts = rowCounts
    }
}

public enum DiagnosticsSupportStoreExporterError: Error, LocalizedError {
    case invalidDayCount(Int)
    case missingStoreFiles

    public var errorDescription: String? {
        switch self {
        case .invalidDayCount(let days):
            String(
                localized: "Diagnostics reports can include only 1, 3, 7, or 30 days. \(days) days is not supported.",
                bundle: .appCoreStrings
            )
        case .missingStoreFiles:
            String(
                localized: "The diagnostics support stores could not be created.",
                bundle: .appCoreStrings
            )
        }
    }
}

public enum DiagnosticsSupportStoreExporter {
    public static let allowedDayCounts = [1, 3, 7, 30]

    public static func makeBundle(
        from sourceContainer: NSPersistentContainer,
        selectedDays: Int,
        now: Date = Date(),
        metadata: DiagnosticsSupportExportMetadata = DiagnosticsSupportExportMetadata()
    ) throws -> DiagnosticsSupportStoreBundle {
        guard allowedDayCounts.contains(selectedDays) else {
            throw DiagnosticsSupportStoreExporterError.invalidDayCount(selectedDays)
        }

        let sourceContext = sourceContainer.newBackgroundContext()
        return try sourceContext.performAndWait {
            try makeBundleOnContextQueue(
                sourceContext: sourceContext,
                selectedDays: selectedDays,
                now: now,
                metadata: metadata
            )
        }
    }

    private static func makeBundleOnContextQueue(
        sourceContext: NSManagedObjectContext,
        selectedDays: Int,
        now: Date,
        metadata: DiagnosticsSupportExportMetadata
    ) throws -> DiagnosticsSupportStoreBundle {
        let startDate = now.addingTimeInterval(-Double(selectedDays) * 24 * 60 * 60)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileagerSupportStores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let destination = try PersistenceController(mode: .localOnly, storeDirectory: directory)
            let destinationContext = destination.container.newBackgroundContext()
            destinationContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

            var rowCounts: [String: Int] = [:]
            let tripPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "startDate <= %@", now as NSDate),
                NSPredicate(format: "endDate >= %@", startDate as NSDate)
            ])
            let selectedTripIDs = try PersistenceStoreAttributeCopier.fetchUUIDs(
                entityName: "TripEntity",
                key: "id",
                predicate: tripPredicate,
                context: sourceContext
            )
            let eligibleEnrichmentAttemptIDs = try TripStore(context: sourceContext)
                .eligibleEnrichmentAttemptIDs()

            rowCounts["TripEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "TripEntity",
                predicate: tripPredicate,
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["TripFeeEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "TripFeeEntity",
                predicate: feePredicate(selectedTripIDs: selectedTripIDs, startDate: startDate, endDate: now),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["OdometerCheckpointEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "OdometerCheckpointEntity",
                predicate: NSPredicate(format: "date >= %@ AND date <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["RawSampleEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "RawSampleEntity",
                predicate: NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["TripEnrichmentAttemptEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "TripEnrichmentAttemptEntity",
                predicate: enrichmentAttemptPredicate(
                    selectedTripIDs: selectedTripIDs,
                    eligibleAttemptIDs: eligibleEnrichmentAttemptIDs,
                    startDate: startDate,
                    endDate: now
                ),
                from: sourceContext,
                to: destinationContext
            )
            try sanitizeEnrichmentAttempts(in: destinationContext)
            rowCounts["DiagnosticSampleEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "DiagnosticSampleEntity",
                predicate: NSPredicate(format: "sampleTimestamp >= %@ AND sampleTimestamp <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["DriveCaptureEventEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "DriveCaptureEventEntity",
                predicate: NSPredicate(format: "date >= %@ AND date <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["PendingDriveStartSignalEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "PendingDriveStartSignalEntity",
                predicate: NSPredicate(format: "createdAt >= %@ AND createdAt <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )
            rowCounts["BluetoothObservationEntity"] = try PersistenceStoreAttributeCopier.copyEntity(
                named: "BluetoothObservationEntity",
                predicate: NSPredicate(format: "observedAt >= %@ AND observedAt <= %@", startDate as NSDate, now as NSDate),
                from: sourceContext,
                to: destinationContext
            )

            for entityName in globalEntityNames {
                rowCounts[entityName] = try PersistenceStoreAttributeCopier.copyEntity(
                    named: entityName,
                    predicate: nil,
                    from: sourceContext,
                    to: destinationContext
                )
            }

            destinationContext.performAndWait {
                destinationContext.reset()
            }
            PersistenceStoreAttributeCopier.closeStores(destination)
            let storeFileURLs = storeFileNames
                .map { directory.appendingPathComponent($0) }
                .filter { url in
                    guard FileManager.default.fileExists(atPath: url.path) else { return false }
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return url.pathExtension == "sqlite" || fileSize > 0
                }
            guard !storeFileURLs.isEmpty else {
                throw DiagnosticsSupportStoreExporterError.missingStoreFiles
            }

            let manifest = DiagnosticsSupportManifest(
                generatedAt: now,
                selectedDays: selectedDays,
                startDate: startDate,
                endDate: now,
                metadata: metadata,
                rowCounts: rowCounts,
                dateFilteredEntities: dateFilteredEntityNames,
                globalEntities: globalEntityNames,
                note: "The day range limits dated trip and tracking records. Some app settings, saved reports, Bluetooth metadata, and current tracking state are included regardless of the selected range."
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            return DiagnosticsSupportStoreBundle(
                directoryURL: directory,
                storeFileURLs: storeFileURLs,
                manifestData: try encoder.encode(manifest),
                supportQuestionsText: supportQuestionsText(selectedDays: selectedDays),
                selectedDays: selectedDays,
                startDate: startDate,
                endDate: now,
                rowCounts: rowCounts
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static let dateFilteredEntityNames = [
        "TripEntity",
        "TripFeeEntity",
        "OdometerCheckpointEntity",
        "RawSampleEntity",
        "TripEnrichmentAttemptEntity",
        "DiagnosticSampleEntity",
        "DriveCaptureEventEntity",
        "PendingDriveStartSignalEntity",
        "BluetoothObservationEntity"
    ]

    private static let globalEntityNames = [
        "PreferenceEntity",
        "VehicleEntity",
        "VehicleConnectionAliasEntity",
        "BluetoothHintEntity",
        "BluetoothMetadataEntity",
        "ReportSnapshotEntity",
        "ActiveDriveEntity"
    ]

    private static let storeFileNames = [
        "MileageTracker.sqlite",
        "MileageTracker.sqlite-wal",
        "MileageTracker.sqlite-shm",
        "MileageTrackerRaw.sqlite",
        "MileageTrackerRaw.sqlite-wal",
        "MileageTrackerRaw.sqlite-shm"
    ]

    private static func feePredicate(selectedTripIDs: [UUID], startDate: Date, endDate: Date) -> NSPredicate {
        let datePredicate = NSPredicate(format: "occurredAt >= %@ AND occurredAt <= %@", startDate as NSDate, endDate as NSDate)
        guard !selectedTripIDs.isEmpty else { return datePredicate }
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "tripID IN %@", selectedTripIDs),
            datePredicate
        ])
    }

    private static func enrichmentAttemptPredicate(
        selectedTripIDs: [UUID],
        eligibleAttemptIDs: [UUID],
        startDate: Date,
        endDate: Date
    ) -> NSPredicate {
        guard !eligibleAttemptIDs.isEmpty else { return NSPredicate(value: false) }
        let datePredicate = NSPredicate(
            format: "lastAttemptAt >= %@ AND lastAttemptAt <= %@",
            startDate as NSDate,
            endDate as NSDate
        )
        let rangePredicate: NSPredicate = if selectedTripIDs.isEmpty {
            datePredicate
        } else {
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "tripID IN %@", selectedTripIDs as NSArray),
                datePredicate
            ])
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            rangePredicate,
            NSPredicate(format: "id IN %@", eligibleAttemptIDs as NSArray)
        ])
    }

    private static func sanitizeEnrichmentAttempts(
        in context: NSManagedObjectContext
    ) throws {
        try context.performAndWait {
            let attempts = try context.fetch(TripEnrichmentAttemptEntity.fetchRequest())
            for attempt in attempts {
                // Unknown/corrupt raw values must never turn support metadata
                // into an accidental carrier for underlying error text.
                if TripEnrichmentFailureCategory(rawValue: attempt.failureCategoryRaw) == nil {
                    attempt.failureCategory = .unknown
                }
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    private static func supportQuestionsText(selectedDays: Int) -> String {
        """
        Please answer these before sending:

        1. What went wrong?
        2. What were you trying to do?
        3. About what date and time did it happen?
        4. Did Mileager show an error message? If so, what did it say?
        5. Anything else that might help reproduce it?

        The attached ZIP contains Mileager support data you chose to send. It includes personal trip/location information, and some app settings, vehicle profiles, saved reports, Bluetooth metadata, and current tracking state are included regardless of the selected day range.

        Selected range: last \(selectedDays) \(selectedDays == 1 ? "day" : "days").
        """
    }
}

private struct DiagnosticsSupportManifest: Codable {
    var generatedAt: Date
    var selectedDays: Int
    var startDate: Date
    var endDate: Date
    var metadata: DiagnosticsSupportExportMetadata
    var rowCounts: [String: Int]
    var dateFilteredEntities: [String]
    var globalEntities: [String]
    var note: String
}
