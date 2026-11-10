import AppCoreModels
import DriveCaptureEngine
import CoreData
import Foundation

public protocol DriveCaptureEventPersisting: AnyObject {
    @discardableResult
    func save(_ event: DriveCaptureJournalEntry) throws -> DriveCaptureJournalEntry
    func fetchEvents(since startDate: Date?, until endDate: Date?) throws -> [DriveCaptureJournalEntry]
    func purgeExpiredEvents(now: Date) throws -> Int
    func deleteAll() throws -> Int
}

public final class DriveCaptureEventStore: DriveCaptureEventPersisting {
    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    @discardableResult
    public func save(_ event: DriveCaptureJournalEntry) throws -> DriveCaptureJournalEntry {
        try context.saveTransaction {
            let entity = DriveCaptureEventEntity.insert(into: context)
            write(event, to: entity)
            return event
        }
    }

    public func fetchEvents(since startDate: Date? = nil, until endDate: Date? = nil) throws -> [DriveCaptureJournalEntry] {
        if let startDate, let endDate, startDate > endDate {
            throw DiagnosticSampleStoreError.invalidDateRange
        }
        let request = DriveCaptureEventEntity.fetchRequest()
        var predicates: [NSPredicate] = []
        if let startDate {
            predicates.append(NSPredicate(format: "date >= %@", startDate as NSDate))
        }
        if let endDate {
            predicates.append(NSPredicate(format: "date <= %@", endDate as NSDate))
        }
        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try context.fetch(request).map(mapEvent)
    }

    @discardableResult
    public func purgeExpiredEvents(now: Date = Date()) throws -> Int {
        try context.saveTransaction {
            let request = DriveCaptureEventEntity.fetchRequest()
            request.predicate = NSPredicate(format: "expiresAt < %@", now as NSDate)
            let events = try context.fetch(request)
            for event in events {
                context.delete(event)
            }
            return events.count
        }
    }

    @discardableResult
    public func deleteAll() throws -> Int {
        try context.saveTransaction {
            let events = try context.fetch(DriveCaptureEventEntity.fetchRequest())
            events.forEach(context.delete)
            return events.count
        }
    }

    private func write(_ event: DriveCaptureJournalEntry, to entity: DriveCaptureEventEntity) {
        entity.id = event.id
        entity.date = event.date
        entity.category = event.category
        entity.message = event.message
        entity.monitoringSessionID = event.monitoringSessionID
        entity.captureID = event.captureID
        entity.tripID = event.tripID
        entity.trackingPhaseRaw = event.trackingPhase
        entity.activityLevelRaw = event.activityLevel
        entity.wakeReason = event.wakeReason
        entity.sampleTimestamp = event.sampleTimestamp
        entity.staleDelaySeconds = event.staleDelaySeconds.asNSNumber
        entity.powerConnected = event.powerConnected
        entity.recentPowerConnected = event.recentPowerConnected
        entity.recentPowerDisconnected = event.recentPowerDisconnected
        entity.trustedBluetoothVehicleHint = event.trustedBluetoothVehicleHint
        entity.detectionOutputRaw = event.detectionOutput
        entity.detectionReason = event.detectionReason
        entity.expiresAt = event.expiresAt
    }

    private func mapEvent(_ entity: DriveCaptureEventEntity) -> DriveCaptureJournalEntry {
        DriveCaptureJournalEntry(
            id: entity.id,
            date: entity.date,
            category: entity.category,
            message: entity.message,
            monitoringSessionID: entity.monitoringSessionID,
            captureID: entity.captureID,
            tripID: entity.tripID,
            trackingPhase: entity.trackingPhaseRaw,
            activityLevel: entity.activityLevelRaw,
            wakeReason: entity.wakeReason,
            sampleTimestamp: entity.sampleTimestamp,
            staleDelaySeconds: entity.staleDelaySeconds?.doubleValue,
            powerConnected: entity.powerConnected,
            recentPowerConnected: entity.recentPowerConnected,
            recentPowerDisconnected: entity.recentPowerDisconnected,
            trustedBluetoothVehicleHint: entity.trustedBluetoothVehicleHint,
            detectionOutput: entity.detectionOutputRaw,
            detectionReason: entity.detectionReason,
            expiresAt: entity.expiresAt
        )
    }
}
