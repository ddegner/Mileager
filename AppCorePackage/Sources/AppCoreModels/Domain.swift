import Foundation

public enum TripClassification: String, Codable, CaseIterable, Identifiable, Sendable {
    case business
    case personal
    case notADrive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .business: String(localized: "Business", bundle: .appCoreStrings)
        case .personal: String(localized: "Personal", bundle: .appCoreStrings)
        case .notADrive: String(localized: "Not a Drive", bundle: .appCoreStrings)
        }
    }

    /// Whether trips with this classification represent real vehicle drives
    /// that count toward mileage totals, reports, and exports.
    public var countsAsDrive: Bool {
        self != .notADrive
    }

    /// The glyph the live drive bar and the Live Activity use for this
    /// classification. `nil` for `.notADrive`: neither surface offers it as a
    /// choice, so neither has a badge for it.
    public var symbolName: String? {
        switch self {
        case .business: "briefcase.fill"
        case .personal: "person.fill"
        case .notADrive: nil
        }
    }
}

/// How a trip's classification was assigned when it wasn't a user decision.
/// Absent for user-reviewed trips.
public enum TripClassificationSource: String, Codable, Sendable {
    /// Auto-marked Not a Drive by the post-completion transit classifier.
    case autoTransit
    /// Auto-discarded by the conservative short/confined post-parking classifier.
    /// The raw value remains stable for legacy rows created by the former
    /// distance-only short-trip rule.
    case autoShortTrip
    /// Auto-marked Not a Drive when a route is confidently identified as
    /// mostly over water with little automotive motion.
    case autoWater
    /// Auto-discarded by the post-completion aircraft classifier: fixes at or
    /// above 90 m/s, sustained or corroborated by a long GPS blackout jump.
    case autoAircraft
    /// Auto-discarded by the post-completion cycling classifier: CoreMotion
    /// reported high-confidence cycling shortly before the capture began and
    /// again during or right after it, no vehicle connection was present, and
    /// the capture never exceeded bicycle speed.
    case autoCycling
}

/// How a trip was attributed to a vehicle. A `.manual` assignment is never
/// overridden by automatic re-attribution.
public enum VehicleAssignmentSource: String, Codable, Sendable {
    /// The arming Shortcut carried an explicit vehicle.
    case shortcut
    /// Resolved from a learned Bluetooth-device → vehicle mapping.
    case bluetooth
    /// Resolved from a confirmed CarPlay or Bluetooth connection mapping.
    /// The older `.bluetooth` value remains readable for historical trips.
    case vehicleConnection
    /// Chosen by the user in trip UI or the retroactive re-attribution tool.
    case manual
}

/// A vehicle profile. Trips, odometer checkpoints, and Bluetooth-device
/// mappings can reference one by `id`.
public struct Vehicle: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Optional hex string (e.g. "#34C759") used for the vehicle's color accent.
    public var colorHex: String?
    /// Optional SF Symbol name (e.g. "car.fill") for the vehicle's glyph.
    public var symbolName: String?
    public var createdAt: Date
    public var sortOrder: Int
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        symbolName: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

public enum ReviewStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case needsReview
    case needsAttention
    case readyToExport

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .needsReview: String(localized: "Needs Review", bundle: .appCoreStrings)
        case .needsAttention: String(localized: "Needs Attention", bundle: .appCoreStrings)
        case .readyToExport: String(localized: "Ready to Export", bundle: .appCoreStrings)
        }
    }
}

public enum MotionHint: String, Codable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

public enum MotionConfidence: String, Codable, Sendable {
    case low
    case medium
    case high
    case unknown
}

public struct MotionActivitySnapshot: Codable, Equatable, Sendable {
    public var startDate: Date
    public var confidence: MotionConfidence
    public var hints: [MotionHint]

    public init(startDate: Date, confidence: MotionConfidence = .unknown, hints: [MotionHint]) {
        self.startDate = startDate
        self.confidence = confidence
        self.hints = hints.isEmpty ? [.unknown] : hints
    }

    public func contains(_ hint: MotionHint) -> Bool {
        hints.contains(hint)
    }
}

public struct TripDetectionContext: Equatable, Sendable {
    public var trustedBluetoothVehicleHint: Bool
    public var powerConnected: Bool
    public var recentPowerConnected: Bool
    public var recentPowerDisconnected: Bool

    public init(
        trustedBluetoothVehicleHint: Bool = false,
        powerConnected: Bool = false,
        recentPowerConnected: Bool = false,
        recentPowerDisconnected: Bool = false
    ) {
        self.trustedBluetoothVehicleHint = trustedBluetoothVehicleHint
        self.powerConnected = powerConnected
        self.recentPowerConnected = recentPowerConnected
        self.recentPowerDisconnected = recentPowerDisconnected
    }
}

public struct LocationSample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    public var speedMetersPerSecond: Double?
    public var speedAccuracyMetersPerSecond: Double?
    public var courseDegrees: Double?
    public var motionHint: MotionHint
    public var motionActivity: MotionActivitySnapshot?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        speedMetersPerSecond: Double? = nil,
        speedAccuracyMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        motionHint: MotionHint = .unknown,
        motionActivity: MotionActivitySnapshot? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speedMetersPerSecond = speedMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.courseDegrees = courseDegrees
        self.motionHint = motionHint
        self.motionActivity = motionActivity
    }
}

public struct DiagnosticLocationSample: Codable, Equatable, Identifiable, Sendable {
    public static let retentionDays = 30

