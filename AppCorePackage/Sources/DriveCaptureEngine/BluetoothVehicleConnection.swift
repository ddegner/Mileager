import AppCoreModels
import Foundation

public enum BluetoothSignalSource: String, Codable, CaseIterable, Sendable {
    case audioRoute
    case blePeripheral
}

/// User-meaningful kind of vehicle connection. Unlike `BluetoothSignalSource`,
/// this distinguishes CarPlay from ordinary Bluetooth audio and is safe to
/// include in the synced semantic alias.
public enum VehicleConnectionKind: String, Codable, CaseIterable, Sendable {
    case carPlay
    case bluetooth
    case unknown

    public var isKnown: Bool { self != .unknown }
}

/// Strength of the device-local identifier behind a connection hint. Raw
/// identifiers never leave the Local store; this value only controls whether a
/// hint may be used silently or must stay a user-confirmed suggestion.
public enum VehicleConnectionIdentityQuality: String, Codable, CaseIterable, Sendable {
    case stablePortIdentifier
    case fallbackPortName
    case unknown
}

public enum VehicleConnectionMappingDisposition: String, Codable, CaseIterable, Sendable {
    case unreviewed
    /// User chose "Ask me later". A new observation after `mappingUpdatedAt`
    /// makes it eligible again, so an immediate relaunch does not re-prompt.
    case deferred
    case assigned
    case ignored
}

/// Cloud-backed, user-approved association between a recognizable connection
/// label/kind and a vehicle. It deliberately contains no raw or salted device
/// identifier.
public struct VehicleConnectionAlias: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var vehicleID: UUID
    public var displayName: String
    public var connectionKind: VehicleConnectionKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        vehicleID: UUID,
        displayName: String,
        connectionKind: VehicleConnectionKind,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.displayName = displayName
        self.connectionKind = connectionKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A synced alias that appears to describe an unreviewed local connection.
/// Merely returning this value never binds the connection; callers must invoke
/// `confirmSuggestion(identifierHash:aliasID:)` after explicit user approval.
public struct VehicleConnectionSuggestion: Equatable, Sendable {
    public var alias: VehicleConnectionAlias
    public var vehicleID: UUID { alias.vehicleID }

    public init(alias: VehicleConnectionAlias) {
        self.alias = alias
    }
}

public struct BluetoothDriveObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var identifierHash: String
    public var displayName: String?
    public var source: BluetoothSignalSource
    public var connectionKind: VehicleConnectionKind
    public var identityQuality: VehicleConnectionIdentityQuality
    public var observedAt: Date

    public init(
        id: UUID = UUID(),
        identifierHash: String,
        displayName: String? = nil,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind = .unknown,
        identityQuality: VehicleConnectionIdentityQuality = .unknown,
        observedAt: Date
    ) {
        self.id = id
        self.identifierHash = identifierHash
        self.displayName = displayName
        self.source = source
        self.connectionKind = connectionKind
        self.identityQuality = identityQuality
        self.observedAt = observedAt
    }
}

public struct BluetoothDriveHint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var identifierHash: String
    public var displayName: String?
    public var source: BluetoothSignalSource
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var correlationCount: Int
    public var notADriveCount: Int
    public var trusted: Bool
    /// Legacy manual override from the removed Trusted Vehicles settings UI.
    /// Converted into counter seeds by `migrateManualTrustOverridesIfNeeded`.
    public var manualTrustOverride: Bool?
    /// Vehicle this device is mapped to, if the user linked it. The mapping is
    /// local to this device (identifier hashes are salted per device), so it
    /// must be re-created on each iPhone.
    public var vehicleID: UUID?
    /// Cloud alias bound to this phone's salted local identifier, if any.
    public var connectionAliasID: UUID?
    public var connectionKind: VehicleConnectionKind
    public var identityQuality: VehicleConnectionIdentityQuality
    public var mappingDisposition: VehicleConnectionMappingDisposition
    public var mappingUpdatedAt: Date?

    /// Negative review evidence dominates this device: it no longer
    /// contributes start signals of any strength.
    public var blocked: Bool {
        VehicleTrustPolicy().isBlocked(confirmed: correlationCount, notADrive: notADriveCount)
    }

    /// Whether this local connection may contribute start/trust evidence. An
    /// ignored connection keeps its historical learning counters but behaves as
    /// absent until the user clears that decision.
    public var contributesDriveDetection: Bool {
        mappingDisposition != .ignored && !blocked
    }

    public var canIdentifyVehicleSilently: Bool {
        identityQuality == .stablePortIdentifier
            && mappingDisposition == .assigned
            && vehicleID != nil
    }

    public init(
        id: UUID = UUID(),
        identifierHash: String,
        displayName: String? = nil,
        source: BluetoothSignalSource,
        firstSeenAt: Date,
        lastSeenAt: Date,
        correlationCount: Int = 0,
        notADriveCount: Int = 0,
        trusted: Bool = false,
        manualTrustOverride: Bool? = nil,
        vehicleID: UUID? = nil,
        connectionAliasID: UUID? = nil,
        connectionKind: VehicleConnectionKind = .unknown,
        identityQuality: VehicleConnectionIdentityQuality = .unknown,
        mappingDisposition: VehicleConnectionMappingDisposition = .unreviewed,
        mappingUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.identifierHash = identifierHash
        self.displayName = displayName
        self.source = source
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.correlationCount = correlationCount
        self.notADriveCount = notADriveCount
        self.trusted = trusted
        self.manualTrustOverride = manualTrustOverride
        self.vehicleID = vehicleID
        self.connectionAliasID = connectionAliasID
        self.connectionKind = connectionKind
        self.identityQuality = identityQuality
        self.mappingDisposition = vehicleID != nil && mappingDisposition == .unreviewed
            ? .assigned
            : mappingDisposition
        self.mappingUpdatedAt = mappingUpdatedAt
    }
}

/// How a user review decision should adjust trust evidence for the Bluetooth
/// devices observed at a drive's start.
public enum VehicleReviewOutcome: Sendable {
    case confirmedDrive
    case notADrive
    case undoConfirmedDrive
    case undoNotADrive
}
