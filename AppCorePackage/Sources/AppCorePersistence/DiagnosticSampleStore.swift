import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public enum DiagnosticSampleStoreError: Error, LocalizedError {
    case invalidSample
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .invalidSample:
            String(localized: "Diagnostic location sample is malformed.", bundle: .appCoreStrings)
        case .invalidDateRange:
            String(localized: "Diagnostic sample date range is invalid.", bundle: .appCoreStrings)
        }
    }
}

public protocol DiagnosticSamplePersisting: AnyObject {
    @discardableResult
    func save(_ sample: DiagnosticLocationSample) throws -> DiagnosticLocationSample
    func fetchSamples(since startDate: Date?, until endDate: Date?) throws -> [DiagnosticLocationSample]
    func tagSamples(monitoringSessionID: UUID, tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int
    func tagSamples(tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int
    func purgeExpiredSamples(now: Date) throws -> Int
    func applyRetentionPolicy(retentionDays: Int, now: Date, preservingFrom: Date?) throws -> Int
}

public final class DiagnosticSampleStore: DiagnosticSamplePersisting {
    private static let retentionPolicyMetadataKey = "com.daviddegner.MileageTracker.diagnosticRetentionDays"
    private let context: NSManagedObjectContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(context: NSManagedObjectContext) {
        self.context = context
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    public func save(_ sample: DiagnosticLocationSample) throws -> DiagnosticLocationSample {
        try context.saveTransaction {
            try validate(sample)
            let entity = DiagnosticSampleEntity.insert(into: context)
            write(sample, to: entity)
            return sample
        }
    }

    public func fetchSamples(since startDate: Date? = nil, until endDate: Date? = nil) throws -> [DiagnosticLocationSample] {
        if let startDate, let endDate, startDate > endDate {
            throw DiagnosticSampleStoreError.invalidDateRange
        }
        let request = DiagnosticSampleEntity.fetchRequest()
        var predicates: [NSPredicate] = []
        if let startDate {
            predicates.append(NSPredicate(format: "sampleTimestamp >= %@", startDate as NSDate))
        }
        if let endDate {
            predicates.append(NSPredicate(format: "sampleTimestamp <= %@", endDate as NSDate))
        }
        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "sampleTimestamp", ascending: true)]
        return try context.fetch(request).map(mapSample)
    }

    public func tagSamples(monitoringSessionID: UUID, tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int {
        guard startDate <= endDate else {
            throw DiagnosticSampleStoreError.invalidDateRange
        }
        return try tagSamples(
            tripID: tripID,
            matching: [
                NSPredicate(format: "monitoringSessionID == %@", monitoringSessionID as CVarArg),
                NSPredicate(format: "sampleTimestamp >= %@", startDate as NSDate),
                NSPredicate(format: "sampleTimestamp <= %@", endDate as NSDate)
            ]
        )
    }

    public func tagSamples(tripID: UUID, from startDate: Date, to endDate: Date) throws -> Int {
        guard startDate <= endDate else {
            throw DiagnosticSampleStoreError.invalidDateRange
        }
        return try tagSamples(
            tripID: tripID,
            matching: [
                NSPredicate(format: "sampleTimestamp >= %@", startDate as NSDate),
                NSPredicate(format: "sampleTimestamp <= %@", endDate as NSDate)
            ]
        )
    }

    private func tagSamples(tripID: UUID, matching predicates: [NSPredicate]) throws -> Int {
        return try context.saveTransaction {
            let request = DiagnosticSampleEntity.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let samples = try context.fetch(request)
            for sample in samples {
                sample.tripID = tripID
            }
            return samples.count
        }
    }

    @discardableResult
    public func purgeExpiredSamples(now: Date = Date()) throws -> Int {
        try context.saveTransaction {
            let request = DiagnosticSampleEntity.fetchRequest()
            request.predicate = NSPredicate(format: "expiresAt < %@", now as NSDate)
            let expired = try context.fetch(request)
            expired.forEach(context.delete)
            return expired.count
        }
    }

    /// Applies the selected retention policy to rows created under either
    /// diagnostics mode. `preservingFrom` protects an active capture even if
    /// it runs longer than the ordinary rolling window.
    @discardableResult
    public func applyRetentionPolicy(
        retentionDays: Int,
        now: Date = Date(),
        preservingFrom: Date? = nil
    ) throws -> Int {
        let retention = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        let cutoff = now.addingTimeInterval(-retention)
        let normalizedRetentionDays = max(1, retentionDays)
        let needsFullRewrite = appliedRetentionDays != normalizedRetentionDays
        let deletedCount = try context.saveTransaction {
            let deleteRequest = DiagnosticSampleEntity.fetchRequest()
            var deletePredicates = [NSPredicate(format: "sampleTimestamp < %@", cutoff as NSDate)]
            if let preservingFrom {
                deletePredicates.append(NSPredicate(format: "sampleTimestamp < %@", preservingFrom as NSDate))
            }
            deleteRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: deletePredicates)
            let expired = try context.fetch(deleteRequest)
            expired.forEach(context.delete)
            var deletedCount = 0
            deletedCount += expired.count

            if !needsFullRewrite {
                guard let preservingFrom else { return deletedCount }
                let protectedExpiry = now.addingTimeInterval(retention)
                let protectedRequest = DiagnosticSampleEntity.fetchRequest()
                protectedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "sampleTimestamp >= %@", preservingFrom as NSDate),
                    NSPredicate(format: "expiresAt < %@", protectedExpiry as NSDate)
                ])
                for sample in try context.fetch(protectedRequest) {
                    sample.expiresAt = protectedExpiry
                }
                return deletedCount
            }