    public var id: UUID
    public var monitoringSessionID: UUID
    public var tripID: UUID?
    public var receivedAt: Date
    public var sample: LocationSample
    public var trackingPhase: String
    public var powerConnected: Bool
    public var recentPowerConnected: Bool
    public var recentPowerDisconnected: Bool
    public var trustedBluetoothVehicleHint: Bool
    public var acceptedForDetection: Bool
    public var detectionOutput: String?
    public var detectionReason: String?
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        monitoringSessionID: UUID,
        tripID: UUID? = nil,
        receivedAt: Date,
        sample: LocationSample,
        trackingPhase: String,
        powerConnected: Bool,
        recentPowerConnected: Bool,
        recentPowerDisconnected: Bool,
        trustedBluetoothVehicleHint: Bool,
        acceptedForDetection: Bool,
        detectionOutput: String? = nil,
        detectionReason: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.monitoringSessionID = monitoringSessionID
        self.tripID = tripID
        self.receivedAt = receivedAt
        self.sample = sample
        self.trackingPhase = trackingPhase
        self.powerConnected = powerConnected
        self.recentPowerConnected = recentPowerConnected
        self.recentPowerDisconnected = recentPowerDisconnected
        self.trustedBluetoothVehicleHint = trustedBluetoothVehicleHint
        self.acceptedForDetection = acceptedForDetection
        self.detectionOutput = detectionOutput
        self.detectionReason = detectionReason
        self.expiresAt = expiresAt
    }
}

public struct DriveCaptureJournalEntry: Codable, Equatable, Identifiable, Sendable {
    public static let retentionDays = 30

    public var id: UUID
    public var date: Date
    public var category: String
    public var message: String
    public var monitoringSessionID: UUID?
    public var captureID: UUID?
    public var tripID: UUID?
    public var trackingPhase: String?
    public var activityLevel: String?
    public var wakeReason: String?
    public var sampleTimestamp: Date?
    public var staleDelaySeconds: Double?
    public var powerConnected: Bool
    public var recentPowerConnected: Bool
    public var recentPowerDisconnected: Bool
    public var trustedBluetoothVehicleHint: Bool
    public var detectionOutput: String?
    public var detectionReason: String?
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        category: String,
        message: String,
        monitoringSessionID: UUID? = nil,
        captureID: UUID? = nil,
        tripID: UUID? = nil,
        trackingPhase: String? = nil,
        activityLevel: String? = nil,
        wakeReason: String? = nil,
        sampleTimestamp: Date? = nil,
        staleDelaySeconds: Double? = nil,
        powerConnected: Bool = false,
        recentPowerConnected: Bool = false,
        recentPowerDisconnected: Bool = false,
        trustedBluetoothVehicleHint: Bool = false,
        detectionOutput: String? = nil,
        detectionReason: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.date = date
        self.category = category
        self.message = message
        self.monitoringSessionID = monitoringSessionID
        self.captureID = captureID
        self.tripID = tripID
        self.trackingPhase = trackingPhase
        self.activityLevel = activityLevel
        self.wakeReason = wakeReason
        self.sampleTimestamp = sampleTimestamp
        self.staleDelaySeconds = staleDelaySeconds
        self.powerConnected = powerConnected
        self.recentPowerConnected = recentPowerConnected
        self.recentPowerDisconnected = recentPowerDisconnected
        self.trustedBluetoothVehicleHint = trustedBluetoothVehicleHint
        self.detectionOutput = detectionOutput
        self.detectionReason = detectionReason
        self.expiresAt = expiresAt
    }
}

public struct DiagnosticSampleBurstSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var firstReceivedAt: Date
    public var lastReceivedAt: Date
    public var sampleCount: Int
    public var acceptedSampleCount: Int
    public var staleSampleCount: Int
    public var maxStaleDelaySeconds: Double
    public var distanceMeters: Double
    public var maxSpeedMetersPerSecond: Double?
    public var medianHorizontalAccuracyMeters: Double?
    public var monitoringSessionIDs: [UUID]
    public var tripIDs: [UUID]
    public var trackingPhases: [String: Int]
    public var motionHints: [String: Int]
    public var detectionOutputs: [String: Int]
    public var detectionReasons: [String: Int]
    public var trustedBluetoothSampleCount: Int
    public var powerConnectedSampleCount: Int
    public var recentPowerConnectedSampleCount: Int
    public var recentPowerDisconnectedSampleCount: Int

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date,
        firstReceivedAt: Date,
        lastReceivedAt: Date,
        sampleCount: Int,
        acceptedSampleCount: Int,
        staleSampleCount: Int,
        maxStaleDelaySeconds: Double,
        distanceMeters: Double,
        maxSpeedMetersPerSecond: Double?,
        medianHorizontalAccuracyMeters: Double?,
        monitoringSessionIDs: [UUID],
        tripIDs: [UUID],
        trackingPhases: [String: Int],
        motionHints: [String: Int],
        detectionOutputs: [String: Int],
        detectionReasons: [String: Int],
        trustedBluetoothSampleCount: Int,
        powerConnectedSampleCount: Int,
        recentPowerConnectedSampleCount: Int,
        recentPowerDisconnectedSampleCount: Int
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.firstReceivedAt = firstReceivedAt
        self.lastReceivedAt = lastReceivedAt
        self.sampleCount = sampleCount
        self.acceptedSampleCount = acceptedSampleCount
        self.staleSampleCount = staleSampleCount
        self.maxStaleDelaySeconds = maxStaleDelaySeconds
        self.distanceMeters = distanceMeters
        self.maxSpeedMetersPerSecond = maxSpeedMetersPerSecond
        self.medianHorizontalAccuracyMeters = medianHorizontalAccuracyMeters
        self.monitoringSessionIDs = monitoringSessionIDs
        self.tripIDs = tripIDs
        self.trackingPhases = trackingPhases
        self.motionHints = motionHints
        self.detectionOutputs = detectionOutputs
        self.detectionReasons = detectionReasons
        self.trustedBluetoothSampleCount = trustedBluetoothSampleCount
        self.powerConnectedSampleCount = powerConnectedSampleCount
        self.recentPowerConnectedSampleCount = recentPowerConnectedSampleCount
        self.recentPowerDisconnectedSampleCount = recentPowerDisconnectedSampleCount
    }
}

