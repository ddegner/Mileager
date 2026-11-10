import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public final class PendingDriveStartSignalStore: PendingDriveStartSignalPersisting {
    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    @discardableResult
    public func save(
        trigger: DriveStartExternalTrigger,
        at date: Date = Date(),
        policy: DriveStartPolicy = .balanced,
        vehicleID: UUID? = nil
    ) throws -> PendingDriveStartSignal {
        let signal = DriveStartEngine.signal(forExternalTrigger: trigger, at: date, policy: policy)
        let pending = PendingDriveStartSignal(
            trigger: trigger,
            source: signal.source,
            confidence: signal.confidence,
            createdAt: date,
            expiresAt: signal.expiresAt,
            vehicleID: vehicleID
        )
        try context.saveTransaction {
            let entity = PendingDriveStartSignalEntity.insert(into: context)
            write(pending, to: entity)
        }
        return pending
    }

    public func fetchPending(at date: Date = Date()) throws -> [PendingDriveStartSignal] {
        _ = try markExpired(now: date)
        let request = PendingDriveStartSignalEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "statusRaw == %@ AND expiresAt >= %@",
            PendingDriveStartSignalStatus.pending.rawValue,
            date as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try context.fetch(request).map(map)
    }

    public func fetchSignals(since startDate: Date? = nil, until endDate: Date? = nil) throws -> [PendingDriveStartSignal] {
        if let startDate, let endDate, startDate > endDate {
            throw DiagnosticSampleStoreError.invalidDateRange
        }
        let request = PendingDriveStartSignalEntity.fetchRequest()
        var predicates: [NSPredicate] = []
        if let startDate {
            predicates.append(NSPredicate(format: "createdAt >= %@", startDate as NSDate))
        }
        if let endDate {
            predicates.append(NSPredicate(format: "createdAt <= %@", endDate as NSDate))
        }
        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        return try context.fetch(request).map(map)
    }

    public func fetchLatest() throws -> PendingDriveStartSignal? {
        let request = PendingDriveStartSignalEntity.fetchRequest()
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request).first.map(map)
    }

    public func markConsumed(id: UUID, consumedAt: Date = Date(), captureID: UUID? = nil) throws {
        try context.saveTransaction {
            guard let entity = try PendingDriveStartSignalEntity.fetchOne(
                in: context,
                where: NSPredicate(format: "id == %@", id as NSUUID)
            ) else {
                return
            }
            entity.statusRaw = PendingDriveStartSignalStatus.consumed.rawValue
            entity.consumedAt = consumedAt
            entity.captureID = captureID
            entity.updatedAt = consumedAt
        }
    }

    @discardableResult
    public func markExpired(now: Date = Date()) throws -> Int {
        try context.saveTransaction {
            let request = PendingDriveStartSignalEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "statusRaw == %@ AND expiresAt < %@",
                PendingDriveStartSignalStatus.pending.rawValue,
                now as NSDate
            )
            let entities = try context.fetch(request)
            for entity in entities {
                entity.statusRaw = PendingDriveStartSignalStatus.expired.rawValue
                entity.resultRaw = "expired before runtime consumed it"
                entity.updatedAt = now
            }
            return entities.count
        }
    }

    public func markResult(id: UUID, result: String, tripID: UUID? = nil) throws {
        try context.saveTransaction {
            guard let entity = try PendingDriveStartSignalEntity.fetchOne(
                in: context,
                where: NSPredicate(format: "id == %@", id as NSUUID)
            ) else {
                return
            }
            entity.resultRaw = result
            entity.tripID = tripID
            entity.updatedAt = Date()
        }
    }

    @discardableResult
    public func purgeResolved(before cutoff: Date) throws -> Int {
        try context.saveTransaction {
            let request = PendingDriveStartSignalEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "statusRaw IN %@ AND updatedAt < %@",
                [
                    PendingDriveStartSignalStatus.consumed.rawValue,
                    PendingDriveStartSignalStatus.expired.rawValue
                ],
                cutoff as NSDate
            )
            let entities = try context.fetch(request)
            entities.forEach(context.delete)
            return entities.count
        }
    }

    private func write(_ pending: PendingDriveStartSignal, to entity: PendingDriveStartSignalEntity) {
        entity.id = pending.id
        entity.triggerRaw = pending.trigger.rawValue
        entity.sourceRaw = pending.source.rawValue
        entity.confidenceRaw = pending.confidence.rawValue
        entity.createdAt = pending.createdAt
        entity.expiresAt = pending.expiresAt
        entity.consumedAt = pending.consumedAt
        entity.statusRaw = pending.status.rawValue
        entity.resultRaw = pending.result
        entity.captureID = pending.captureID
        entity.tripID = pending.tripID
        entity.vehicleID = pending.vehicleID
        entity.updatedAt = pending.createdAt
    }

    private func map(_ entity: PendingDriveStartSignalEntity) -> PendingDriveStartSignal {
        PendingDriveStartSignal(
            id: entity.id,
            trigger: DriveStartExternalTrigger(rawValue: entity.triggerRaw) ?? .manual,
            source: DriveStartSignalSource(rawValue: entity.sourceRaw) ?? .externalVehicleAutomation,
            confidence: DriveStartSignalConfidence(rawValue: entity.confidenceRaw) ?? .assist,
            createdAt: entity.createdAt,
            expiresAt: entity.expiresAt,
            consumedAt: entity.consumedAt,
            status: PendingDriveStartSignalStatus(rawValue: entity.statusRaw) ?? .pending,
            result: entity.resultRaw,
            captureID: entity.captureID,
            tripID: entity.tripID,
            vehicleID: entity.vehicleID
        )
    }
}

public extension Notification.Name {
    static let pendingDriveStartSignalCreated = Notification.Name("MileageTrackerPendingDriveStartSignalCreated")
}
