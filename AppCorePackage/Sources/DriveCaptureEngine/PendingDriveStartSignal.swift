import AppCoreModels
import Foundation

public enum PendingDriveStartSignalStatus: String, Codable, Equatable, Sendable {
    case pending
    case consumed
    case expired
}

public struct PendingDriveStartSignal: Codable, Equatable, Identifiable, Sendable {
    public static let retentionDays = 30

    public var id: UUID
    public var trigger: DriveStartExternalTrigger
    public var source: DriveStartSignalSource
    public var confidence: DriveStartSignalConfidence
    public var createdAt: Date
    public var expiresAt: Date
    public var consumedAt: Date?
    public var status: PendingDriveStartSignalStatus
    public var result: String?
    public var captureID: UUID?
    public var tripID: UUID?
    /// Explicit vehicle carried by the arming Shortcut, if any.
    public var vehicleID: UUID?

    public init(
        id: UUID = UUID(),
        trigger: DriveStartExternalTrigger,
        source: DriveStartSignalSource,
        confidence: DriveStartSignalConfidence,
        createdAt: Date,
        expiresAt: Date,
        consumedAt: Date? = nil,
        status: PendingDriveStartSignalStatus = .pending,
        result: String? = nil,
        captureID: UUID? = nil,
        tripID: UUID? = nil,
        vehicleID: UUID? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.status = status
        self.result = result
        self.captureID = captureID
        self.tripID = tripID
        self.vehicleID = vehicleID
    }

    public var driveStartSignal: DriveStartSignal {
        DriveStartSignal(
            source: source,
            confidence: confidence,
            startedAt: createdAt,
            expiresAt: expiresAt,
            pendingSignalID: id,
            vehicleID: vehicleID,
            externalTrigger: trigger
        )
    }
}

public protocol PendingDriveStartSignalPersisting: AnyObject {
    @discardableResult
    func save(trigger: DriveStartExternalTrigger, at date: Date, policy: DriveStartPolicy, vehicleID: UUID?) throws -> PendingDriveStartSignal
    func fetchPending(at date: Date) throws -> [PendingDriveStartSignal]
    func fetchSignals(since startDate: Date?, until endDate: Date?) throws -> [PendingDriveStartSignal]
    func fetchLatest() throws -> PendingDriveStartSignal?
    func markConsumed(id: UUID, consumedAt: Date, captureID: UUID?) throws
    func markExpired(now: Date) throws -> Int
    func markResult(id: UUID, result: String, tripID: UUID?) throws
}