public struct PossibleDriveCandidate: Codable, Equatable, Identifiable, Sendable {
    public static let attentionReason = "Possible drive reconstructed from sparse or delayed diagnostic samples"

    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var sampleCount: Int
    public var acceptedSampleCount: Int
    public var staleSampleCount: Int
    public var distanceMeters: Double
    public var confidence: String
    public var reasons: [String]
    public var monitoringSessionIDs: [UUID]
    public var linkedTripIDs: [UUID]
    public var reviewStatus: ReviewStatus
    public var needsAttention: Bool

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date,
        sampleCount: Int,
        acceptedSampleCount: Int,
        staleSampleCount: Int,
        distanceMeters: Double,
        confidence: String = "low",
        reasons: [String],
        monitoringSessionIDs: [UUID],
        linkedTripIDs: [UUID],
        reviewStatus: ReviewStatus = .needsAttention,
        needsAttention: Bool = true
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.sampleCount = sampleCount
        self.acceptedSampleCount = acceptedSampleCount
        self.staleSampleCount = staleSampleCount
        self.distanceMeters = distanceMeters
        self.confidence = confidence
        self.reasons = reasons
        self.monitoringSessionIDs = monitoringSessionIDs
        self.linkedTripIDs = linkedTripIDs
        self.reviewStatus = reviewStatus
        self.needsAttention = needsAttention
    }
}

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct TripEndpointAddressComponents: Codable, Equatable, Sendable {
    public var streetNumber: String?
    public var streetName: String?
    public var neighborhood: String?
    public var city: String?
    public var state: String?
    public var country: String?
    public var countryCode: String?

    public init(
        streetNumber: String? = nil,
        streetName: String? = nil,
        neighborhood: String? = nil,
        city: String? = nil,
        state: String? = nil,
        country: String? = nil,
        countryCode: String? = nil
    ) {
        self.streetNumber = Self.normalized(streetNumber)
        self.streetName = Self.normalized(streetName)
        self.neighborhood = Self.normalized(neighborhood)
        self.city = Self.normalized(city)
        self.state = Self.normalized(state)
        self.country = Self.normalized(country)
        self.countryCode = Self.normalized(countryCode)
    }

    public var streetLine: String? {
        guard let streetName else { return nil }
        let value = [streetNumber, streetName]
            .compactMap { $0 }
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    public var hasDisplayableComponent: Bool {
        streetLine != nil || neighborhood != nil || city != nil || state != nil || country != nil
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

public struct TripLeg: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceTripID: UUID?
    public var captureSource: String
    public var startDate: Date
    public var endDate: Date
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var startAddress: String?
    public var endAddress: String?
    public var startAddressComponents: TripEndpointAddressComponents?
    public var endAddressComponents: TripEndpointAddressComponents?
    public var distanceMeters: Double
    public var routePolyline: String?
    public var tollsAmount: Double
    public var parkingAmount: Double
    public var stopDurationAfterSeconds: Double?

    public init(
        id: UUID = UUID(),
        sourceTripID: UUID? = nil,
        captureSource: String,
        startDate: Date,
        endDate: Date,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        startAddress: String?,
        endAddress: String?,
        distanceMeters: Double,
        routePolyline: String?,
        tollsAmount: Double = 0,
        parkingAmount: Double = 0,
        stopDurationAfterSeconds: Double? = nil
    ) {
        self.id = id
        self.sourceTripID = sourceTripID
        self.captureSource = captureSource
        self.startDate = startDate
        self.endDate = endDate
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.distanceMeters = distanceMeters
        self.routePolyline = routePolyline
        self.tollsAmount = tollsAmount
        self.parkingAmount = parkingAmount
        self.stopDurationAfterSeconds = stopDurationAfterSeconds
    }

    public var durationSeconds: Double {
        max(0, endDate.timeIntervalSince(startDate))
    }

    public var miles: Double {
        DistanceConversion.miles(fromMeters: distanceMeters)
    }

    public var routeSegments: [[Coordinate]] {
        if let routePolyline,
           let segments = EncodedPolyline.decodeSegments(routePolyline),
           !segments.isEmpty {
            return segments
        }
        let endpoints = [startCoordinate, endCoordinate].compactMap { $0 }
        return endpoints.count >= 2 ? [endpoints] : []
    }
}

extension Array where Element == TripLeg {
    /// A later-starting capture may finish inside an earlier one. Array order
    /// describes the legs, while these indices describe the whole trip's span.
    package var tripBoundaryIndices: (start: Int, end: Int)? {
        guard let start = indices.min(by: { lhs, rhs in
            if self[lhs].startDate != self[rhs].startDate {
                return self[lhs].startDate < self[rhs].startDate
            }
            return self[lhs].id.uuidString < self[rhs].id.uuidString
        }), let end = indices.max(by: { lhs, rhs in
            if self[lhs].endDate != self[rhs].endDate {
                return self[lhs].endDate < self[rhs].endDate
            }
            if self[lhs].startDate != self[rhs].startDate {
                return self[lhs].startDate < self[rhs].startDate
            }
            return self[lhs].id.uuidString < self[rhs].id.uuidString
        }) else { return nil }
        return (start, end)
    }
}

public struct TripLegConnector: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var fromLegID: UUID
    public var toLegID: UUID
    public var startCoordinate: Coordinate
    public var endCoordinate: Coordinate
    public var startAddress: String?
    public var endAddress: String?
    public var distanceMeters: Double
    public var routePolyline: String?

    public init(
        id: UUID = UUID(),
        fromLegID: UUID,
        toLegID: UUID,
        startCoordinate: Coordinate,
        endCoordinate: Coordinate,
        startAddress: String? = nil,
        endAddress: String? = nil,
        distanceMeters: Double,
        routePolyline: String? = nil
    ) {
        self.id = id
        self.fromLegID = fromLegID
        self.toLegID = toLegID
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.distanceMeters = distanceMeters
        self.routePolyline = routePolyline
    }

    public var miles: Double {
        DistanceConversion.miles(fromMeters: distanceMeters)
    }

    public var routeSegments: [[Coordinate]] {
        if let routePolyline,
           let segments = EncodedPolyline.decodeSegments(routePolyline),
           !segments.isEmpty {
            return segments
        }
        return [[startCoordinate, endCoordinate]]
    }
}

public struct TripDisplayLeg: Identifiable, Equatable, Sendable {
    public var leg: TripLeg
    public var incomingConnector: TripLegConnector?

    public init(leg: TripLeg, incomingConnector: TripLegConnector? = nil) {
        self.leg = leg
        self.incomingConnector = incomingConnector
    }

    public var id: UUID { leg.id }
    public var startDate: Date { leg.startDate }
    public var endDate: Date { leg.endDate }
    public var startCoordinate: Coordinate? { incomingConnector?.startCoordinate ?? leg.startCoordinate }
    public var endCoordinate: Coordinate? { leg.endCoordinate }
    public var startAddress: String? { incomingConnector?.startAddress ?? leg.startAddress }
    public var endAddress: String? { leg.endAddress }
    public var distanceMeters: Double { leg.distanceMeters + (incomingConnector?.distanceMeters ?? 0) }
    public var miles: Double { DistanceConversion.miles(fromMeters: distanceMeters) }
    public var stopDurationAfterSeconds: Double? { leg.stopDurationAfterSeconds }
}

public struct TripStop: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var arrivedAt: Date
    public var departedAt: Date
    public var coordinate: Coordinate?
    public var address: String?

    public init(
        id: UUID = UUID(),
        arrivedAt: Date,
        departedAt: Date,
        coordinate: Coordinate?,
        address: String?
    ) {
        self.id = id
        self.arrivedAt = arrivedAt
        self.departedAt = departedAt
        self.coordinate = coordinate
        self.address = address
    }

    public var durationSeconds: Double {
        max(0, departedAt.timeIntervalSince(arrivedAt))
    }
}