            let retainedRequest = DiagnosticSampleEntity.fetchRequest()
            let retainedFrom = min(cutoff, preservingFrom ?? cutoff)
            retainedRequest.predicate = NSPredicate(
                format: "sampleTimestamp >= %@",
                retainedFrom as NSDate
            )
            for sample in try context.fetch(retainedRequest) where !sample.isDeleted {
                let isProtectedForActiveCapture = preservingFrom.map {
                    sample.sampleTimestamp >= $0
                } ?? false
                if isProtectedForActiveCapture {
                    let protectedExpiry = max(sample.expiresAt, now.addingTimeInterval(retention))
                    if sample.expiresAt != protectedExpiry {
                        sample.expiresAt = protectedExpiry
                    }
                    continue
                }
                let policyExpiry = sample.receivedAt.addingTimeInterval(retention)
                if sample.expiresAt != policyExpiry {
                    sample.expiresAt = policyExpiry
                }
            }
            return deletedCount
        }
        if needsFullRewrite {
            appliedRetentionDays = normalizedRetentionDays
        }
        return deletedCount
    }

    /// Store metadata makes the expensive rewrite a one-time mode transition,
    /// not a launch-time scan. The Local configuration owns diagnostic rows, so
    /// this marker follows the SQLite store without becoming synced user data.
    private var appliedRetentionDays: Int? {
        get {
            guard let coordinator = context.persistentStoreCoordinator,
                  let store = coordinator.persistentStores.first(where: {
                      $0.configurationName == PersistenceController.localConfigurationName
                  }) else {
                return nil
            }
            return coordinator.metadata(for: store)[Self.retentionPolicyMetadataKey] as? Int
        }
        set {
            guard let coordinator = context.persistentStoreCoordinator,
                  let store = coordinator.persistentStores.first(where: {
                      $0.configurationName == PersistenceController.localConfigurationName
                  }) else {
                return
            }
            var metadata = coordinator.metadata(for: store)
            metadata[Self.retentionPolicyMetadataKey] = newValue
            coordinator.setMetadata(metadata, for: store)
        }
    }

    // MARK: - Mapping

    private func write(_ sample: DiagnosticLocationSample, to entity: DiagnosticSampleEntity) {
        let location = sample.sample
        entity.id = sample.id
        entity.monitoringSessionID = sample.monitoringSessionID
        entity.tripID = sample.tripID
        entity.receivedAt = sample.receivedAt
        entity.sampleTimestamp = location.timestamp
        entity.latitude = location.latitude
        entity.longitude = location.longitude
        entity.horizontalAccuracy = location.horizontalAccuracy
        entity.speedMetersPerSecond = location.speedMetersPerSecond.asNSNumber
        entity.speedAccuracyMetersPerSecond = location.speedAccuracyMetersPerSecond.asNSNumber
        entity.courseDegrees = location.courseDegrees.asNSNumber
        entity.motionHintRaw = location.motionHint.rawValue
        entity.motionActivityData = location.motionActivity.flatMap { try? encoder.encode($0) }
        entity.trackingPhaseRaw = sample.trackingPhase
        entity.powerConnected = sample.powerConnected
        entity.recentPowerConnected = sample.recentPowerConnected
        entity.recentPowerDisconnected = sample.recentPowerDisconnected
        entity.trustedBluetoothVehicleHint = sample.trustedBluetoothVehicleHint
        entity.acceptedForDetection = sample.acceptedForDetection
        entity.detectionOutputRaw = emptyToNil(sample.detectionOutput)
        entity.detectionReason = emptyToNil(sample.detectionReason)
        entity.expiresAt = sample.expiresAt
    }

    private func mapSample(_ entity: DiagnosticSampleEntity) -> DiagnosticLocationSample {
        let motionActivity = entity.motionActivityData.flatMap { try? decoder.decode(MotionActivitySnapshot.self, from: $0) }
        let location = LocationSample(
            timestamp: entity.sampleTimestamp,
            latitude: entity.latitude,
            longitude: entity.longitude,
            horizontalAccuracy: entity.horizontalAccuracy,
            speedMetersPerSecond: entity.speedMetersPerSecond?.doubleValue,
            speedAccuracyMetersPerSecond: entity.speedAccuracyMetersPerSecond?.doubleValue,
            courseDegrees: entity.courseDegrees?.doubleValue,
            motionHint: MotionHint(rawValue: entity.motionHintRaw) ?? .unknown,
            motionActivity: motionActivity
        )
        return DiagnosticLocationSample(
            id: entity.id,
            monitoringSessionID: entity.monitoringSessionID,
            tripID: entity.tripID,
            receivedAt: entity.receivedAt,
            sample: location,
            trackingPhase: entity.trackingPhaseRaw,
            powerConnected: entity.powerConnected,
            recentPowerConnected: entity.recentPowerConnected,
            recentPowerDisconnected: entity.recentPowerDisconnected,
            trustedBluetoothVehicleHint: entity.trustedBluetoothVehicleHint,
            acceptedForDetection: entity.acceptedForDetection,
            detectionOutput: entity.detectionOutputRaw,
            detectionReason: entity.detectionReason,
            expiresAt: entity.expiresAt
        )
    }

    private func validate(_ sample: DiagnosticLocationSample) throws {
        let location = sample.sample
        guard sample.receivedAt.timeIntervalSinceReferenceDate.isFinite,
              sample.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              location.timestamp.timeIntervalSinceReferenceDate.isFinite,
              location.latitude.isFinite,
              location.longitude.isFinite,
              location.horizontalAccuracy.isFinite,
              (-90...90).contains(location.latitude),
              (-180...180).contains(location.longitude),
              location.speedMetersPerSecond?.isFinite ?? true,
              location.speedAccuracyMetersPerSecond?.isFinite ?? true,
              location.courseDegrees?.isFinite ?? true else {
            throw DiagnosticSampleStoreError.invalidSample
        }
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