public struct TripRouteSummary: Codable, Equatable, Sendable {
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var routePolyline: String?
    public var segments: [[Coordinate]]

    public init(legs: [TripLeg], connectors: [TripLegConnector]) {
        let boundaries = legs.tripBoundaryIndices
        startCoordinate = boundaries.flatMap { legs[$0.start].startCoordinate }
        endCoordinate = boundaries.flatMap { legs[$0.end].endCoordinate }
        let connectorsByToLegID = Dictionary(grouping: connectors, by: \.toLegID)
        segments = legs.flatMap { leg in
            (connectorsByToLegID[leg.id] ?? []).flatMap(\.routeSegments) + leg.routeSegments
        }
        routePolyline = segments.isEmpty ? nil : EncodedPolyline.encodeSegments(segments)
    }
}

public struct TripDraft: Codable, Equatable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var samples: [LocationSample]
    public var distanceMeters: Double
    public var attentionReasons: [String]
    public var classification: TripClassification?
    public var businessPurpose: String?
    public var fees: [TripFee]
    public var notes: String?
    /// Vehicle carried from the arming Shortcut, if any. `nil` when the drive
    /// wasn't armed with an explicit vehicle.
    public var vehicleID: UUID?
    public var vehicleAssignmentSource: VehicleAssignmentSource?
    /// Other confidently mapped vehicles observed after the first connection
    /// latched. Persisting this on the pending draft keeps the post-trip choice
    /// intact across background completion and process restoration.
    public var conflictingVehicleIDs: [UUID]
    /// Start times of the high-confidence CoreMotion cycling snapshots the
    /// reducer saw around this capture: shortly before it began, during it,
    /// and the one that parked it. The reducer is the only component that
    /// sees those snapshots, so it carries them here for the completion
    /// classifiers. Sorted ascending.
    public var cyclingMotionDates: [Date]
    /// True when the reducer knew a trusted vehicle connection to be live at
    /// any point from shortly before the start through the end of the capture.
    public var vehicleConnectionObserved: Bool

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        samples: [LocationSample],
        distanceMeters: Double,
        attentionReasons: [String] = [],
        classification: TripClassification? = nil,
        businessPurpose: String? = nil,
        fees: [TripFee] = [],
        notes: String? = nil,
        vehicleID: UUID? = nil,
        vehicleAssignmentSource: VehicleAssignmentSource? = nil,
        conflictingVehicleIDs: [UUID] = [],
        cyclingMotionDates: [Date] = [],
        vehicleConnectionObserved: Bool = false
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.samples = samples
        self.distanceMeters = distanceMeters
        self.attentionReasons = attentionReasons
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.fees = fees
        self.notes = notes
        self.vehicleID = vehicleID
        self.vehicleAssignmentSource = vehicleAssignmentSource
        self.conflictingVehicleIDs = Array(Set(conflictingVehicleIDs))
            .filter { $0 != vehicleID }
            .sorted { $0.uuidString < $1.uuidString }
        self.cyclingMotionDates = cyclingMotionDates.sorted()
        self.vehicleConnectionObserved = vehicleConnectionObserved
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startDate
        case endDate
        case samples
        case distanceMeters
        case attentionReasons
        case classification
        case businessPurpose
        case fees
        case notes
        case vehicleID
        case vehicleAssignmentSource
        case conflictingVehicleIDs
        case cyclingMotionDates
        case vehicleConnectionObserved
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        samples = try container.decodeIfPresent([LocationSample].self, forKey: .samples) ?? []
        distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
        attentionReasons = try container.decodeIfPresent([String].self, forKey: .attentionReasons) ?? []
        classification = try container.decodeIfPresent(TripClassification.self, forKey: .classification)
        businessPurpose = try container.decodeIfPresent(String.self, forKey: .businessPurpose)
        fees = try container.decodeIfPresent([TripFee].self, forKey: .fees) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        let decodedVehicleID = try container.decodeIfPresent(UUID.self, forKey: .vehicleID)
        vehicleID = decodedVehicleID
        vehicleAssignmentSource = try container.decodeIfPresent(VehicleAssignmentSource.self, forKey: .vehicleAssignmentSource)
        conflictingVehicleIDs = Array(Set(
            try container.decodeIfPresent([UUID].self, forKey: .conflictingVehicleIDs) ?? []
        ))
        .filter { $0 != decodedVehicleID }
        .sorted { $0.uuidString < $1.uuidString }
        // Drafts checkpointed by builds before the cycling classifier carry
        // neither key; they simply have no cycling evidence.
        cyclingMotionDates = (try container.decodeIfPresent([Date].self, forKey: .cyclingMotionDates) ?? []).sorted()
        vehicleConnectionObserved = try container.decodeIfPresent(Bool.self, forKey: .vehicleConnectionObserved) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(samples, forKey: .samples)
        try container.encode(distanceMeters, forKey: .distanceMeters)
        try container.encode(attentionReasons, forKey: .attentionReasons)
        try container.encodeIfPresent(classification, forKey: .classification)
        try container.encodeIfPresent(businessPurpose, forKey: .businessPurpose)
        try container.encode(fees, forKey: .fees)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(vehicleID, forKey: .vehicleID)
        try container.encodeIfPresent(vehicleAssignmentSource, forKey: .vehicleAssignmentSource)
        try container.encode(conflictingVehicleIDs, forKey: .conflictingVehicleIDs)
        try container.encode(cyclingMotionDates, forKey: .cyclingMotionDates)
        try container.encode(vehicleConnectionObserved, forKey: .vehicleConnectionObserved)
    }
}

public enum TripFeeCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case toll
    case parking

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toll: String(localized: "Toll", bundle: .appCoreStrings)
        case .parking: String(localized: "Parking", bundle: .appCoreStrings)
        }
    }

    /// The glyph both the live drive bar and the Live Activity use for this
    /// category. Not localized; shared so the two surfaces cannot drift.
    public var symbolName: String {
        switch self {
        case .toll: "dollarsign.circle.fill"
        case .parking: "parkingsign.circle.fill"
        }
    }

    /// "Add Toll" / "Add Parking" — the accessibility label for a control that
    /// starts fee entry, as distinct from `displayName`, which titles it.
    public var addActionName: String {
        switch self {
        case .toll: String(localized: "Add Toll", bundle: .appCoreStrings)
        case .parking: String(localized: "Add Parking", bundle: .appCoreStrings)
        }
    }
}

public enum TripFeeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case ezPassImport
    case manual
    case preset
    case liveActivity
    case legacyTotal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ezPassImport: "E-ZPass"
        case .manual: String(localized: "Manual", bundle: .appCoreStrings)
        case .preset: String(localized: "Preset", bundle: .appCoreStrings)
        case .liveActivity: String(localized: "Live Activity", bundle: .appCoreStrings)
        case .legacyTotal: String(localized: "Manual total", bundle: .appCoreStrings)
        }
    }
}

public struct TripFee: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tripID: UUID?
    public var category: TripFeeCategory
    public var amount: Double
    public var occurredAt: Date
    public var label: String?
    public var source: TripFeeSource
    public var presetID: UUID?
    public var sourceTransactionID: String?
    public var tagOrPlate: String?
    public var agency: String?
    public var entryPlaza: String?
    public var exitPlaza: String?
    public var vehicleClass: String?
    public var importedAt: Date?

    public init(
        id: UUID = UUID(),
        tripID: UUID?,
        category: TripFeeCategory,
        amount: Double,
        occurredAt: Date,
        label: String? = nil,
        source: TripFeeSource = .manual,
        presetID: UUID? = nil,
        sourceTransactionID: String? = nil,
        tagOrPlate: String? = nil,
        agency: String? = nil,
        entryPlaza: String? = nil,
        exitPlaza: String? = nil,
        vehicleClass: String? = nil,
        importedAt: Date? = nil
    ) {
        self.id = id
        self.tripID = tripID
        self.category = category
        self.amount = amount
        self.occurredAt = occurredAt
        self.label = label
        self.source = source
        self.presetID = presetID
        self.sourceTransactionID = sourceTransactionID
        self.tagOrPlate = tagOrPlate
        self.agency = agency
        self.entryPlaza = entryPlaza
        self.exitPlaza = exitPlaza
        self.vehicleClass = vehicleClass
        self.importedAt = importedAt
    }

    public var originDetail: String? {
        switch source {
        case .ezPassImport:
            return [agency, plazaSummary].compactMap(Self.nonEmpty).joined(separator: " ")
        case .manual, .preset, .liveActivity, .legacyTotal:
            return source.displayName
        }
    }

    private var plazaSummary: String? {
        if let entryPlaza = Self.nonEmpty(entryPlaza), let exitPlaza = Self.nonEmpty(exitPlaza) {
            return "\(entryPlaza) -> \(exitPlaza)"
        }
        return Self.nonEmpty(exitPlaza) ?? Self.nonEmpty(entryPlaza)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct TripFeePreset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var category: TripFeeCategory
    public var label: String
    public var amount: Double
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        category: TripFeeCategory,
        label: String,
        amount: Double,
        sortOrder: Int
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.amount = amount
        self.sortOrder = sortOrder
    }
}

public enum TripEnrichmentState: String, Codable, Sendable {
    case pending
    case complete
    case userManaged
    case unavailable
    case legacy
}

public enum TripEnrichmentComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case startAddress
    case endAddress
    case route
}

public enum TripEnrichmentFailureCategory: String, Codable, Sendable {
    case networkUnavailable
    case timedOut
    case serviceUnavailable
    case rateLimited
    case cancelled
    case invalidInput
    case missingSamples
    case unknown
}

public struct TripEnrichmentAttempt: Equatable, Sendable {
    public var tripID: UUID
    public var component: TripEnrichmentComponent
    public var lastAttemptAt: Date
    public var consecutiveFailures: Int
    public var failureCategory: TripEnrichmentFailureCategory

    public init(
        tripID: UUID,
        component: TripEnrichmentComponent,
        lastAttemptAt: Date,
        consecutiveFailures: Int,
        failureCategory: TripEnrichmentFailureCategory
    ) {
        self.tripID = tripID
        self.component = component
        self.lastAttemptAt = lastAttemptAt
        self.consecutiveFailures = consecutiveFailures
        self.failureCategory = failureCategory
    }

    public var nextEligibleAt: Date {
        lastAttemptAt.addingTimeInterval(Self.retryDelay(forConsecutiveFailures: consecutiveFailures))
    }

    public static func retryDelay(forConsecutiveFailures failureCount: Int) -> TimeInterval {
        switch max(1, failureCount) {
        case 1: 5 * 60
        case 2: 30 * 60
        case 3: 2 * 60 * 60
        case 4: 12 * 60 * 60
        default: 24 * 60 * 60
        }
    }
}

public struct TripEnrichmentCandidate: Equatable, Sendable {
    public var trip: TripSummary
    public var components: Set<TripEnrichmentComponent>

    public init(trip: TripSummary, components: Set<TripEnrichmentComponent>) {
        self.trip = trip
        self.components = components
    }
}

public struct TripSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var captureSource: String
    public var startDate: Date
    public var endDate: Date
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var startAddress: String?
    public var endAddress: String?
    public var startAddressComponents: TripEndpointAddressComponents?
    public var endAddressComponents: TripEndpointAddressComponents?
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var routePolyline: String?
    public var classification: TripClassification?
    public var reviewStatus: ReviewStatus
    public var businessPurpose: String?
    public var notes: String?
    public var tollsAmount: Double
    public var parkingAmount: Double
    public var needsAttention: Bool
    public var attentionReasons: [String]
    public var manualDistanceOverrideMeters: Double?
    public var legs: [TripLeg]
    public var connectors: [TripLegConnector]
    /// Salted identifier hashes of Bluetooth devices observed near the drive's
    /// start, recorded at completion so review decisions can train vehicle trust.
    /// Hashes are salted per device, so values synced from another device are inert.
    public var startBluetoothHintHashes: [String]
    public var classificationSource: TripClassificationSource?
    /// The vehicle this trip is attributed to. `nil` means the primary vehicle
    /// (or, when no vehicles exist, the single implicit vehicle).
    public var vehicleID: UUID?
    /// How `vehicleID` was set, so automatic re-attribution never overrides a
    /// manual choice.
    public var vehicleAssignmentSource: VehicleAssignmentSource?
    public var startAddressEnrichmentState: TripEnrichmentState
    public var endAddressEnrichmentState: TripEnrichmentState
    public var routeEnrichmentState: TripEnrichmentState

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        captureSource: String,
        startDate: Date,
        endDate: Date,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        startAddress: String?,
        endAddress: String?,
        startAddressComponents: TripEndpointAddressComponents? = nil,
        endAddressComponents: TripEndpointAddressComponents? = nil,
        distanceMeters: Double,
        routePolyline: String?,
        classification: TripClassification?,
        reviewStatus: ReviewStatus,
        businessPurpose: String?,
        notes: String?,
        tollsAmount: Double,
        parkingAmount: Double,
        needsAttention: Bool,
        attentionReasons: [String],
        manualDistanceOverrideMeters: Double?,
        legs: [TripLeg] = [],
        connectors: [TripLegConnector] = [],
        startBluetoothHintHashes: [String] = [],
        classificationSource: TripClassificationSource? = nil,
        vehicleID: UUID? = nil,
        vehicleAssignmentSource: VehicleAssignmentSource? = nil,
        startAddressEnrichmentState: TripEnrichmentState = .legacy,
        endAddressEnrichmentState: TripEnrichmentState = .legacy,
        routeEnrichmentState: TripEnrichmentState = .legacy,
        deriveRoutePolylineWhenMissing: Bool = true
    ) {
        let normalizedLegs = Self.normalizedLegs(
            legs,
            fallbackID: id,
            captureSource: captureSource,
            startDate: startDate,
            endDate: endDate,
            startCoordinate: startCoordinate,
            endCoordinate: endCoordinate,
            startAddress: startAddress,
            endAddress: endAddress,
            distanceMeters: distanceMeters,
            routePolyline: routePolyline,
            tollsAmount: tollsAmount,
            parkingAmount: parkingAmount
        )
        let boundaries = normalizedLegs.tripBoundaryIndices
        let firstLeg = boundaries.map { normalizedLegs[$0.start] }
        let lastLeg = boundaries.map { normalizedLegs[$0.end] }
        let normalizedConnectors = Self.normalizedConnectors(connectors, legs: normalizedLegs)
        let route = TripRouteSummary(legs: normalizedLegs, connectors: normalizedConnectors)

        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.captureSource = captureSource
        self.startDate = firstLeg?.startDate ?? startDate
        self.endDate = lastLeg?.endDate ?? endDate
        let matchesStoredStart = self.startDate == startDate
        let matchesStoredEnd = self.endDate == endDate
        self.startCoordinate = firstLeg?.startCoordinate ?? (matchesStoredStart ? startCoordinate : nil)
        self.endCoordinate = lastLeg?.endCoordinate ?? (matchesStoredEnd ? endCoordinate : nil)
        self.startAddress = firstLeg?.startAddress ?? (matchesStoredStart ? startAddress : nil)
        self.endAddress = lastLeg?.endAddress ?? (matchesStoredEnd ? endAddress : nil)
        // Older merged records may carry the last-starting leg's endpoint at
        // the top level. Only reuse that metadata when it belongs to this end.
        let startComponents = matchesStoredStart && self.startCoordinate == startCoordinate && self.startAddress == startAddress
            ? startAddressComponents ?? firstLeg?.startAddressComponents
            : firstLeg?.startAddressComponents
        let endComponents = matchesStoredEnd && self.endCoordinate == endCoordinate && self.endAddress == endAddress
            ? endAddressComponents ?? lastLeg?.endAddressComponents
            : lastLeg?.endAddressComponents
        self.startAddressComponents = startComponents?.hasDisplayableComponent == true ? startComponents : nil
        self.endAddressComponents = endComponents?.hasDisplayableComponent == true ? endComponents : nil
        self.distanceMeters = distanceMeters
        self.durationSeconds = max(0, (lastLeg?.endDate ?? endDate).timeIntervalSince(firstLeg?.startDate ?? startDate))
        self.routePolyline = routePolyline
            ?? (deriveRoutePolylineWhenMissing ? route.routePolyline : nil)
        self.classification = classification
        self.reviewStatus = reviewStatus
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.tollsAmount = tollsAmount
        self.parkingAmount = parkingAmount
        self.needsAttention = needsAttention
        self.attentionReasons = attentionReasons
        self.manualDistanceOverrideMeters = manualDistanceOverrideMeters
        self.legs = normalizedLegs
        self.connectors = normalizedConnectors
        self.startBluetoothHintHashes = startBluetoothHintHashes
        self.classificationSource = classificationSource
        self.vehicleID = vehicleID
        self.vehicleAssignmentSource = vehicleAssignmentSource
        self.startAddressEnrichmentState = startAddressEnrichmentState
        self.endAddressEnrichmentState = endAddressEnrichmentState
        self.routeEnrichmentState = routeEnrichmentState
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case captureSource
        case startDate
        case endDate
        case startCoordinate
        case endCoordinate
        case startAddress
        case endAddress
        case startAddressComponents
        case endAddressComponents
        case distanceMeters
        case durationSeconds
        case routePolyline
        case classification
        case reviewStatus
        case businessPurpose
        case notes
        case tollsAmount
        case parkingAmount
        case needsAttention
        case attentionReasons
        case manualDistanceOverrideMeters
        case legs
        case connectors
        case startBluetoothHintHashes
        case classificationSource
        case vehicleID
        case vehicleAssignmentSource
        case startAddressEnrichmentState
        case endAddressEnrichmentState
        case routeEnrichmentState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            captureSource: try container.decode(String.self, forKey: .captureSource),
            startDate: try container.decode(Date.self, forKey: .startDate),
            endDate: try container.decode(Date.self, forKey: .endDate),
            startCoordinate: try container.decodeIfPresent(Coordinate.self, forKey: .startCoordinate),
            endCoordinate: try container.decodeIfPresent(Coordinate.self, forKey: .endCoordinate),
            startAddress: try container.decodeIfPresent(String.self, forKey: .startAddress),
            endAddress: try container.decodeIfPresent(String.self, forKey: .endAddress),
            startAddressComponents: try container.decodeIfPresent(TripEndpointAddressComponents.self, forKey: .startAddressComponents),
            endAddressComponents: try container.decodeIfPresent(TripEndpointAddressComponents.self, forKey: .endAddressComponents),
            distanceMeters: try container.decode(Double.self, forKey: .distanceMeters),
            routePolyline: try container.decodeIfPresent(String.self, forKey: .routePolyline),
            classification: try container.decodeIfPresent(TripClassification.self, forKey: .classification),
            reviewStatus: try container.decode(ReviewStatus.self, forKey: .reviewStatus),
            businessPurpose: try container.decodeIfPresent(String.self, forKey: .businessPurpose),
            notes: try container.decodeIfPresent(String.self, forKey: .notes),
            tollsAmount: try container.decode(Double.self, forKey: .tollsAmount),
            parkingAmount: try container.decode(Double.self, forKey: .parkingAmount),
            needsAttention: try container.decode(Bool.self, forKey: .needsAttention),
            attentionReasons: try container.decode([String].self, forKey: .attentionReasons),
            manualDistanceOverrideMeters: try container.decodeIfPresent(Double.self, forKey: .manualDistanceOverrideMeters),
            legs: try container.decode([TripLeg].self, forKey: .legs),
            connectors: try container.decode([TripLegConnector].self, forKey: .connectors),
            startBluetoothHintHashes: try container.decodeIfPresent([String].self, forKey: .startBluetoothHintHashes) ?? [],
            classificationSource: try container.decodeIfPresent(TripClassificationSource.self, forKey: .classificationSource),
            vehicleID: try container.decodeIfPresent(UUID.self, forKey: .vehicleID),
            vehicleAssignmentSource: try container.decodeIfPresent(VehicleAssignmentSource.self, forKey: .vehicleAssignmentSource),
            startAddressEnrichmentState: try container.decodeIfPresent(
                TripEnrichmentState.self,
                forKey: .startAddressEnrichmentState
            ) ?? .legacy,
            endAddressEnrichmentState: try container.decodeIfPresent(
                TripEnrichmentState.self,
                forKey: .endAddressEnrichmentState
            ) ?? .legacy,
            routeEnrichmentState: try container.decodeIfPresent(
                TripEnrichmentState.self,
                forKey: .routeEnrichmentState
            ) ?? .legacy
        )
    }

    public var reportableDistanceMeters: Double {
        manualDistanceOverrideMeters ?? distanceMeters
    }

    public var miles: Double {
        DistanceConversion.miles(fromMeters: reportableDistanceMeters)
    }

    public var routeSummary: TripRouteSummary {
        TripRouteSummary(legs: legs, connectors: connectors)
    }

    public var effectiveLegs: [TripDisplayLeg] {
        let connectorsByToLegID = Dictionary(grouping: connectors, by: \.toLegID)
        return legs.map { leg in
            TripDisplayLeg(leg: leg, incomingConnector: connectorsByToLegID[leg.id]?.first)
        }
    }

    public var stops: [TripStop] {
        guard legs.count >= 2 else { return [] }
        return zip(legs, legs.dropFirst()).map { previous, next in
            TripStop(
                id: previous.id,
                arrivedAt: previous.endDate,
                departedAt: next.startDate,
                coordinate: previous.endCoordinate ?? next.startCoordinate,
                address: previous.endAddress ?? next.startAddress
            )
        }
    }

    public var isMerged: Bool {
        legs.count >= 2 || captureSource == "merged"
    }

    public var canSplit: Bool {
        true
    }

    public var canUnmerge: Bool {
        uniqueSourceTripIDs.count >= 2
    }

    private static func normalizedLegs(
        _ legs: [TripLeg],
        fallbackID: UUID,
        captureSource: String,
        startDate: Date,
        endDate: Date,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        startAddress: String?,
        endAddress: String?,
        distanceMeters: Double,
        routePolyline: String?,
        tollsAmount: Double,
        parkingAmount: Double
    ) -> [TripLeg] {
        let sourceLegs = legs.isEmpty
            ? [TripLeg(
                id: fallbackID,
                sourceTripID: nil,
                captureSource: captureSource,
                startDate: startDate,
                endDate: endDate,
                startCoordinate: startCoordinate,
                endCoordinate: endCoordinate,
                startAddress: startAddress,
                endAddress: endAddress,
                distanceMeters: distanceMeters,
                routePolyline: routePolyline,
                tollsAmount: tollsAmount,
                parkingAmount: parkingAmount
            )]
            : legs
        return legsWithStopDurations(sourceLegs.sorted { $0.startDate < $1.startDate })
    }

    private var uniqueSourceTripIDs: [UUID] {
        var ids: [UUID] = []
        for id in legs.compactMap(\.sourceTripID) where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private static func legsWithStopDurations(_ legs: [TripLeg]) -> [TripLeg] {
        var result = legs
        for index in result.indices {
            let nextIndex = result.index(after: index)
            if result.indices.contains(nextIndex) {
                result[index].stopDurationAfterSeconds = max(0, result[nextIndex].startDate.timeIntervalSince(result[index].endDate))
            } else {
                result[index].stopDurationAfterSeconds = nil
            }
        }
        return result
    }

    private static func normalizedConnectors(_ connectors: [TripLegConnector], legs: [TripLeg]) -> [TripLegConnector] {
        let legIDs = Set(legs.map(\.id))
        return connectors.filter { connector in
            legIDs.contains(connector.fromLegID) && legIDs.contains(connector.toLegID)
        }
    }
}

public extension TripSummary {
    var isExportableBusiness: Bool {
        TripReviewPolicy.isExportableBusiness(
            classification: classification,
            businessPurpose: businessPurpose
        )
    }

    var isUnresolved: Bool {
        TripReviewPolicy.isUnresolved(
            classification: classification,
            businessPurpose: businessPurpose
        )
    }
}

public struct ManualTripInput: Codable, Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var startAddress: String?
    public var endAddress: String?
    public var distanceMeters: Double
    public var routePolyline: String?
    public var manualDistanceOverrideMeters: Double?
    public var classification: TripClassification?
    public var businessPurpose: String?
    public var notes: String?
    public var vehicleID: UUID?

    public init(
        startDate: Date,
        endDate: Date,
        startCoordinate: Coordinate? = nil,
        endCoordinate: Coordinate? = nil,
        startAddress: String? = nil,
        endAddress: String? = nil,
        distanceMeters: Double,
        routePolyline: String? = nil,
        manualDistanceOverrideMeters: Double? = nil,
        classification: TripClassification? = nil,
        businessPurpose: String? = nil,
        notes: String? = nil,
        vehicleID: UUID? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.distanceMeters = distanceMeters
        self.routePolyline = routePolyline
        self.manualDistanceOverrideMeters = manualDistanceOverrideMeters
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.vehicleID = vehicleID
    }
}

public struct ReviewUpdate: Codable, Equatable, Sendable {
    public var classification: TripClassification?
    public var clearClassification: Bool
    public var reviewStatus: ReviewStatus?
    public var businessPurpose: String?
    public var notes: String?
    public var tollsAmount: Double?
    public var parkingAmount: Double?
    public var manualDistanceOverrideMeters: Double?
    public var clearManualDistanceOverride: Bool
    public var startDate: Date?
    public var endDate: Date?
    public var vehicleID: UUID?
    public var clearVehicleAssignment: Bool

    public init(
        classification: TripClassification? = nil,
        clearClassification: Bool = false,
        reviewStatus: ReviewStatus? = nil,
        businessPurpose: String? = nil,
        notes: String? = nil,
        tollsAmount: Double? = nil,
        parkingAmount: Double? = nil,
        manualDistanceOverrideMeters: Double? = nil,
        clearManualDistanceOverride: Bool = false,
        startDate: Date? = nil,
        endDate: Date? = nil,
        vehicleID: UUID? = nil,
        clearVehicleAssignment: Bool = false
    ) {
        self.classification = classification
        self.clearClassification = clearClassification
        self.reviewStatus = reviewStatus
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.tollsAmount = tollsAmount
        self.parkingAmount = parkingAmount
        self.manualDistanceOverrideMeters = manualDistanceOverrideMeters
        self.clearManualDistanceOverride = clearManualDistanceOverride
        self.startDate = startDate
        self.endDate = endDate
        self.vehicleID = vehicleID
        self.clearVehicleAssignment = clearVehicleAssignment
    }
}

public struct OdometerCheckpoint: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var odometerMiles: Double
    public var note: String?
    /// Vehicle this reading belongs to. `nil` = the primary/only vehicle.
    public var vehicleID: UUID?

    public init(id: UUID = UUID(), date: Date, odometerMiles: Double, note: String? = nil, vehicleID: UUID? = nil) {
        self.id = id
        self.date = date
        self.odometerMiles = odometerMiles
        self.note = note
        self.vehicleID = vehicleID
    }
}

public struct ReportSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var startDate: Date
    public var endDate: Date
    public var title: String
    public var csvText: String
    public var pdfData: Data
    public var businessMiles: Double
    public var businessValue: Double
    public var rateCentsPerMile: Double
    public var includedTripIDs: [UUID]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        startDate: Date,
        endDate: Date,
        title: String,
        csvText: String,
        pdfData: Data,
        businessMiles: Double,
        businessValue: Double,
        rateCentsPerMile: Double,
        includedTripIDs: [UUID]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.csvText = csvText
        self.pdfData = pdfData
        self.businessMiles = businessMiles
        self.businessValue = businessValue
        self.rateCentsPerMile = rateCentsPerMile
        self.includedTripIDs = includedTripIDs
    }
}

public struct TrackingHealth: Codable, Equatable, Sendable {
    public var alwaysLocationAuthorized: Bool
    public var preciseLocationEnabled: Bool
    public var motionAuthorized: Bool
    public var backgroundRefreshAvailable: Bool
    public var lastBackgroundWake: Date?
    public var lastCapturedTrip: Date?
    public var trackingPausedUntil: Date?
    public var issues: [String]

    public static var unknown: TrackingHealth {
        TrackingHealth(
            alwaysLocationAuthorized: false,
            preciseLocationEnabled: false,
            motionAuthorized: false,
            backgroundRefreshAvailable: false,
            lastBackgroundWake: nil,
            lastCapturedTrip: nil,
            trackingPausedUntil: nil,
            issues: ["Tracking has not been checked yet."]
        )
    }
}
