import AppCoreModels
import Foundation

public enum DriveCapturePhase: String, Codable, Equatable, Sendable {
    case idle
    case candidate
    case recording
    case paused
}

public enum VehicleConnectionSource: String, Codable, Equatable, Sendable {
    case bluetoothAudio
    case carPlayAudio
    case usbPower
    case unknownTrustedRoute
}

public enum ParkingSignal: String, Codable, Equatable, Sendable {
    case vehicleConnectionDisconnected
    case motionParkingTransition
    case fallbackStationaryTimeout
    case trafficStopHold
}

public enum ParkingConfidence: String, Codable, Equatable, Sendable {
    case hard
    case assist
    case fallback
}

public enum DriveStartSignalSource: String, Codable, Equatable, Sendable {
    case motionAutomotive
    case trustedBluetooth
    case weakBluetoothName
    case usbPower
    case parkedAnchorExit
    case acceptedVehicleLocation
    case coarseLocationWake
    case significantLocationChange
    case visitDeparture
    case externalVehicleAutomation
    case externalChargerAutomation
}

public enum DriveStartSignalConfidence: String, Codable, Comparable, Equatable, Sendable {
    case weak
    case assist
    case strong
}

public struct DriveStartSignal: Codable, Equatable, Sendable {
    public var source: DriveStartSignalSource
    public var confidence: DriveStartSignalConfidence
    public var startedAt: Date
    public var expiresAt: Date
    public var motionContributed: Bool
    public var bluetoothContributed: Bool
    public var powerContributed: Bool
    public var pendingSignalID: UUID?
    /// Explicit vehicle carried by an arming Shortcut, if the automation set one.
    public var vehicleID: UUID?
    /// Exact Shortcuts trigger. The source alone cannot distinguish vehicle
    /// automations from Manual, which historically shares the same source.
    public var externalTrigger: DriveStartExternalTrigger?

    public init(
        source: DriveStartSignalSource,
        confidence: DriveStartSignalConfidence,
        startedAt: Date,
        expiresAt: Date,
        motionContributed: Bool? = nil,
        bluetoothContributed: Bool? = nil,
        powerContributed: Bool? = nil,
        pendingSignalID: UUID? = nil,
        vehicleID: UUID? = nil,
        externalTrigger: DriveStartExternalTrigger? = nil
    ) {
        self.source = source
        self.confidence = confidence
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.motionContributed = motionContributed ?? (source == .motionAutomotive)
        self.bluetoothContributed = bluetoothContributed ?? (source == .trustedBluetooth || source == .weakBluetoothName || source == .externalVehicleAutomation)
        self.powerContributed = powerContributed ?? (source == .usbPower || source == .externalChargerAutomation)
        self.pendingSignalID = pendingSignalID
        self.vehicleID = vehicleID
        self.externalTrigger = externalTrigger
    }

    public func merged(with signal: DriveStartSignal) -> DriveStartSignal {
        DriveStartSignal(
            source: strongerSource(comparedWith: signal),
            confidence: max(confidence, signal.confidence),
            startedAt: min(startedAt, signal.startedAt),
            expiresAt: max(expiresAt, signal.expiresAt),
            motionContributed: motionContributed || signal.motionContributed,
            bluetoothContributed: bluetoothContributed || signal.bluetoothContributed,
            powerContributed: powerContributed || signal.powerContributed,
            pendingSignalID: pendingSignalID ?? signal.pendingSignalID,
            vehicleID: vehicleID ?? signal.vehicleID,
            externalTrigger: signal.externalTrigger ?? externalTrigger
        )
    }

    public var isVehicleAutomation: Bool {
        source == .externalVehicleAutomation
            && (externalTrigger == .vehicleBluetooth || externalTrigger == .carPlay)
    }

    private func strongerSource(comparedWith signal: DriveStartSignal) -> DriveStartSignalSource {
        signal.confidence > confidence ? signal.source : source
    }
}

extension DriveStartSignalConfidence {
    public static func < (lhs: DriveStartSignalConfidence, rhs: DriveStartSignalConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .weak:
            0
        case .assist:
            1
        case .strong:
            2
        }
    }
}

public struct ParkingEvidence: Codable, Equatable, Sendable {
    public var signal: ParkingSignal
    public var source: VehicleConnectionSource?
    public var confidence: ParkingConfidence
    public var signalAt: Date
    public var inferredEndAt: Date
    public var anchorSample: LocationSample?
    public var cancelReason: String?

    public init(
        signal: ParkingSignal,
        source: VehicleConnectionSource? = nil,
        confidence: ParkingConfidence,
        signalAt: Date,
        inferredEndAt: Date,
        anchorSample: LocationSample? = nil,
        cancelReason: String? = nil
    ) {
        self.signal = signal
        self.source = source
        self.confidence = confidence
        self.signalAt = signalAt
        self.inferredEndAt = inferredEndAt
        self.anchorSample = anchorSample
        self.cancelReason = cancelReason
    }
}

public struct DriveCaptureConfiguration: Codable, Equatable, Sendable {
    public var startPolicy: DriveStartPolicy
    public var minimumStartSpeedMetersPerSecond: Double
    public var minimumStartDuration: TimeInterval
    public var bluetoothAssistedStartSpeedMetersPerSecond: Double
    public var bluetoothAssistedStartDuration: TimeInterval
    public var powerAssistedStartSpeedMetersPerSecond: Double
    public var powerAssistedStartDuration: TimeInterval
    public var stationarySpeedMetersPerSecond: Double
    public var stopTimeout: TimeInterval
    public var pedestrianExitTimeout: TimeInterval
    public var maxHorizontalAccuracyMeters: Double
    public var maxLocationAgeSeconds: TimeInterval
    public var maxSegmentSpeedMetersPerSecond: Double
    public var rawSampleRetentionDays: Int
    public var routeSimplificationToleranceMeters: Double

    public static var automatic: DriveCaptureConfiguration {
        DriveCaptureConfiguration(
            startPolicy: .balanced,
            minimumStartSpeedMetersPerSecond: 2.0,
            minimumStartDuration: 25,
            bluetoothAssistedStartSpeedMetersPerSecond: 1.5,
            bluetoothAssistedStartDuration: 10,
            powerAssistedStartSpeedMetersPerSecond: 1.5,
            powerAssistedStartDuration: 10,
            stationarySpeedMetersPerSecond: 1.2,
            stopTimeout: 180,
            pedestrianExitTimeout: 90,
            maxHorizontalAccuracyMeters: 65,
            maxLocationAgeSeconds: 90,
            maxSegmentSpeedMetersPerSecond: 60,
            rawSampleRetentionDays: 30,
            routeSimplificationToleranceMeters: 8
        )
    }

    public init(
        startPolicy: DriveStartPolicy = .balanced,
        minimumStartSpeedMetersPerSecond: Double,
        minimumStartDuration: TimeInterval,
        bluetoothAssistedStartSpeedMetersPerSecond: Double,
        bluetoothAssistedStartDuration: TimeInterval,
        powerAssistedStartSpeedMetersPerSecond: Double,
        powerAssistedStartDuration: TimeInterval,
        stationarySpeedMetersPerSecond: Double,
        stopTimeout: TimeInterval,
        pedestrianExitTimeout: TimeInterval,
        maxHorizontalAccuracyMeters: Double,
        maxLocationAgeSeconds: TimeInterval,
        maxSegmentSpeedMetersPerSecond: Double,
        rawSampleRetentionDays: Int,
        routeSimplificationToleranceMeters: Double
    ) {
        self.startPolicy = startPolicy
        self.minimumStartSpeedMetersPerSecond = minimumStartSpeedMetersPerSecond
        self.minimumStartDuration = minimumStartDuration
        self.bluetoothAssistedStartSpeedMetersPerSecond = bluetoothAssistedStartSpeedMetersPerSecond
        self.bluetoothAssistedStartDuration = bluetoothAssistedStartDuration
        self.powerAssistedStartSpeedMetersPerSecond = powerAssistedStartSpeedMetersPerSecond
        self.powerAssistedStartDuration = powerAssistedStartDuration
        self.stationarySpeedMetersPerSecond = stationarySpeedMetersPerSecond
        self.stopTimeout = stopTimeout
        self.pedestrianExitTimeout = pedestrianExitTimeout
        self.maxHorizontalAccuracyMeters = maxHorizontalAccuracyMeters
        self.maxLocationAgeSeconds = maxLocationAgeSeconds
        self.maxSegmentSpeedMetersPerSecond = maxSegmentSpeedMetersPerSecond
        self.rawSampleRetentionDays = rawSampleRetentionDays
        self.routeSimplificationToleranceMeters = routeSimplificationToleranceMeters
    }
}

extension DriveCaptureConfiguration {
    private enum CodingKeys: String, CodingKey {
        case startPolicy
        case minimumStartSpeedMetersPerSecond
        case minimumStartDuration
        case bluetoothAssistedStartSpeedMetersPerSecond
        case bluetoothAssistedStartDuration
        case powerAssistedStartSpeedMetersPerSecond
        case powerAssistedStartDuration
        case stationarySpeedMetersPerSecond
        case stopTimeout
        case pedestrianExitTimeout
        case maxHorizontalAccuracyMeters
        case maxLocationAgeSeconds
        case maxSegmentSpeedMetersPerSecond
        case rawSampleRetentionDays
        case routeSimplificationToleranceMeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is soft-decoded with a fallback to `.automatic` so adding a
        // new field never throws while decoding a pre-existing on-disk checkpoint
        // and dropping the persisted DriveCaptureState (active trip, parked anchor).
        let defaults = DriveCaptureConfiguration.automatic
        self.init(
            startPolicy: try container.decodeIfPresent(DriveStartPolicy.self, forKey: .startPolicy) ?? defaults.startPolicy,
            minimumStartSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .minimumStartSpeedMetersPerSecond) ?? defaults.minimumStartSpeedMetersPerSecond,
            minimumStartDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .minimumStartDuration) ?? defaults.minimumStartDuration,
            bluetoothAssistedStartSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .bluetoothAssistedStartSpeedMetersPerSecond) ?? defaults.bluetoothAssistedStartSpeedMetersPerSecond,
            bluetoothAssistedStartDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .bluetoothAssistedStartDuration) ?? defaults.bluetoothAssistedStartDuration,
            powerAssistedStartSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .powerAssistedStartSpeedMetersPerSecond) ?? defaults.powerAssistedStartSpeedMetersPerSecond,
            powerAssistedStartDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .powerAssistedStartDuration) ?? defaults.powerAssistedStartDuration,
            stationarySpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .stationarySpeedMetersPerSecond) ?? defaults.stationarySpeedMetersPerSecond,
            stopTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .stopTimeout) ?? defaults.stopTimeout,
            pedestrianExitTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .pedestrianExitTimeout) ?? defaults.pedestrianExitTimeout,
            maxHorizontalAccuracyMeters: try container.decodeIfPresent(Double.self, forKey: .maxHorizontalAccuracyMeters) ?? defaults.maxHorizontalAccuracyMeters,
            maxLocationAgeSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .maxLocationAgeSeconds) ?? defaults.maxLocationAgeSeconds,
            maxSegmentSpeedMetersPerSecond: try container.decodeIfPresent(Double.self, forKey: .maxSegmentSpeedMetersPerSecond) ?? defaults.maxSegmentSpeedMetersPerSecond,
            rawSampleRetentionDays: try container.decodeIfPresent(Int.self, forKey: .rawSampleRetentionDays) ?? defaults.rawSampleRetentionDays,
            routeSimplificationToleranceMeters: try container.decodeIfPresent(Double.self, forKey: .routeSimplificationToleranceMeters) ?? defaults.routeSimplificationToleranceMeters
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startPolicy, forKey: .startPolicy)
        try container.encode(minimumStartSpeedMetersPerSecond, forKey: .minimumStartSpeedMetersPerSecond)
        try container.encode(minimumStartDuration, forKey: .minimumStartDuration)
        try container.encode(bluetoothAssistedStartSpeedMetersPerSecond, forKey: .bluetoothAssistedStartSpeedMetersPerSecond)
        try container.encode(bluetoothAssistedStartDuration, forKey: .bluetoothAssistedStartDuration)
        try container.encode(powerAssistedStartSpeedMetersPerSecond, forKey: .powerAssistedStartSpeedMetersPerSecond)
        try container.encode(powerAssistedStartDuration, forKey: .powerAssistedStartDuration)
        try container.encode(stationarySpeedMetersPerSecond, forKey: .stationarySpeedMetersPerSecond)
        try container.encode(stopTimeout, forKey: .stopTimeout)
        try container.encode(pedestrianExitTimeout, forKey: .pedestrianExitTimeout)
        try container.encode(maxHorizontalAccuracyMeters, forKey: .maxHorizontalAccuracyMeters)
        try container.encode(maxLocationAgeSeconds, forKey: .maxLocationAgeSeconds)
        try container.encode(maxSegmentSpeedMetersPerSecond, forKey: .maxSegmentSpeedMetersPerSecond)
        try container.encode(rawSampleRetentionDays, forKey: .rawSampleRetentionDays)
        try container.encode(routeSimplificationToleranceMeters, forKey: .routeSimplificationToleranceMeters)
    }
}

/// A contradiction (non-vehicle evidence) observed while a drive candidate
/// was alive. The timestamp keeps blocking no-trust confirmation for a hold
/// window even if the sample itself was tolerated or the candidate revived.
public struct CandidateContradiction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case pedestrian
        case stationary
        case lowSpeed
    }

    public var at: Date
    public var kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// Evidence preserved from a just-killed drive candidate so a quick restart
/// (June 9 pattern: kill/restart cycles ~11 s apart while actually driving)
/// can inherit the accumulated start time, samples, and assist hints instead
/// of losing minutes of trip start.
public struct RecentCandidateSnapshot: Codable, Equatable, Sendable {
    public var candidateStartedAt: Date?
    public var samples: [LocationSample]
    public var startSignal: DriveStartSignal?
    public var hadBluetoothHint: Bool
    public var hadPowerHint: Bool
    public var contradictionCount: Int
    public var lastContradiction: CandidateContradiction?
    public var killedAt: Date
    public var firstMovementAt: Date?
    public var vehicleID: UUID?
    public var vehicleAssignmentSource: VehicleAssignmentSource?
    public var conflictingVehicleIDs: [UUID]?

    public init(
        candidateStartedAt: Date?,
        samples: [LocationSample],
        startSignal: DriveStartSignal?,
        hadBluetoothHint: Bool,
        hadPowerHint: Bool,
        contradictionCount: Int,
        lastContradiction: CandidateContradiction?,
        killedAt: Date,
        firstMovementAt: Date? = nil,
        vehicleID: UUID? = nil,
        vehicleAssignmentSource: VehicleAssignmentSource? = nil,
        conflictingVehicleIDs: [UUID]? = nil
    ) {
        self.candidateStartedAt = candidateStartedAt
        self.samples = samples
        self.startSignal = startSignal
        self.hadBluetoothHint = hadBluetoothHint
        self.hadPowerHint = hadPowerHint
        self.contradictionCount = contradictionCount
        self.lastContradiction = lastContradiction
        self.killedAt = killedAt
        self.firstMovementAt = firstMovementAt
        self.vehicleID = vehicleID
        self.vehicleAssignmentSource = vehicleAssignmentSource
        self.conflictingVehicleIDs = conflictingVehicleIDs
    }
}

public struct DriveCaptureState: Codable, Equatable, Sendable {
    public var captureID: UUID
    public var pendingTripID: UUID?
    public var phase: DriveCapturePhase
    public var configuration: DriveCaptureConfiguration
    public var automaticTripStartMode: AutomaticTripStartMode
    /// Movement rejected by the admission policy must not be revived by a
    /// delayed location, an old Shortcut, or parked-origin inference.
    public var automaticStartExcludedThrough: Date?
    /// Unmerged, bounded permission from an explicit Bluetooth/CarPlay
    /// Shortcut. Passive confidence signals cannot extend this window.
    public var vehicleAutomationStartSignal: DriveStartSignal?
    public var candidateStartedAt: Date?
    public var startedAt: Date?
    public var lastMovingAt: Date?
    public var firstStationaryAt: Date?
    public var stopDueAt: Date?
    public var lastProcessedLocationTimestamp: Date?
    public var candidateSamples: [LocationSample]
    public var samples: [LocationSample]
    public var attentionReasons: [String]
    /// Authoritative source of truth for the generic idle-wake anchor. The
    /// idle-wake provider mirrors this into a non-secure beacon to re-arm the
    /// geofence on a cold relaunch. This is a stopped-phone location, not proof
    /// that a vehicle is parked there, so it must never contribute route geometry
    /// or mileage.
    public var parkedStartAnchor: LocationSample?
    /// Last parking location established by a completed vehicle trip. Unlike the
    /// generic idle-wake anchor, this may be used to recover a delayed GPS start.
    public var vehicleParkingAnchor: LocationSample?
    public var pausedUntil: Date?
    public var pendingCompletionDraft: TripDraft?
    public var pendingFees: [TripFee]
    public var pendingClassification: TripClassification?
    public var pendingBusinessPurpose: String?
    public var pendingNote: String?
    public var vehicleConnectionActive: Bool
    public var lastVehicleConnectionAt: Date?
    public var parkingCandidateStartedAt: Date?
    public var parkingAnchorSample: LocationSample?
    public var firstPostVehicleStationaryAt: Date?
    public var firstPedestrianAt: Date?
    public var parkingEvidence: ParkingEvidence?
    public var idlePrimingExhaustedAt: Date?
    public var startSignal: DriveStartSignal?
    /// Explicit vehicle from the arming Shortcut for the in-flight capture.
    /// Unlike `startSignal` (nulled when a candidate is promoted to recording),
    /// this persists until the draft is built so a per-car automation firing
    /// seconds after motion confirmation still tags the finished trip.
    public var startVehicleHint: UUID?
    /// True when `startVehicleHint` was chosen by the user mid-drive (live bar)
    /// rather than carried by a Shortcut; the finished trip is then stamped
    /// `.manual`, which protects it from automatic re-attribution.
    public var startVehicleIsManual: Bool
    /// Source attached to `startVehicleHint`. Kept separately from the legacy
    /// manual flag so confirmed connection mappings survive relaunch and stamp
    /// completed drafts as `.vehicleConnection`.
    public var startVehicleAssignmentSource: VehicleAssignmentSource?
    /// Later mapped connections that disagree with the latched vehicle. They
    /// are deferred for UI review and never switch the drive automatically.
    public var conflictingVehicleIDs: [UUID]
    /// Start times of recent high-confidence cycling motion snapshots, kept
    /// from `CyclingTripClassifier.leadInSeconds` before the current capture's
    /// start (or before the newest snapshot while idle). A recorded "drive"
    /// that was really a bike ride is cut out of the stretch where CoreMotion
    /// mislabels fast cycling as automotive; the cycling reports that bracket
    /// it live only here, so the finished draft carries them to the completion
    /// classifiers.
    public var recentCyclingMotionDates: [Date]
    /// Last moment a trusted vehicle connection was known to be live: an
    /// `active` connection event, or a location whose context carried the
    /// trusted hint. Lets a finished draft report that a car was present even
    /// after the link dropped mid-capture.
    public var lastVehicleConnectionActiveAt: Date?
    /// Audio routes carry vehicle evidence; generic charging events share the
    /// parking connection channel but must not veto a cycling classification.
    public var vehicleAudioConnectionActive: Bool
    /// Accepted Bluetooth/CarPlay actions are vehicle evidence even when iOS
    /// never exposes the car's audio route or no vehicle mapping exists.
    public var lastVehicleAutomationSignalAt: Date?

    var candidateHadBluetoothHint: Bool
    var candidateHadPowerHint: Bool
    var lastAcceptedSample: LocationSample?
    var pendingImpossibleSample: LocationSample?
    var candidateContradictionCount: Int
    var lastCandidateContradiction: CandidateContradiction?
    package var recentCandidate: RecentCandidateSnapshot?
    /// Timestamp of the first sample on the current candidate carrying genuine
    /// movement evidence (reported/derived/assisted speed - not a bare automotive
    /// motion label, which can co-occur with `.stationary` on an idling parked car).
    /// `nil` means the candidate hasn't seen real movement yet.
    var candidateFirstMovementAt: Date?

    public init(
        captureID: UUID = UUID(),
        pendingTripID: UUID? = nil,
        phase: DriveCapturePhase = .idle,
        configuration: DriveCaptureConfiguration = .automatic,
        automaticTripStartMode: AutomaticTripStartMode = .both,
        automaticStartExcludedThrough: Date? = nil,
        vehicleAutomationStartSignal: DriveStartSignal? = nil,
        candidateStartedAt: Date? = nil,
        startedAt: Date? = nil,
        lastMovingAt: Date? = nil,
        firstStationaryAt: Date? = nil,
        stopDueAt: Date? = nil,
        lastProcessedLocationTimestamp: Date? = nil,
        candidateSamples: [LocationSample] = [],
        samples: [LocationSample] = [],
        attentionReasons: [String] = [],
        parkedStartAnchor: LocationSample? = nil,
        vehicleParkingAnchor: LocationSample? = nil,
        pausedUntil: Date? = nil,
        pendingCompletionDraft: TripDraft? = nil,
        pendingFees: [TripFee] = [],
        pendingClassification: TripClassification? = nil,
        pendingBusinessPurpose: String? = nil,
        pendingNote: String? = nil,
        vehicleConnectionActive: Bool = false,
        lastVehicleConnectionAt: Date? = nil,
        parkingCandidateStartedAt: Date? = nil,
        parkingAnchorSample: LocationSample? = nil,
        firstPostVehicleStationaryAt: Date? = nil,
        firstPedestrianAt: Date? = nil,
        parkingEvidence: ParkingEvidence? = nil,
        idlePrimingExhaustedAt: Date? = nil,
        startSignal: DriveStartSignal? = nil,
        startVehicleHint: UUID? = nil,
        startVehicleIsManual: Bool = false,
        startVehicleAssignmentSource: VehicleAssignmentSource? = nil,
        conflictingVehicleIDs: [UUID] = [],
        recentCyclingMotionDates: [Date] = [],
        lastVehicleConnectionActiveAt: Date? = nil,
        vehicleAudioConnectionActive: Bool = false,
        lastVehicleAutomationSignalAt: Date? = nil
    ) {
        self.captureID = captureID
        self.pendingTripID = pendingTripID
        self.phase = phase
        self.configuration = configuration
        self.automaticTripStartMode = automaticTripStartMode
        self.automaticStartExcludedThrough = automaticStartExcludedThrough
        self.vehicleAutomationStartSignal = vehicleAutomationStartSignal
        self.candidateStartedAt = candidateStartedAt
        self.startedAt = startedAt
        self.lastMovingAt = lastMovingAt
        self.firstStationaryAt = firstStationaryAt
        self.stopDueAt = stopDueAt
        self.lastProcessedLocationTimestamp = lastProcessedLocationTimestamp
        self.candidateSamples = candidateSamples
        self.samples = samples
        self.attentionReasons = attentionReasons
        self.parkedStartAnchor = parkedStartAnchor
        self.vehicleParkingAnchor = vehicleParkingAnchor
        self.pausedUntil = pausedUntil
        self.pendingCompletionDraft = pendingCompletionDraft
        self.pendingFees = pendingFees
        self.pendingClassification = pendingClassification
        self.pendingBusinessPurpose = pendingBusinessPurpose
        self.pendingNote = pendingNote
        self.vehicleConnectionActive = vehicleConnectionActive
        self.lastVehicleConnectionAt = lastVehicleConnectionAt
        self.parkingCandidateStartedAt = parkingCandidateStartedAt
        self.parkingAnchorSample = parkingAnchorSample
        self.firstPostVehicleStationaryAt = firstPostVehicleStationaryAt
        self.firstPedestrianAt = firstPedestrianAt
        self.parkingEvidence = parkingEvidence
        self.idlePrimingExhaustedAt = idlePrimingExhaustedAt
        self.startSignal = startSignal
        self.startVehicleHint = startVehicleHint
        self.startVehicleIsManual = startVehicleIsManual
        self.startVehicleAssignmentSource = startVehicleHint == nil
            ? nil
            : (startVehicleAssignmentSource ?? (startVehicleIsManual ? .manual : .shortcut))
        self.conflictingVehicleIDs = Self.normalizedVehicleIDs(conflictingVehicleIDs, excluding: startVehicleHint)
        self.recentCyclingMotionDates = recentCyclingMotionDates.sorted()
        self.lastVehicleConnectionActiveAt = lastVehicleConnectionActiveAt
        self.vehicleAudioConnectionActive = vehicleAudioConnectionActive
        self.lastVehicleAutomationSignalAt = lastVehicleAutomationSignalAt
        self.candidateHadBluetoothHint = false
        self.candidateHadPowerHint = false
        self.lastAcceptedSample = samples.last ?? candidateSamples.last
        self.pendingImpossibleSample = nil
        self.candidateContradictionCount = 0
        self.lastCandidateContradiction = nil
        self.recentCandidate = nil
        self.candidateFirstMovementAt = nil
    }
}

extension DriveCaptureState {
    private enum CodingKeys: String, CodingKey {
        case captureID
        case pendingTripID
        case phase
        case configuration
        case automaticTripStartMode
        case automaticStartExcludedThrough
        case vehicleAutomationStartSignal
        case candidateStartedAt
        case startedAt
        case lastMovingAt
        case firstStationaryAt
        case stopDueAt
        case lastProcessedLocationTimestamp
        case candidateSamples
        case samples
        case attentionReasons
        case parkedStartAnchor
        case vehicleParkingAnchor
        case pausedUntil
        case pendingCompletionDraft
        case pendingFees
        case pendingClassification
        case pendingBusinessPurpose
        case pendingNote
        case vehicleConnectionActive
        case lastVehicleConnectionAt
        case parkingCandidateStartedAt
        case parkingAnchorSample
        case firstPostVehicleStationaryAt
        case firstPedestrianAt
        case parkingEvidence
        case idlePrimingExhaustedAt
        case startSignal
        case startVehicleHint
        case startVehicleIsManual
        case startVehicleAssignmentSource
        case conflictingVehicleIDs
        case recentCyclingMotionDates
        case lastVehicleConnectionActiveAt
        case vehicleAudioConnectionActive
        case lastVehicleAutomationSignalAt
        case candidateHadBluetoothHint
        case candidateHadPowerHint
        case lastAcceptedSample
        case pendingImpossibleSample
        case candidateContradictionCount
        case lastCandidateContradiction
        case recentCandidate
        case candidateFirstMovementAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureID = try container.decodeIfPresent(UUID.self, forKey: .captureID) ?? UUID()
        pendingTripID = try container.decodeIfPresent(UUID.self, forKey: .pendingTripID)
        phase = try container.decodeIfPresent(DriveCapturePhase.self, forKey: .phase) ?? .idle
        configuration = try container.decodeIfPresent(DriveCaptureConfiguration.self, forKey: .configuration) ?? .automatic
        automaticTripStartMode = try container.decodeIfPresent(AutomaticTripStartMode.self, forKey: .automaticTripStartMode) ?? .both
        automaticStartExcludedThrough = try container.decodeIfPresent(Date.self, forKey: .automaticStartExcludedThrough)
        vehicleAutomationStartSignal = try container.decodeIfPresent(DriveStartSignal.self, forKey: .vehicleAutomationStartSignal)
        candidateStartedAt = try container.decodeIfPresent(Date.self, forKey: .candidateStartedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        lastMovingAt = try container.decodeIfPresent(Date.self, forKey: .lastMovingAt)
        firstStationaryAt = try container.decodeIfPresent(Date.self, forKey: .firstStationaryAt)
        stopDueAt = try container.decodeIfPresent(Date.self, forKey: .stopDueAt)
        lastProcessedLocationTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastProcessedLocationTimestamp)
        candidateSamples = try container.decodeIfPresent([LocationSample].self, forKey: .candidateSamples) ?? []
        samples = try container.decodeIfPresent([LocationSample].self, forKey: .samples) ?? []
        attentionReasons = try container.decodeIfPresent([String].self, forKey: .attentionReasons) ?? []
        parkedStartAnchor = try container.decodeIfPresent(LocationSample.self, forKey: .parkedStartAnchor)
        // Older checkpoints only had a generic parkedStartAnchor. Treat it as
        // wake-only rather than guessing that it represents a vehicle parking
        // location, so an upgrade cannot fabricate a route origin.
        vehicleParkingAnchor = try container.decodeIfPresent(LocationSample.self, forKey: .vehicleParkingAnchor)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        pendingCompletionDraft = try container.decodeIfPresent(TripDraft.self, forKey: .pendingCompletionDraft)
        pendingFees = try container.decodeIfPresent([TripFee].self, forKey: .pendingFees) ?? []
        pendingClassification = try container.decodeIfPresent(TripClassification.self, forKey: .pendingClassification)
        pendingBusinessPurpose = try container.decodeIfPresent(String.self, forKey: .pendingBusinessPurpose)
        pendingNote = try container.decodeIfPresent(String.self, forKey: .pendingNote)
        vehicleConnectionActive = try container.decodeIfPresent(Bool.self, forKey: .vehicleConnectionActive) ?? false
        lastVehicleConnectionAt = try container.decodeIfPresent(Date.self, forKey: .lastVehicleConnectionAt)
        parkingCandidateStartedAt = try container.decodeIfPresent(Date.self, forKey: .parkingCandidateStartedAt)
        parkingAnchorSample = try container.decodeIfPresent(LocationSample.self, forKey: .parkingAnchorSample)
        firstPostVehicleStationaryAt = try container.decodeIfPresent(Date.self, forKey: .firstPostVehicleStationaryAt)
        firstPedestrianAt = try container.decodeIfPresent(Date.self, forKey: .firstPedestrianAt)
        parkingEvidence = try container.decodeIfPresent(ParkingEvidence.self, forKey: .parkingEvidence)
        idlePrimingExhaustedAt = try container.decodeIfPresent(Date.self, forKey: .idlePrimingExhaustedAt)
        startSignal = try container.decodeIfPresent(DriveStartSignal.self, forKey: .startSignal)
        startVehicleHint = try container.decodeIfPresent(UUID.self, forKey: .startVehicleHint)
        startVehicleIsManual = try container.decodeIfPresent(Bool.self, forKey: .startVehicleIsManual) ?? false
        startVehicleAssignmentSource = try container.decodeIfPresent(
            VehicleAssignmentSource.self,
            forKey: .startVehicleAssignmentSource
        ) ?? (startVehicleHint == nil ? nil : (startVehicleIsManual ? .manual : .shortcut))
        conflictingVehicleIDs = Self.normalizedVehicleIDs(
            try container.decodeIfPresent([UUID].self, forKey: .conflictingVehicleIDs) ?? [],
            excluding: startVehicleHint
        )
        recentCyclingMotionDates = (try container.decodeIfPresent([Date].self, forKey: .recentCyclingMotionDates) ?? []).sorted()
        lastVehicleConnectionActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastVehicleConnectionActiveAt)
        vehicleAudioConnectionActive = try container.decodeIfPresent(Bool.self, forKey: .vehicleAudioConnectionActive) ?? false
        lastVehicleAutomationSignalAt = try container.decodeIfPresent(Date.self, forKey: .lastVehicleAutomationSignalAt)
        candidateHadBluetoothHint = try container.decodeIfPresent(Bool.self, forKey: .candidateHadBluetoothHint) ?? false
        candidateHadPowerHint = try container.decodeIfPresent(Bool.self, forKey: .candidateHadPowerHint) ?? false
        lastAcceptedSample = try container.decodeIfPresent(LocationSample.self, forKey: .lastAcceptedSample) ?? samples.last ?? candidateSamples.last
        pendingImpossibleSample = try container.decodeIfPresent(LocationSample.self, forKey: .pendingImpossibleSample)
        candidateContradictionCount = try container.decodeIfPresent(Int.self, forKey: .candidateContradictionCount) ?? 0
        lastCandidateContradiction = try container.decodeIfPresent(CandidateContradiction.self, forKey: .lastCandidateContradiction)
        recentCandidate = try container.decodeIfPresent(RecentCandidateSnapshot.self, forKey: .recentCandidate)
        candidateFirstMovementAt = try container.decodeIfPresent(Date.self, forKey: .candidateFirstMovementAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureID, forKey: .captureID)
        try container.encodeIfPresent(pendingTripID, forKey: .pendingTripID)
        try container.encode(phase, forKey: .phase)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(automaticTripStartMode, forKey: .automaticTripStartMode)
        try container.encodeIfPresent(automaticStartExcludedThrough, forKey: .automaticStartExcludedThrough)
        try container.encodeIfPresent(vehicleAutomationStartSignal, forKey: .vehicleAutomationStartSignal)
        try container.encodeIfPresent(candidateStartedAt, forKey: .candidateStartedAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(lastMovingAt, forKey: .lastMovingAt)
        try container.encodeIfPresent(firstStationaryAt, forKey: .firstStationaryAt)
        try container.encodeIfPresent(stopDueAt, forKey: .stopDueAt)
        try container.encodeIfPresent(lastProcessedLocationTimestamp, forKey: .lastProcessedLocationTimestamp)
        try container.encode(candidateSamples, forKey: .candidateSamples)
        try container.encode(samples, forKey: .samples)
        try container.encode(attentionReasons, forKey: .attentionReasons)
        try container.encodeIfPresent(parkedStartAnchor, forKey: .parkedStartAnchor)
        try container.encodeIfPresent(vehicleParkingAnchor, forKey: .vehicleParkingAnchor)
        try container.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        try container.encodeIfPresent(pendingCompletionDraft, forKey: .pendingCompletionDraft)
        try container.encode(pendingFees, forKey: .pendingFees)
        try container.encodeIfPresent(pendingClassification, forKey: .pendingClassification)
        try container.encodeIfPresent(pendingBusinessPurpose, forKey: .pendingBusinessPurpose)
        try container.encodeIfPresent(pendingNote, forKey: .pendingNote)
        try container.encode(vehicleConnectionActive, forKey: .vehicleConnectionActive)
        try container.encodeIfPresent(lastVehicleConnectionAt, forKey: .lastVehicleConnectionAt)
        try container.encodeIfPresent(parkingCandidateStartedAt, forKey: .parkingCandidateStartedAt)
        try container.encodeIfPresent(parkingAnchorSample, forKey: .parkingAnchorSample)
        try container.encodeIfPresent(firstPostVehicleStationaryAt, forKey: .firstPostVehicleStationaryAt)
        try container.encodeIfPresent(firstPedestrianAt, forKey: .firstPedestrianAt)
        try container.encodeIfPresent(parkingEvidence, forKey: .parkingEvidence)
        try container.encodeIfPresent(idlePrimingExhaustedAt, forKey: .idlePrimingExhaustedAt)
        try container.encodeIfPresent(startSignal, forKey: .startSignal)
        try container.encodeIfPresent(startVehicleHint, forKey: .startVehicleHint)
        try container.encode(startVehicleIsManual, forKey: .startVehicleIsManual)
        try container.encodeIfPresent(startVehicleAssignmentSource, forKey: .startVehicleAssignmentSource)
        try container.encode(conflictingVehicleIDs, forKey: .conflictingVehicleIDs)
        try container.encode(recentCyclingMotionDates, forKey: .recentCyclingMotionDates)
        try container.encodeIfPresent(lastVehicleConnectionActiveAt, forKey: .lastVehicleConnectionActiveAt)
        try container.encode(vehicleAudioConnectionActive, forKey: .vehicleAudioConnectionActive)
        try container.encodeIfPresent(lastVehicleAutomationSignalAt, forKey: .lastVehicleAutomationSignalAt)
        try container.encode(candidateHadBluetoothHint, forKey: .candidateHadBluetoothHint)
        try container.encode(candidateHadPowerHint, forKey: .candidateHadPowerHint)
        try container.encodeIfPresent(lastAcceptedSample, forKey: .lastAcceptedSample)
        try container.encodeIfPresent(pendingImpossibleSample, forKey: .pendingImpossibleSample)
        try container.encode(candidateContradictionCount, forKey: .candidateContradictionCount)
        try container.encodeIfPresent(lastCandidateContradiction, forKey: .lastCandidateContradiction)
        try container.encodeIfPresent(recentCandidate, forKey: .recentCandidate)
        try container.encodeIfPresent(candidateFirstMovementAt, forKey: .candidateFirstMovementAt)
    }

    private static func normalizedVehicleIDs(_ ids: [UUID], excluding vehicleID: UUID?) -> [UUID] {
        Array(Set(ids).subtracting(vehicleID.map { [$0] } ?? []))
            .sorted { $0.uuidString < $1.uuidString }
    }
}

public struct DriveCaptureLocationOptions: Equatable, Sendable {
    public var isStaleWake: Bool

    public static let normal = DriveCaptureLocationOptions(isStaleWake: false)
    public static let staleWake = DriveCaptureLocationOptions(isStaleWake: true)

    public init(isStaleWake: Bool = false) {
        self.isStaleWake = isStaleWake
    }
}

public enum DriveCaptureEvent: Equatable, Sendable {
    case location(LocationSample, receivedAt: Date, context: TripDetectionContext, options: DriveCaptureLocationOptions)
    case startSignal(DriveStartSignal, receivedAt: Date)
    case vehicleConnectionChanged(active: Bool, source: VehicleConnectionSource, at: Date)
    case motionActivity(MotionActivitySnapshot, receivedAt: Date)
    case stopTimerFired(Date)
    case sceneBecameInactive(Date)
    case sceneBecameActive(Date)
    case trackingPaused(until: Date?)
    case trackingResumed(Date)
    case trackingStopped(Date)
    case completionSaved(UUID)
    case completionDiscarded(UUID)
}

public enum DriveCaptureOutput: Equatable, Sendable {
    case ignored(String)
    case candidateStarted(Date)
    case tripStarted(Date)
    case tripUpdated(sampleCount: Int)
    case stopDeadlineChanged(Date?)
    case tripCompleted(TripDraft)
    case paused
    case parkingCandidateChanged(ParkingEvidence?)
    case checkpointChanged(DriveCaptureState)

    public var diagnosticOutput: String {
        switch self {
        case .ignored:
            "ignored"
        case .candidateStarted:
            "candidateStarted"
        case .tripStarted:
            "tripStarted"
        case .tripUpdated:
            "tripUpdated"
        case .stopDeadlineChanged:
            "stopDeadlineChanged"
        case .tripCompleted:
            "tripEnded"
        case .paused:
            "paused"
        case .parkingCandidateChanged:
            "parkingCandidateChanged"
        case .checkpointChanged:
            "checkpointChanged"
        }
    }
}

public struct DriveCaptureReducer: Sendable {
    public static let shortTripInferredAttentionReason = "Short trip inferred from sparse samples"
    public static let inferredStartAttentionReason = TripReviewPolicy.inferredStartAttentionReason
    public static let excessiveParkedDisplacementAttentionReason = "Start origin discarded — parked anchor too far"

    private enum VehicleEvidence {
        case automotiveMotion
        case reportedSpeed
        case derivedSpeed
        case assistedSpeed
    }

    private enum NonVehicleEvidence {
        case pedestrianMotion
        case stationaryMotion
        case lowSpeedMovement
    }

    private enum IgnoreReason: String {
        case weakGPSAccuracy = "Weak GPS accuracy"
        case impossibleGPSJump = "Impossible GPS jump"
        case noDrivingSignal = "No driving signal"
        case candidateTimedOut = "Unconfirmed candidate timed out"
        case staleWake = "Stale wake cached as parked anchor"
        case emptyCompletion = "Discarded empty drive (no usable route)"

        var message: String { rawValue }
    }

    private enum SpeedSource {
        case reported
        case derived
    }

    private struct MeasuredSpeed {
        var value: Double
        var source: SpeedSource
    }

    private struct VehicleAssistEvidence {
        var speedThreshold: Double
        var startDuration: TimeInterval
    }

    private struct SampleClassification {
        var vehicleEvidence: VehicleEvidence?
        var nonVehicleEvidence: NonVehicleEvidence?

        var isVehicle: Bool { vehicleEvidence != nil }
        var isUnknown: Bool { vehicleEvidence == nil && nonVehicleEvidence == nil }
        var isExitMovement: Bool {
            switch nonVehicleEvidence {
            case .pedestrianMotion, .lowSpeedMovement:
                true
            case .stationaryMotion, .none:
                false
            }
        }
        var isStationary: Bool { nonVehicleEvidence == .stationaryMotion }
        var isPedestrianMotion: Bool { nonVehicleEvidence == .pedestrianMotion }

        static func vehicle(_ evidence: VehicleEvidence) -> SampleClassification {
            SampleClassification(vehicleEvidence: evidence, nonVehicleEvidence: nil)
        }

        static func nonVehicle(_ evidence: NonVehicleEvidence) -> SampleClassification {
            SampleClassification(vehicleEvidence: nil, nonVehicleEvidence: evidence)
        }

        static var unknown: SampleClassification {
            SampleClassification(vehicleEvidence: nil, nonVehicleEvidence: nil)
        }
    }

    private struct CandidateMetrics {
        var elapsed: TimeInterval
        var sampleCount: Int
        var distanceMeters: Double
        var hasMovementEvidence: Bool
        var hasReportedSpeedEvidence: Bool
        var hasDerivedSpeedEvidence: Bool
        var hasMeaningfulDisplacement: Bool
        var hasAutomotiveEvidence: Bool
    }

    private var startPolicy: DriveStartPolicy {
        state.configuration.startPolicy
    }

    public private(set) var state: DriveCaptureState
    /// Persisted in diagnostic reasons, so later Motion Detection recovery cannot
    /// turn movement the user excluded into a trip.
    public static let automaticStartSuppressedReason = "Automatic start suppressed: Bluetooth or CarPlay automation required"
    package static let legacyAutomaticStartSuppressedReason = "Automatic start suppressed: saved vehicle required"

    public func allowsAutomaticTripStart(at date: Date) -> Bool {
        if state.automaticTripStartMode != .bluetoothOrCarPlay { return true }
        guard let signal = state.vehicleAutomationStartSignal, signal.isVehicleAutomation else { return false }
        return date >= signal.startedAt && date <= signal.expiresAt
    }

    public init(state: DriveCaptureState = DriveCaptureState()) {
        self.state = state
    }

    @discardableResult
    public mutating func setAutomaticTripStartMode(_ mode: AutomaticTripStartMode, at date: Date = Date()) -> [DriveCaptureOutput] {
        if state.automaticTripStartMode != mode { state.vehicleAutomationStartSignal = nil }
        state.automaticTripStartMode = mode
        return refreshAutomaticStartEligibility(at: date)
    }

    @discardableResult
    public mutating func refreshAutomaticStartEligibility(at date: Date) -> [DriveCaptureOutput] {
        if let signal = state.vehicleAutomationStartSignal, date > signal.expiresAt {
            state.vehicleAutomationStartSignal = nil
        }
        if !allowsAutomaticTripStart(at: date) { cancelUnadmittedCandidate() }
        return [.checkpointChanged(state)]
    }

    private mutating func cancelUnadmittedCandidate() {
        // A recorded (or explicitly paused) drive remains admitted through a
        // route flap. Only a not-yet-confirmed start is withdrawn.
        guard state.phase == .idle || state.phase == .candidate else { return }
        if let last = state.candidateSamples.last?.timestamp {
            excludeAutomaticStarts(through: last)
        }
        state.phase = .idle
        resetCandidate()
        state.recentCandidate = nil
        state.lastAcceptedSample = nil
        state.pendingImpossibleSample = nil
        state.vehicleParkingAnchor = nil
    }

    private mutating func excludeAutomaticStarts(through date: Date) {
        state.automaticStartExcludedThrough = max(state.automaticStartExcludedThrough ?? date, date)
    }

    private mutating func suppressAutomaticStart(at date: Date? = nil) -> [DriveCaptureOutput] {
        if let date { excludeAutomaticStarts(through: date) }
        cancelUnadmittedCandidate()
        return [.ignored(Self.automaticStartSuppressedReason), .checkpointChanged(state)]
    }

    @discardableResult
    public mutating func apply(_ event: DriveCaptureEvent) -> [DriveCaptureOutput] {
        let outputs: [DriveCaptureOutput]
        switch event {
        case .location(let sample, let receivedAt, let context, let options):
            outputs = ingest(sample, receivedAt: receivedAt, context: context, options: options)
        case .startSignal(let signal, let receivedAt):
            outputs = handleStartSignal(signal, receivedAt: receivedAt)
        case .vehicleConnectionChanged(let active, let source, let at):
            outputs = handleVehicleConnectionChanged(active: active, source: source, at: at)
        case .motionActivity(let snapshot, let receivedAt):
            outputs = handleMotionActivity(snapshot, receivedAt: receivedAt)
        case .stopTimerFired(let now):
            outputs = finalizeIfDue(now: now)
        case .sceneBecameInactive, .sceneBecameActive:
            outputs = [.checkpointChanged(state)]
        case .trackingPaused(let until):
            let keepsPendingTrip = !state.samples.isEmpty
            state.vehicleAutomationStartSignal = nil
            state.pausedUntil = until
            state.phase = .paused
            // Pause turns GPS off, so no sample can ever clear an armed stop
            // deadline; leaving it set spun the runtime's stop timer at zero
            // delay for the whole pause window (2026-08 field freeze).
            state.stopDueAt = nil
            resetCandidate(keepsPendingTrip: keepsPendingTrip)
            state.recentCandidate = nil
            outputs = [.paused, .checkpointChanged(state)]
        case .trackingResumed:
            state.pausedUntil = nil
            settlePhaseAfterPause()
            outputs = [.checkpointChanged(state)]
        case .trackingStopped(let now):
            outputs = stopTracking(at: now)
        case .completionSaved(let tripID):
            outputs = resolveCompletion(tripID: tripID, keptVehicleParkingAnchor: true)
        case .completionDiscarded(let tripID):
            outputs = resolveCompletion(tripID: tripID, keptVehicleParkingAnchor: false)
        }
        return outputs
    }

    private mutating func resolveCompletion(
        tripID: UUID,
        keptVehicleParkingAnchor: Bool
    ) -> [DriveCaptureOutput] {
        if state.pendingCompletionDraft?.id == tripID {
            state.pendingCompletionDraft = nil
        }
        if state.pendingTripID == tripID {
            state.pendingTripID = nil
        }
        // A split leg's save can land after the user has already classified the
        // new recording; those pendings belong to the live leg, not the saved trip.
        if state.phase != .recording {
            clearPendingReviewFields()
        }
        if !keptVehicleParkingAnchor {
            state.vehicleParkingAnchor = nil
        }
        return [.checkpointChanged(state)]
    }

    public mutating func replaceState(_ state: DriveCaptureState) {
        self.state = state
    }

    @discardableResult
    public mutating func setCurrentDriveClassification(_ classification: TripClassification?) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        state.pendingClassification = classification
        if classification != .business {
            state.pendingBusinessPurpose = nil
        }
        return [.checkpointChanged(state)]
    }

    @discardableResult
    public mutating func setCurrentDriveBusinessPurpose(_ purpose: String?) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        let trimmed = purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        state.pendingBusinessPurpose = trimmed.isEmpty ? nil : trimmed
        if !trimmed.isEmpty {
            state.pendingClassification = .business
        }
        return [.checkpointChanged(state)]
    }

    /// Mid-drive vehicle choice from the live bar. Passing nil reverts to
    /// automatic attribution (Shortcut vehicle or mapped Bluetooth device at
    /// completion); a concrete vehicle stamps the finished trip `.manual` so
    /// automatic re-attribution can never override the user's pick.
    @discardableResult
    public mutating func setCurrentDriveVehicle(_ vehicleID: UUID?) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        state.startVehicleHint = vehicleID
        state.startVehicleIsManual = vehicleID != nil
        state.startVehicleAssignmentSource = vehicleID == nil ? nil : .manual
        state.conflictingVehicleIDs = []
        return [.checkpointChanged(state)]
    }

    /// Applies a confidently mapped CarPlay/Bluetooth connection to the active
    /// capture. The first vehicle latches; disconnects and repeat observations
    /// are no-ops. A later different vehicle is recorded as a conflict without
    /// switching. A manual user choice always wins.
    @discardableResult
    public mutating func observeMappedVehicleConnection(_ vehicleID: UUID?) -> [DriveCaptureOutput] {
        let hasActivePausedDrive = state.phase == .paused
            && state.startedAt != nil
            && !state.samples.isEmpty
            && state.pendingTripID != nil
        guard let vehicleID,
              state.phase == .candidate || state.phase == .recording || hasActivePausedDrive else {
            return []
        }
        if state.startVehicleAssignmentSource == .manual || state.startVehicleIsManual {
            return []
        }
        guard let latchedVehicleID = state.startVehicleHint else {
            state.startVehicleHint = vehicleID
            state.startVehicleIsManual = false
            state.startVehicleAssignmentSource = .vehicleConnection
            state.conflictingVehicleIDs = []
            return [.checkpointChanged(state)]
        }
        guard latchedVehicleID != vehicleID else { return [] }
        guard !state.conflictingVehicleIDs.contains(vehicleID) else { return [] }
        state.conflictingVehicleIDs.append(vehicleID)
        state.conflictingVehicleIDs.sort { $0.uuidString < $1.uuidString }
        return [.checkpointChanged(state)]
    }

    @discardableResult
    public mutating func setCurrentDriveNote(_ note: String?) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        state.pendingNote = trimmed.isEmpty ? nil : trimmed
        return [.checkpointChanged(state)]
    }

    @discardableResult
    public mutating func appendCurrentDriveFee(_ fee: TripFee) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        var pendingFee = fee
        pendingFee.tripID = nil
        state.pendingFees.append(pendingFee)
        return [.checkpointChanged(state)]
    }

    @discardableResult
    public mutating func completeCurrentRecording(at date: Date) -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        let endDate = max(date, state.startedAt ?? date)
        return completeRecording(endDate: endDate)
    }

    /// Ends the current recording as a completed trip and atomically continues
    /// recording a new one from the same moment and position ("new leg"). The two
    /// legs are separate trips; pending classification/purpose/note/fees are
    /// snapshotted onto the finished leg and the new leg starts unclassified.
    @discardableResult
    public mutating func splitCurrentRecording(at date: Date) -> [DriveCaptureOutput] {
        guard state.phase == .recording, let startedAt = state.startedAt else { return [] }
        let endDate = max(date, startedAt)
        // A leg with no measurable route would be discarded by completeRecording
        // anyway; refuse to split instead of shedding a stub leg (also makes an
        // accidental double-tap a no-op).
        guard !isEmptyCompletion(completedTripDraft(startedAt: startedAt, endDate: endDate)) else {
            return [.ignored(IgnoreReason.emptyCompletion.message)]
        }
        // The new leg starts where the finished one ends: its last usable sample,
        // restamped to the split moment.
        let boundarySample = parkingAnchorSample(before: endDate)?.retimestamped(to: endDate)
        // completeRecording clears the vehicle hint, but the split's continuing
        // leg is the same car mid-motion — carry it (and whether it was a
        // manual pick) so leg 2+ gets the same attribution as leg 1.
        let continuingVehicleHint = state.startVehicleHint
        let continuingVehicleIsManual = state.startVehicleIsManual
        let continuingVehicleSource = state.startVehicleAssignmentSource
        let continuingVehicleConflicts = state.conflictingVehicleIDs
        var outputs = completeRecording(endDate: endDate)
        state.startVehicleHint = continuingVehicleHint
        state.startVehicleIsManual = continuingVehicleIsManual
        state.startVehicleAssignmentSource = continuingVehicleSource
        state.conflictingVehicleIDs = continuingVehicleConflicts
        state.captureID = UUID()
        state.pendingTripID = UUID()
        state.phase = .recording
        state.startedAt = endDate
        state.samples = boundarySample.map { [$0] } ?? []
        state.lastMovingAt = endDate
        state.firstStationaryAt = nil
        state.stopDueAt = nil
        state.attentionReasons = []
        // The car is mid-motion, not parked; a parked anchor here would also let
        // applyDeferredVehicleParkingAnchorIfNeeded prepend a back-dated start.
        state.parkedStartAnchor = nil
        state.vehicleParkingAnchor = nil
        clearPendingReviewFields()
        outputs.append(.tripStarted(endDate))
        outputs.append(.tripUpdated(sampleCount: state.samples.count))
        return outputs
    }

    @discardableResult
    public mutating func discardCurrentDrive() -> [DriveCaptureOutput] {
        guard state.currentDriveSummary() != nil else { return [] }
        state.phase = .idle
        state.startedAt = nil
        state.samples = []
        state.lastMovingAt = nil
        state.firstStationaryAt = nil
        state.stopDueAt = nil
        state.attentionReasons = []
        state.pausedUntil = nil
        state.pendingCompletionDraft = nil
        state.pendingTripID = nil
        resetParkingCandidate()
        resetCandidate()
        state.recentCandidate = nil
        state.parkedStartAnchor = nil
        state.vehicleParkingAnchor = nil
        clearPendingReviewFields()
        return [.checkpointChanged(state), .stopDeadlineChanged(nil)]
    }

    @discardableResult
    public mutating func finalizeIfDue(now: Date) -> [DriveCaptureOutput] {
        // An expired pause must resume here, not only on a location sample —
        // GPS is off while paused, so a sample can never arrive to clear it,
        // and an uncleared pause keeps the capture policy at the unwakeable
        // `.paused` level forever ("Pause Today" becoming "pause forever").
        if let pausedUntil = state.pausedUntil, now >= pausedUntil {
            state.pausedUntil = nil
        }
        settlePhaseAfterPause()

        if state.phase == .candidate, !allowsAutomaticTripStart(at: now) {
            return suppressAutomaticStart(at: now)
        }

        if state.phase == .candidate,
           let startSignal = state.startSignal,
           now >= startSignal.expiresAt {
            return resolveExpiredCandidate(evidenceAt: now, rejectedAt: now) + [.checkpointChanged(state)]
        }

        guard state.phase == .recording,
              let stopDueAt = state.stopDueAt,
              now >= stopDueAt else {
            return [.checkpointChanged(state)]
        }
        return completeRecording(endDate: completionEndDate(forStopDueAt: stopDueAt))
    }

    /// Settles a cleared pause back into `.recording`/`.idle`. Any stop
    /// deadline armed before the pause is stale evidence — resuming must not
    /// instantly complete the drive at a pre-pause timestamp, and legacy
    /// checkpoints from the wedged-pause bug carry one that must be scrubbed.
    private mutating func settlePhaseAfterPause() {
        guard state.phase == .paused, state.pausedUntil == nil else { return }
        state.phase = state.samples.isEmpty ? .idle : .recording
        state.stopDueAt = nil
    }

    private mutating func ingest(
        _ sample: LocationSample,
        receivedAt: Date,
        context: TripDetectionContext,
        options: DriveCaptureLocationOptions
    ) -> [DriveCaptureOutput] {
        if state.phase == .paused, state.currentDriveSummary() == nil, !allowsAutomaticTripStart(at: receivedAt) {
            // In-flight provider updates can arrive after pause has stopped
            // GPS. Keep the exclusion durable even though pause wins the UI.
            state.lastProcessedLocationTimestamp = sample.timestamp
            excludeAutomaticStarts(through: sample.timestamp)
            return [.paused, .ignored(Self.automaticStartSuppressedReason), .checkpointChanged(state)]
        }
        if let pausedUntil = state.pausedUntil, sample.timestamp < pausedUntil {
            return [.paused, .checkpointChanged(state)]
        }
        if let pausedUntil = state.pausedUntil, sample.timestamp >= pausedUntil {
            state.pausedUntil = nil
            settlePhaseAfterPause()
        }

        state.lastProcessedLocationTimestamp = sample.timestamp
        if let cutoff = state.automaticStartExcludedThrough, sample.timestamp <= cutoff {
            return [.ignored(Self.automaticStartSuppressedReason), .checkpointChanged(state)]
        }
        if state.automaticTripStartMode == .bluetoothOrCarPlay,
           state.phase == .idle || state.phase == .candidate,
           let authorization = state.vehicleAutomationStartSignal,
           sample.timestamp < authorization.startedAt {
            excludeAutomaticStarts(through: sample.timestamp)
            return [.ignored(Self.automaticStartSuppressedReason), .checkpointChanged(state)]
        }
        if (state.phase == .idle || state.phase == .candidate), !allowsAutomaticTripStart(at: receivedAt) {
            // Includes stale/poor fixes: diagnostics must remember the user's
            // exclusion rather than later recovering these as a missed drive.
            updateParkedStartAnchorIfNeeded(sample)
            return suppressAutomaticStart(at: sample.timestamp)
        }
        if context.trustedBluetoothVehicleHint {
            state.lastVehicleConnectionActiveAt = max(
                state.lastVehicleConnectionActiveAt ?? sample.timestamp,
                sample.timestamp
            )
        }

        if options.isStaleWake {
            updateParkedStartAnchorIfNeeded(sample)
            return [.ignored(IgnoreReason.staleWake.message), .checkpointChanged(state)]
        }

        guard sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= state.configuration.maxHorizontalAccuracyMeters else {
            return [.ignored(IgnoreReason.weakGPSAccuracy.message), .checkpointChanged(state)]
        }

        if shouldIgnoreAsImpossibleJump(sample) {
            recordImpossibleJumpAttention(rejectedAt: receivedAt)
            return [.ignored(IgnoreReason.impossibleGPSJump.message), .checkpointChanged(state)]
        }

        let outputs: [DriveCaptureOutput]
        switch state.phase {
        case .idle, .paused:
            outputs = ingestIdle(sample, context: context)
        case .candidate:
            outputs = ingestCandidate(sample, receivedAt: receivedAt, context: context)
        case .recording:
            outputs = ingestRecording(sample, receivedAt: receivedAt, context: context)
        }
        state.lastAcceptedSample = sample
        return outputs + [.checkpointChanged(state)]
    }

    private mutating func ingestIdle(_ sample: LocationSample, context: TripDetectionContext) -> [DriveCaptureOutput] {
        guard allowsAutomaticTripStart(at: sample.timestamp) else {
            updateParkedStartAnchorIfNeeded(sample)
            return suppressAutomaticStart()
        }
        let classification = classify(sample, context: context, allowsPedestrianSpeedOverride: false)
        guard classification.isVehicle else {
            updateParkedStartAnchorIfNeeded(sample)
            return [.ignored(IgnoreReason.noDrivingSignal.message)]
        }
        guard !shouldSuppressPostParkingSpeedOnlyStart(sample, classification: classification, context: context) else {
            updateParkedStartAnchorIfNeeded(sample)
            return [.ignored(IgnoreReason.noDrivingSignal.message)]
        }
        guard !isDuplicateRecentCandidateStart(
            source: .acceptedVehicleLocation,
            startedAt: sample.timestamp,
            observedAt: sample.timestamp,
            coordinate: sample.coordinate
        ) else {
            return [.checkpointChanged(state)]
        }

        state.captureID = UUID()
        state.pendingTripID = UUID()
        state.phase = .candidate
        state.candidateStartedAt = sample.timestamp
        state.candidateSamples = [sample]
        state.candidateFirstMovementAt = isGenuineMovementEvidence(classification, sample: sample) ? sample.timestamp : nil
        state.startSignal = DriveStartEngine.signal(
            source: .acceptedVehicleLocation,
            startedAt: sample.timestamp,
            policy: startPolicy
        )
        state.candidateHadBluetoothHint = hasBluetoothAssistHint(context)
        state.candidateHadPowerHint = hasPowerAssistHint(context)
        // The parked anchor intentionally persists across candidate arming so a
        // confirmed start can backdate from it; it is cleared on confirmation.
        inheritRecentCandidateIfFresh(at: sample.timestamp)
        return [.candidateStarted(state.candidateStartedAt ?? sample.timestamp)]
    }

    private mutating func ingestCandidate(
        _ sample: LocationSample,
        receivedAt: Date,
        context: TripDetectionContext
    ) -> [DriveCaptureOutput] {
        guard allowsAutomaticTripStart(at: receivedAt) else { return suppressAutomaticStart(at: receivedAt) }
        let classification = classify(sample, context: context, allowsPedestrianSpeedOverride: true)
        guard classification.isVehicle else {
            if classification.isUnknown {
                // A fix with no measurable speed and no motion hint says
                // nothing either way and must not spend the contradiction
                // budget: a GPS cold-start burst delivers several such fixes
                // inside one second (2026-07-07 17 Pro ignition — sub-second
                // pairs can't derive speed, so the burst would otherwise burn
                // the whole budget before the first real fix arrives).
                return [.tripUpdated(sampleCount: state.candidateSamples.count)]
            }
            if let draft = rescuedShortTrip(endingWith: sample, classification: classification, context: context) {
                state.pendingCompletionDraft = draft
                resetCandidate()
                // resetCandidate skips the hint clear while a completion draft is
                // pending; mirror completeRecording (the draft already carries the
                // vehicle) so a later location-armed drive isn't tagged with it.
                state.startVehicleHint = nil
                state.startVehicleIsManual = false
                state.startVehicleAssignmentSource = nil
                state.conflictingVehicleIDs = []
                // The vehicle is now parked at the rescue end location, not the pre-trip
                // spot. Mirror completeRecording: drop the stale vehicle anchor and
                // re-anchor to the end sample only if it's accurate & stationary.
                state.parkedStartAnchor = nil
                state.vehicleParkingAnchor = nil
                updateParkedStartAnchorIfNeeded(sample)
                updateVehicleParkingAnchorIfEligible(sample)
                state.phase = .idle
                state.recentCandidate = nil
                state.vehicleAutomationStartSignal = nil
                return [.tripCompleted(draft)]
            }
            let isGracedContradiction = classification.isStationary
                || (classification.nonVehicleEvidence == .lowSpeedMovement && startPolicy.candidateResilience.preMovementToleratesLowSpeed)
                || (classification.isPedestrianMotion && hasActiveVehicleConnection(context: context, at: sample.timestamp))
            if isGracedContradiction, isVehicleTriggerArmedCandidate(at: sample.timestamp, context: context) {
                // Pre-movement grace: a vehicle-triggered candidate that hasn't
                // moved yet patiently waits out parked-stationary samples instead
                // of burning the contradiction budget. Pedestrian/cycling samples
                // normally kill the candidate (walking away from the car), with
                // one exception: while the trusted vehicle connection is live,
                // "walking" is the driver settling into a running car, not a
                // departure — CoreMotion keeps reporting high-confidence walking
                // for seconds after sitting down, and a cold-GPS burst can spend
                // the whole contradiction budget inside one of those seconds
                // (2026-07-07: the 17 Pro killed a trusted-Bluetooth +
                // Shortcut-armed candidate 4 s after ignition and slept through
                // the first three minutes of the drive).
                return [.tripUpdated(sampleCount: state.candidateSamples.count)]
            }
            recordCandidateContradiction(classification, at: sample.timestamp)
            if state.candidateContradictionCount < startPolicy.candidateResilience.maximumConsecutiveContradictions {
                // Tolerated flicker. Returning .ignored here would clear
                // pending start signals upstream, so report a passive update
                // and keep collecting.
                return [.tripUpdated(sampleCount: state.candidateSamples.count)]
            }
            let reason = candidateDiagnosticReason(prefix: IgnoreReason.noDrivingSignal.message, context: context, at: sample.timestamp)
            stashRecentCandidate(rejectedAt: receivedAt)
            resetCandidate()
            state.phase = .idle
            updateParkedStartAnchorIfNeeded(sample)
            return [.ignored(reason)]
        }

        state.candidateContradictionCount = 0
        state.candidateSamples.append(sample)
        recordCandidateAssistHints(context)
        if state.candidateFirstMovementAt == nil, isGenuineMovementEvidence(classification, sample: sample) {
            state.candidateFirstMovementAt = sample.timestamp
        }
        let metrics = candidateMetrics(context: context)
        // A candidate that reaches its signal high-fidelity expiry without having
        // confirmed through the normal flow resolves the same way as the scheduled
        // expiry timer: confirm if still qualifying, otherwise time out. This keeps
        // the location-driven and timer-driven expiry paths on one cutoff. Checked
        // before the first-movement guard below so a never-moved candidate still
        // resolves here instead of only via the separate scheduled timer.
        if let expiresAt = state.startSignal?.expiresAt, sample.timestamp >= expiresAt {
            return resolveExpiredCandidate(evidenceAt: sample.timestamp, rejectedAt: receivedAt)
        }
        // No confirmed first-movement sample yet (e.g. only ambiguous
        // automotive-while-stationary evidence so far) - there is no real
        // movement duration to measure the assisted-start window against, so
        // keep collecting rather than falling back to a trigger-time elapsed
        // clock that would let parked wall-clock time alone satisfy it.
        guard let firstMovementAt = state.candidateFirstMovementAt else {
            return [.tripUpdated(sampleCount: state.candidateSamples.count)]
        }
        let elapsed = sample.timestamp.timeIntervalSince(firstMovementAt)

        let requiredDuration = vehicleAssistEvidence(
            context: context,
            includeCandidateBluetoothHistory: state.candidateHadBluetoothHint,
            includeCandidatePowerHistory: state.candidateHadPowerHint
        )?.startDuration
            ?? state.configuration.minimumStartDuration
        guard elapsed >= requiredDuration, metrics.hasMovementEvidence else {
            return [.tripUpdated(sampleCount: state.candidateSamples.count)]
        }

        let evidence = candidateConfirmationEvidence(metrics: metrics, context: context, at: sample.timestamp)
        switch DriveCandidateConfirmationPolicy().disposition(for: evidence) {
        case .confirmVisible:
            break
        case .continueCollecting:
            return [.tripUpdated(sampleCount: state.candidateSamples.count)]
        case .deferToDiagnostics(let reason):
            let diagnosticReason = candidateDiagnosticReason(prefix: reason.message, metrics: metrics, at: sample.timestamp)
            stashRecentCandidate(rejectedAt: receivedAt)
            resetCandidate()
            state.phase = .idle
            updateParkedStartAnchorIfNeeded(sample)
            return [.ignored(diagnosticReason)]
        }

        return beginRecordingFromCandidate(lastMovingAt: sample.timestamp)
    }

    /// Promotes the live candidate to an active recording. Shared by the normal
    /// confirmation flow and the expiry resolver so both produce identical state.
    private mutating func beginRecordingFromCandidate(lastMovingAt: Date) -> [DriveCaptureOutput] {
        guard allowsAutomaticTripStart(at: lastMovingAt) else { return suppressAutomaticStart(at: lastMovingAt) }
        let prepared = prepareTripStart()
        let shouldDeferVehicleParkingAnchor = prepared.samples.isEmpty && state.vehicleParkingAnchor != nil
        state.phase = .recording
        state.vehicleAutomationStartSignal = nil
        state.startedAt = prepared.startedAt
        state.samples = prepared.samples
        state.lastMovingAt = lastMovingAt
        state.firstStationaryAt = nil
        state.stopDueAt = nil
        state.attentionReasons = prepared.attentionReasons
        // The generic anchor has done its only job (wake-up) once recording
        // begins. Keep a confirmed vehicle anchor only long enough to cover a
        // sampleless candidate's first real location.
        state.parkedStartAnchor = nil
        if !shouldDeferVehicleParkingAnchor {
            state.vehicleParkingAnchor = nil
        }
        state.recentCandidate = nil
        resetCandidate(keepsPendingTrip: true)
        return [.tripStarted(prepared.startedAt), .tripUpdated(sampleCount: state.samples.count)]
    }

    /// Single authoritative candidate-expiry path, shared by the scheduled timer
    /// (`finalizeIfDue`) and the location-driven path. Confirms a still-qualifying
    /// candidate — so a drive that goes GPS-silent right after arming isn't lost —
    /// and otherwise discards it as timed out / diagnostic-only.
    private mutating func resolveExpiredCandidate(evidenceAt: Date, rejectedAt: Date) -> [DriveCaptureOutput] {
        let context = signalDetectionContext()
        let metrics = candidateMetrics(context: context)
        let evidence = candidateConfirmationEvidence(metrics: metrics, context: context, at: evidenceAt)
        switch DriveCandidateConfirmationPolicy().disposition(for: evidence) {
        case .confirmVisible:
            return beginRecordingFromCandidate(lastMovingAt: state.candidateSamples.last?.timestamp ?? evidenceAt)
        case .deferToDiagnostics(let reason):
            return discardExpiredCandidate(
                prefix: reason.message,
                metrics: metrics,
                evidenceAt: evidenceAt,
                rejectedAt: rejectedAt
            )
        case .continueCollecting:
            return discardExpiredCandidate(
                prefix: IgnoreReason.candidateTimedOut.message,
                metrics: metrics,
                evidenceAt: evidenceAt,
                rejectedAt: rejectedAt
            )
        }
    }

    private mutating func discardExpiredCandidate(
        prefix: String,
        metrics: CandidateMetrics,
        evidenceAt: Date,
        rejectedAt: Date
    ) -> [DriveCaptureOutput] {
        let reason = candidateDiagnosticReason(prefix: prefix, metrics: metrics, at: evidenceAt)
        stashRecentCandidate(rejectedAt: rejectedAt)
        resetCandidate()
        state.phase = .idle
        return [.ignored(reason)]
    }

    private mutating func ingestRecording(
        _ sample: LocationSample,
        receivedAt: Date,
        context: TripDetectionContext
    ) -> [DriveCaptureOutput] {
        let classification = classify(sample, context: context, allowsPedestrianSpeedOverride: false)
        if let stopDueAt = state.stopDueAt, sample.timestamp >= stopDueAt {
            let completion = completeRecording(endDate: completionEndDate(forStopDueAt: stopDueAt))
            let followup = classification.isVehicle ? ingestIdle(sample, context: context) : []
            return completion + followup
        }

        if let parkingOutputs = handleParkingCandidateSample(sample, classification: classification) {
            return parkingOutputs
        }

        if let lastSample = state.samples.last,
           classification.isVehicle,
           silentStopEndDate(before: sample, lastSample: lastSample) != nil {
            let endDate = lastSample.timestamp
            let completion = completeRecording(endDate: endDate)
            let followup = ingestIdle(sample, context: context)
            return completion + followup
        }

        applyDeferredVehicleParkingAnchorIfNeeded(firstTripSample: sample)
        state.samples.append(sample)
        if classification.isVehicle {
            state.lastMovingAt = sample.timestamp
            state.firstStationaryAt = nil
            resetParkingCandidate()
            if state.stopDueAt != nil {
                state.stopDueAt = nil
                return [.stopDeadlineChanged(nil), .tripUpdated(sampleCount: state.samples.count)]
            }
            return [.tripUpdated(sampleCount: state.samples.count)]
        }

        if classification.isUnknown, isTrafficStopProtected(at: sample.timestamp) {
            let base = state.lastMovingAt ?? sample.timestamp
            let hold = openTrafficStopHold(at: sample.timestamp, base: base)
            return hold + [.tripUpdated(sampleCount: state.samples.count)]
        }

        if classification.isExitMovement || classification.isStationary {
            if state.firstStationaryAt == nil {
                state.firstStationaryAt = sample.timestamp
            }
            recordPostVehicleMotion(sample.timestamp, classification: classification)
            if let completion = completeForParkingMotionIfNeeded(sample: sample, classification: classification) {
                return completion
            }
            let timeout = classification.isExitMovement
                ? state.configuration.pedestrianExitTimeout
                : state.configuration.stopTimeout
            let base = state.lastMovingAt ?? sample.timestamp
            if isTrafficStopProtected(at: sample.timestamp) {
                let hold = openTrafficStopHold(at: sample.timestamp, base: base)
                return hold + [.tripUpdated(sampleCount: state.samples.count)]
            }
            let due = base.addingTimeInterval(timeout)
            let changed = state.stopDueAt != due
            state.stopDueAt = due
            if state.parkingEvidence == nil {
                state.parkingCandidateStartedAt = state.firstStationaryAt ?? sample.timestamp
                state.parkingAnchorSample = parkingAnchorSample(before: base)
                state.parkingEvidence = ParkingEvidence(
                    signal: .fallbackStationaryTimeout,
                    confidence: .fallback,
                    signalAt: sample.timestamp,
                    inferredEndAt: due,
                    anchorSample: state.parkingAnchorSample
                )
            }
            if receivedAt >= due || sample.timestamp >= due {
                return completeRecording(endDate: due)
            }
            return changed
                ? [.stopDeadlineChanged(due), .tripUpdated(sampleCount: state.samples.count)]
                : [.tripUpdated(sampleCount: state.samples.count)]
        }

        return [.tripUpdated(sampleCount: state.samples.count)]
    }

    private mutating func handleVehicleConnectionChanged(
        active: Bool,
        source: VehicleConnectionSource,
        at date: Date
    ) -> [DriveCaptureOutput] {
        state.vehicleConnectionActive = active
        state.lastVehicleConnectionAt = date
        if source != .usbPower {
            // A known audio disconnect is also the last instant the car was
            // present. USB changes must not clear an independent audio route.
            if active || state.vehicleAudioConnectionActive {
                state.lastVehicleConnectionActiveAt = max(state.lastVehicleConnectionActiveAt ?? date, date)
            }
            state.vehicleAudioConnectionActive = active
        }

        if active, (state.phase == .idle || state.phase == .candidate) {
            return handleStartSignal(
                DriveStartEngine.signal(forVehicleConnection: source, at: date, policy: startPolicy),
                receivedAt: date
            )
        }

        guard state.phase == .recording else {
            return [.checkpointChanged(state)]
        }

        if active {
            if let canceled = cancelParkingCandidate(reason: "Vehicle connection resumed") {
                return [.parkingCandidateChanged(canceled), .stopDeadlineChanged(state.stopDueAt)]
            }
            return [.checkpointChanged(state)]
        }

        if isTrafficStopProtected(at: date) {
            let base = state.lastMovingAt ?? date
            let deadline = trafficStopHoldDeadline(base: base)
            let evidence = beginParkingCandidate(
                signal: .trafficStopHold,
                source: source,
                confidence: .fallback,
                signalAt: date,
                inferredEndAt: deadline
            )
            updateTrafficStopAnchor(base: base)
            state.stopDueAt = deadline
            return [.parkingCandidateChanged(state.parkingEvidence ?? evidence), .stopDeadlineChanged(deadline)]
        }

        let confidence: ParkingConfidence = source == .usbPower ? .assist : .hard
        let evidence = beginParkingCandidate(
            signal: .vehicleConnectionDisconnected,
            source: source,
            confidence: confidence,
            signalAt: date,
            inferredEndAt: max(date, state.startedAt ?? date)
        )
        if confidence == .hard {
            let due = date.addingTimeInterval(startPolicy.parkingEnd.hardParkingGrace)
            state.stopDueAt = due
            return [.parkingCandidateChanged(evidence), .stopDeadlineChanged(due)]
        }
        // Assist disconnect (e.g. USB power): a settling stationary/pedestrian
        // sample completes earlier via handleParkingCandidateSample, but arm a
        // bounded backstop so the trip can't linger in .recording forever if GPS
        // and motion both go quiet right after unplugging.
        let due = date.addingTimeInterval(state.configuration.stopTimeout)
        state.stopDueAt = due
        return [.parkingCandidateChanged(evidence), .stopDeadlineChanged(due)]
    }

    private mutating func handleMotionActivity(
        _ snapshot: MotionActivitySnapshot,
        receivedAt: Date
    ) -> [DriveCaptureOutput] {
        // Remembered before any phase logic acts on it: the snapshot that kills
        // a candidate and the one that parks a recording are exactly the
        // evidence the cycling classifier needs.
        if snapshot.confidence == .high, snapshot.contains(.cycling) {
            recordCyclingMotion(at: snapshot.startDate)
        }

        if state.phase == .idle || state.phase == .candidate {
            if let signal = DriveStartEngine.signal(forMotion: snapshot, policy: startPolicy) {
                return handleStartSignal(
                    signal,
                    receivedAt: receivedAt
                )
            }
            if state.phase == .candidate,
               state.startSignal != nil,
               state.candidateSamples.isEmpty,
               snapshot.startDate >= (state.candidateStartedAt ?? snapshot.startDate),
               snapshot.contains(.walking) || snapshot.contains(.running) || snapshot.contains(.cycling) || snapshot.contains(.stationary) {
                let isPedestrianSnapshot = snapshot.contains(.walking) || snapshot.contains(.running) || snapshot.contains(.cycling)
                let isGracedPedestrianSnapshot = isPedestrianSnapshot
                    && !snapshot.contains(.cycling)
                    && hasActiveVehicleConnection(context: signalDetectionContext(), at: snapshot.startDate)
                if !isPedestrianSnapshot || isGracedPedestrianSnapshot,
                   isVehicleTriggerArmedCandidate(at: snapshot.startDate, context: signalDetectionContext()) {
                    // Pre-movement grace: a stationary-only motion snapshot from a
                    // vehicle-triggered candidate that hasn't moved yet must not
                    // kill it - mirrors the location-sample patience in
                    // ingestCandidate. Pedestrian snapshots (walking/running/
                    // cycling) still kill during grace, with the same exception
                    // as the location path: while the vehicle Bluetooth link is
                    // live, "walking" is the driver settling into a running car
                    // (2026-07-07 17 Pro ignition kill), not a departure.
                    // Cycling is never graced — riding off with the car's
                    // Bluetooth in range is a real departure.
                    return [.checkpointChanged(state)]
                }
                let kind: CandidateContradiction.Kind = isPedestrianSnapshot ? .pedestrian : .stationary
                state.candidateContradictionCount += 1
                state.lastCandidateContradiction = CandidateContradiction(at: snapshot.startDate, kind: kind)
                stashRecentCandidate(rejectedAt: receivedAt)
                resetCandidate()
                state.phase = .idle
                return [.ignored(IgnoreReason.noDrivingSignal.message), .checkpointChanged(state)]
            }
            return [.checkpointChanged(state)]
        }

        guard state.phase == .recording,
              snapshot.startDate >= (state.startedAt ?? snapshot.startDate) else {
            return [.checkpointChanged(state)]
        }

        if snapshot.contains(.automotive) {
            state.firstPostVehicleStationaryAt = nil
            state.firstPedestrianAt = nil
            if state.parkingEvidence != nil,
               snapshot.startDate > (state.parkingCandidateStartedAt ?? snapshot.startDate) {
                if let canceled = cancelParkingCandidate(reason: "Automotive motion continued") {
                    return [.parkingCandidateChanged(canceled), .stopDeadlineChanged(state.stopDueAt)]
                }
            }
            return [.checkpointChanged(state)]
        }

        let classification: SampleClassification
        if snapshot.contains(.walking) || snapshot.contains(.running) || snapshot.contains(.cycling) {
            classification = .nonVehicle(.pedestrianMotion)
        } else if snapshot.contains(.stationary) {
            classification = .nonVehicle(.stationaryMotion)
        } else {
            return [.checkpointChanged(state)]
        }

        recordPostVehicleMotion(snapshot.startDate, classification: classification)
        if let completion = completeForParkingMotionIfNeeded(sample: nil, at: snapshot.startDate, classification: classification) {
            return completion
        }

        if isTrafficStopProtected(at: snapshot.startDate),
           let lastMovingAt = state.lastMovingAt {
            return openTrafficStopHold(at: snapshot.startDate, base: lastMovingAt) + [.checkpointChanged(state)]
        }

        if classification.isStationary,
           state.stopDueAt == nil,
           let lastMovingAt = state.lastMovingAt {
            let due = lastMovingAt.addingTimeInterval(state.configuration.stopTimeout)
            state.stopDueAt = due
            if state.parkingEvidence == nil {
                let evidence = beginParkingCandidate(
                    signal: .fallbackStationaryTimeout,
                    source: nil,
                    confidence: .fallback,
                    signalAt: snapshot.startDate,
                    inferredEndAt: due
                )
                return [.parkingCandidateChanged(evidence), .stopDeadlineChanged(due)]
            }
            return [.stopDeadlineChanged(due), .checkpointChanged(state)]
        }

        return [.checkpointChanged(state)]
    }

    private mutating func handleStartSignal(
        _ signal: DriveStartSignal,
        receivedAt: Date
    ) -> [DriveCaptureOutput] {
        if state.automaticTripStartMode == .motionDetection,
           signal.source == .externalVehicleAutomation,
           signal.externalTrigger != .manual {
            return [.ignored("Bluetooth or CarPlay automation ignored in Motion Detection mode"), .checkpointChanged(state)]
        }
        guard receivedAt <= signal.expiresAt,
              state.automaticTripStartMode != .bluetoothOrCarPlay || receivedAt >= signal.startedAt else {
            return [.ignored(IgnoreReason.candidateTimedOut.message), .checkpointChanged(state)]
        }
        if state.phase == .idle || state.phase == .candidate {
            if state.automaticTripStartMode == .bluetoothOrCarPlay, signal.isVehicleAutomation {
                if allowsAutomaticTripStart(at: receivedAt), let previous = state.vehicleAutomationStartSignal {
                    // Bluetooth and CarPlay often fire for the same departure.
                    // A later approved event can extend expiry, but must not
                    // retroactively exclude delayed fixes inside the first window.
                    state.vehicleAutomationStartSignal = previous.merged(with: signal)
                } else {
                    cancelUnadmittedCandidate()
                    state.vehicleAutomationStartSignal = signal
                }
            }
            guard allowsAutomaticTripStart(at: receivedAt) else { return suppressAutomaticStart(at: receivedAt) }
        }
        var signal = signal
        if state.automaticTripStartMode == .bluetoothOrCarPlay,
           let authorization = state.vehicleAutomationStartSignal {
            signal.startedAt = max(signal.startedAt, authorization.startedAt)
            signal.expiresAt = min(signal.expiresAt, authorization.expiresAt)
        }
        if let cutoff = state.automaticStartExcludedThrough {
            signal.startedAt = max(signal.startedAt, cutoff)
        }
        guard receivedAt <= signal.expiresAt else {
            return [.ignored(IgnoreReason.candidateTimedOut.message), .checkpointChanged(state)]
        }

        switch state.phase {
        case .idle:
            guard !isDuplicateRecentCandidateStart(source: signal.source, startedAt: signal.startedAt, observedAt: receivedAt) else {
                return [.checkpointChanged(state)]
            }
            // Post-kill cooldown backstop (the runtime gates these same
            // sources before applying; this keeps checkpoint replays honest).
            // Passive location wakes — anchor exit, SLC, visit departure,
            // coarse wake — may not reopen a probe right after a never-moved
            // pedestrian/stationary kill; motion/Bluetooth/power/strong
            // signals stay ungated.
            if Self.postKillCooldownGatedSources.contains(signal.source),
               isParkedExitRearmSuppressed(at: receivedAt) {
                return [.checkpointChanged(state)]
            }
            state.captureID = UUID()
            state.pendingTripID = UUID()
            state.phase = .candidate
            state.candidateStartedAt = signal.startedAt
            state.candidateSamples = []
            state.startSignal = signal
            state.startVehicleHint = signal.vehicleID
            state.startVehicleIsManual = false
            state.startVehicleAssignmentSource = signal.vehicleID == nil ? nil : .shortcut
            state.conflictingVehicleIDs = []
            applyStartSignalContributions(signal)
            inheritRecentCandidateIfFresh(at: receivedAt)
            return [.candidateStarted(state.candidateStartedAt ?? signal.startedAt), .checkpointChanged(state)]
        case .candidate:
            state.startSignal = state.startSignal?.merged(with: signal) ?? signal
            if state.automaticTripStartMode == .bluetoothOrCarPlay,
               let authorization = state.vehicleAutomationStartSignal {
                let deadline = min(state.startSignal?.expiresAt ?? authorization.expiresAt, authorization.expiresAt)
                state.startSignal?.expiresAt = deadline
            }
            if let candidateStartedAt = state.candidateStartedAt {
                state.candidateStartedAt = min(candidateStartedAt, signal.startedAt)
            } else {
                state.candidateStartedAt = signal.startedAt
            }
            if state.startVehicleHint == nil, let vehicleID = signal.vehicleID {
                state.startVehicleHint = vehicleID
                state.startVehicleAssignmentSource = .shortcut
            }
            applyStartSignalContributions(signal)
            return [.checkpointChanged(state)]
        case .recording, .paused:
            if state.phase == .recording {
                recordVehicleAutomationEvidence(signal)
            }
            // A per-car automation can fire seconds after motion already confirmed
            // the drive; capture the vehicle so the finished trip is still tagged.
            if state.startVehicleHint == nil, let vehicleID = signal.vehicleID {
                state.startVehicleHint = vehicleID
                state.startVehicleAssignmentSource = .shortcut
            }
            return [.checkpointChanged(state)]
        }
    }

    private mutating func handleParkingCandidateSample(
        _ sample: LocationSample,
        classification: SampleClassification
    ) -> [DriveCaptureOutput]? {
        guard let evidence = state.parkingEvidence else {
            return nil
        }

        if evidence.signal == .trafficStopHold {
            if classification.isVehicle {
                if isTrafficStopVehicleContinuation(sample, classification: classification) {
                    let canceled = cancelParkingCandidate(reason: "Vehicle movement continued")
                    var outputs: [DriveCaptureOutput] = []
                    if let canceled {
                        outputs.append(.parkingCandidateChanged(canceled))
                    }
                    if state.stopDueAt == nil {
                        outputs.append(.stopDeadlineChanged(nil))
                    }
                    return outputs.isEmpty ? nil : outputs
                }
                let hold = openTrafficStopHold(at: sample.timestamp, base: state.lastMovingAt ?? evidence.inferredEndAt)
                return hold + [.tripUpdated(sampleCount: state.samples.count)]
            }

            recordPostVehicleMotion(sample.timestamp, classification: classification)
            if classification.isPedestrianMotion,
               isConfirmedPedestrianExit(sample: sample, at: sample.timestamp) {
                let endDate = max(state.lastMovingAt ?? evidence.inferredEndAt, state.startedAt ?? evidence.inferredEndAt)
                return completeRecording(endDate: endDate)
            }
            let hold = openTrafficStopHold(at: sample.timestamp, base: state.lastMovingAt ?? evidence.inferredEndAt)
            return hold + [.tripUpdated(sampleCount: state.samples.count)]
        }

        if classification.isVehicle {
            if isObviousVehicleContinuation(sample, classification: classification) {
                let canceled = cancelParkingCandidate(reason: "Vehicle movement continued")
                var outputs: [DriveCaptureOutput] = []
                if let canceled {
                    outputs.append(.parkingCandidateChanged(canceled))
                }
                if state.stopDueAt == nil {
                    outputs.append(.stopDeadlineChanged(nil))
                }
                return outputs.isEmpty ? nil : outputs
            }

            if evidence.signal == .vehicleConnectionDisconnected {
                return [.tripUpdated(sampleCount: state.samples.count)]
            }
            return nil
        }

        recordPostVehicleMotion(sample.timestamp, classification: classification)

        if evidence.signal == .vehicleConnectionDisconnected,
           evidence.confidence == .assist,
           classification.isStationary || classification.isPedestrianMotion {
            updateParkingAnchorCoordinateIfUseful(with: sample, evidence: evidence)
            return completeRecording(endDate: evidence.inferredEndAt)
        }

        if evidence.confidence == .hard {
            updateParkingAnchorCoordinateIfUseful(with: sample, evidence: evidence)
            if let stopDueAt = state.stopDueAt,
               sample.timestamp >= stopDueAt {
                return completeRecording(endDate: evidence.inferredEndAt)
            }
            return [.tripUpdated(sampleCount: state.samples.count)]
        }

        return nil
    }

    private mutating func completeForParkingMotionIfNeeded(
        sample: LocationSample?,
        at explicitDate: Date? = nil,
        classification: SampleClassification
    ) -> [DriveCaptureOutput]? {
        guard let date = explicitDate ?? sample?.timestamp else {
            return nil
        }
        guard classification.isPedestrianMotion,
              let lastMovingAt = state.lastMovingAt,
              date.timeIntervalSince(lastMovingAt) <= startPolicy.parkingEnd.motionParkingTransitionWindow else {
            return nil
        }

        if isTrafficStopProtected(at: date),
           !isConfirmedPedestrianExit(sample: sample, at: date) {
            return openTrafficStopHold(at: date, base: lastMovingAt)
        }

        let evidence = beginParkingCandidate(
            signal: .motionParkingTransition,
            source: nil,
            confidence: .fallback,
            signalAt: date,
            inferredEndAt: max(lastMovingAt, state.startedAt ?? lastMovingAt)
        )
        return [.parkingCandidateChanged(evidence)] + completeRecording(endDate: evidence.inferredEndAt)
    }

    private mutating func recordPostVehicleMotion(
        _ date: Date,
        classification: SampleClassification
    ) {
        guard state.phase == .recording,
              let lastMovingAt = state.lastMovingAt,
              date >= lastMovingAt else {
            return
        }
        if classification.isStationary, state.firstPostVehicleStationaryAt == nil {
            state.firstPostVehicleStationaryAt = date
        }
        if classification.isPedestrianMotion, state.firstPedestrianAt == nil {
            state.firstPedestrianAt = date
        }
    }

    private func isTrafficStopProtected(at date: Date) -> Bool {
        isTrafficStopHoldActive(at: date) || recentTrafficStopRoadSpeedSample(at: date) != nil
    }

    private func isTrafficStopHoldActive(at date: Date) -> Bool {
        guard state.parkingEvidence?.signal == .trafficStopHold,
              let stopDueAt = state.stopDueAt else {
            return false
        }
        return date <= stopDueAt
    }

    private func recentTrafficStopRoadSpeedSample(at date: Date) -> LocationSample? {
        let windowStart = date.addingTimeInterval(-startPolicy.parkingEnd.trafficStopProtectionWindow)
        return state.samples.reversed().first { sample in
            guard sample.timestamp >= windowStart,
                  sample.timestamp <= date,
                  sample.horizontalAccuracy >= 0,
                  sample.horizontalAccuracy <= state.configuration.maxHorizontalAccuracyMeters,
                  hasAutomotiveHint(sample),
                  let speed = effectiveSpeed(for: sample) else {
                return false
            }
            return speed.value >= startPolicy.parkingEnd.trafficStopMinimumSpeedMetersPerSecond
        }
    }

    private mutating func openTrafficStopHold(at date: Date, base: Date) -> [DriveCaptureOutput] {
        let deadline = trafficStopHoldDeadline(base: base)
        var outputs: [DriveCaptureOutput] = []
        let previousEvidence = state.parkingEvidence
        if previousEvidence?.signal != .trafficStopHold {
            let evidence = beginParkingCandidate(
                signal: .trafficStopHold,
                source: previousEvidence?.source,
                confidence: .fallback,
                signalAt: previousEvidence?.signalAt ?? date,
                inferredEndAt: deadline
            )
            updateTrafficStopAnchor(base: base)
            outputs.append(.parkingCandidateChanged(state.parkingEvidence ?? evidence))
        } else {
            state.parkingEvidence?.inferredEndAt = deadline
            updateTrafficStopAnchor(base: base)
        }

        if state.stopDueAt != deadline {
            state.stopDueAt = deadline
            outputs.append(.stopDeadlineChanged(deadline))
        }
        return outputs
    }

    private func trafficStopHoldDeadline(base: Date) -> Date {
        base.addingTimeInterval(startPolicy.parkingEnd.trafficStopHold)
    }

    private mutating func updateTrafficStopAnchor(base: Date) {
        guard let anchor = parkingAnchorSample(before: base) else { return }
        state.parkingAnchorSample = anchor
        state.parkingEvidence?.anchorSample = anchor
    }

    private func isConfirmedPedestrianExit(sample: LocationSample?, at date: Date) -> Bool {
        guard let sample,
              let firstPedestrianAt = state.firstPedestrianAt,
              date.timeIntervalSince(firstPedestrianAt) >= startPolicy.parkingEnd.pedestrianExitMinimumDuration,
              let anchor = state.parkingAnchorSample
                ?? state.parkingEvidence?.anchorSample
                ?? state.lastMovingAt.flatMap({ parkingAnchorSample(before: $0) }) else {
            return false
        }
        let distance = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: anchor.latitude, longitude: anchor.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        return distance.isFinite && distance >= startPolicy.parkingEnd.pedestrianExitMinimumDistanceMeters
    }

    private func isTrafficStopVehicleContinuation(
        _ sample: LocationSample,
        classification: SampleClassification
    ) -> Bool {
        if let speed = effectiveSpeed(for: sample) {
            return speed.value >= startPolicy.parkingEnd.continuationSpeedMetersPerSecond
        }
        return classification.vehicleEvidence == .automotiveMotion
    }

    @discardableResult
    private mutating func beginParkingCandidate(
        signal: ParkingSignal,
        source: VehicleConnectionSource?,
        confidence: ParkingConfidence,
        signalAt: Date,
        inferredEndAt: Date
    ) -> ParkingEvidence {
        let anchor = parkingAnchorSample(before: inferredEndAt)
        let evidence = ParkingEvidence(
            signal: signal,
            source: source,
            confidence: confidence,
            signalAt: signalAt,
            inferredEndAt: inferredEndAt,
            anchorSample: anchor
        )
        state.parkingCandidateStartedAt = signalAt
        state.parkingAnchorSample = anchor
        state.parkingEvidence = evidence
        return evidence
    }

    private mutating func cancelParkingCandidate(reason: String) -> ParkingEvidence? {
        guard var evidence = state.parkingEvidence else { return nil }
        evidence.cancelReason = reason
        resetParkingCandidate()
        state.stopDueAt = nil
        return evidence
    }

    private mutating func resetParkingCandidate() {
        state.parkingCandidateStartedAt = nil
        state.parkingAnchorSample = nil
        state.firstPostVehicleStationaryAt = nil
        state.firstPedestrianAt = nil
        state.parkingEvidence = nil
    }

    private func completionEndDate(forStopDueAt stopDueAt: Date) -> Date {
        state.parkingEvidence?.inferredEndAt ?? stopDueAt
    }

    private func parkingAnchorSample(before date: Date) -> LocationSample? {
        let usableSamples = state.samples
            .filter {
                $0.timestamp <= date
                    && $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= state.configuration.maxHorizontalAccuracyMeters
            }
            .sorted { $0.timestamp < $1.timestamp }
        return usableSamples.last
    }

    private func finalParkingAnchor(for endDate: Date) -> LocationSample? {
        if let anchor = state.parkingAnchorSample ?? state.parkingEvidence?.anchorSample {
            return anchor.retimestamped(to: endDate)
        }
        return parkingAnchorSample(before: endDate)?.retimestamped(to: endDate)
    }

    private func shouldSuppressPostParkingSpeedOnlyStart(
        _ sample: LocationSample,
        classification: SampleClassification,
        context: TripDetectionContext
    ) -> Bool {
        guard isPostParkingSpeedOnlyEvidence(classification.vehicleEvidence),
              !hasAutomotiveHint(sample),
              !hasBluetoothAssistHint(context),
              !hasPowerAssistHint(context),
              let anchor = state.vehicleParkingAnchor ?? state.parkedStartAnchor else {
            return false
        }
        let age = sample.timestamp.timeIntervalSince(anchor.timestamp)
        guard age >= 0, age <= startPolicy.locationConfirmation.postParkingSpeedOnlySuppressionWindow else {
            return false
        }
        let distance = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: anchor.latitude, longitude: anchor.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        return distance.isFinite && distance <= startPolicy.locationConfirmation.postParkingSpeedOnlySuppressionDistanceMeters
    }

    private func isPostParkingSpeedOnlyEvidence(_ evidence: VehicleEvidence?) -> Bool {
        switch evidence {
        case .reportedSpeed?, .derivedSpeed?:
            true
        case .automotiveMotion?, .assistedSpeed?, nil:
            false
        }
    }

    private mutating func updateParkingAnchorCoordinateIfUseful(
        with sample: LocationSample,
        evidence: ParkingEvidence
    ) {
        guard sample.timestamp >= evidence.inferredEndAt,
              sample.timestamp.timeIntervalSince(evidence.inferredEndAt) <= startPolicy.parkingEnd.postDisconnectCoordinateGrace,
              sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= state.configuration.maxHorizontalAccuracyMeters,
              hasStationaryHint(sample) || effectiveSpeed(for: sample)?.value ?? 0 <= state.configuration.stationarySpeedMetersPerSecond else {
            return
        }
        let retimestamped = sample.retimestamped(to: evidence.inferredEndAt)
        state.parkingAnchorSample = retimestamped
        state.parkingEvidence?.anchorSample = retimestamped
    }

    private func isObviousVehicleContinuation(
        _ sample: LocationSample,
        classification: SampleClassification
    ) -> Bool {
        guard classification.isVehicle else { return false }
        if hasAutomotiveHint(sample) {
            return true
        }
        guard let anchor = state.parkingAnchorSample ?? state.parkingEvidence?.anchorSample,
              let speed = effectiveSpeed(for: sample),
              speed.value >= startPolicy.parkingEnd.continuationSpeedMetersPerSecond else {
            return false
        }
        let distance = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: anchor.latitude, longitude: anchor.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        return distance.isFinite && distance >= startPolicy.parkingEnd.continuationDistanceMeters
    }

    private mutating func stopTracking(at date: Date) -> [DriveCaptureOutput] {
        state.vehicleAutomationStartSignal = nil
        var outputs: [DriveCaptureOutput] = []
        if state.phase == .recording, !state.samples.isEmpty {
            let endDate = max(date, state.startedAt ?? date)
            outputs.append(contentsOf: completeRecording(endDate: endDate))
        }
        state.phase = .idle
        state.pausedUntil = nil
        resetCandidate()
        state.recentCandidate = nil
        state.parkedStartAnchor = nil
        state.vehicleParkingAnchor = nil
        state.stopDueAt = nil
        state.firstStationaryAt = nil
        resetParkingCandidate()
        return outputs + [.checkpointChanged(state)]
    }

    private mutating func completeRecording(endDate: Date) -> [DriveCaptureOutput] {
        guard let startedAt = state.startedAt else {
            state.phase = .idle
            return [.checkpointChanged(state)]
        }
        let draft = completedTripDraft(startedAt: startedAt, endDate: endDate)
        let finalParkedAnchor = finalParkingAnchor(for: endDate)
        // A recording that confirmed on connection/assist evidence but never gathered
        // a usable route is not a drive — persisting it produces a 0.0 mi stub trip
        // in the user's list (2026-06-18 17 Pro return-drive start: 1 sample, 0.0 mi).
        // Reset state either way; only emit a completion when there is a real route.
        let keepsTrip = !isEmptyCompletion(draft)
            || !state.pendingFees.isEmpty
            || state.pendingClassification != nil
            || state.pendingBusinessPurpose != nil
            || state.pendingNote != nil
        state.pendingCompletionDraft = keepsTrip ? draft : nil
        state.phase = .idle
        state.startedAt = nil
        state.samples = []
        state.lastMovingAt = nil
        state.firstStationaryAt = nil
        state.stopDueAt = nil
        state.attentionReasons = []
        state.parkedStartAnchor = finalParkedAnchor
        state.vehicleParkingAnchor = keepsTrip ? finalParkedAnchor : nil
        resetParkingCandidate()
        resetCandidate()
        state.recentCandidate = nil
        // The draft (kept via pendingCompletionDraft) already carries the vehicle;
        // clear the in-flight hint so the next capture starts clean.
        state.startVehicleHint = nil
        state.startVehicleIsManual = false
        state.startVehicleAssignmentSource = nil
        state.conflictingVehicleIDs = []
        pruneCyclingMotionDates(anchor: endDate)
        guard keepsTrip else {
            return [.ignored(IgnoreReason.emptyCompletion.message), .stopDeadlineChanged(nil)]
        }
        return [.tripCompleted(draft), .stopDeadlineChanged(nil)]
    }

    /// A completed automatic draft with no measurable route — fewer than two samples
    /// or zero route distance — cannot be a real drive (a genuine short trip keeps its
    /// distance via `rescuedShortTrip`, which has its own distance floor).
    private func isEmptyCompletion(_ draft: TripDraft) -> Bool {
        draft.samples.count < 2 || draft.distanceMeters <= 0
    }

    private func completedTripDraft(startedAt: Date, endDate: Date) -> TripDraft {
        var usableSamples = state.samples
            .filter { $0.timestamp <= endDate }
            .sorted { $0.timestamp < $1.timestamp }
        if let anchor = state.parkingAnchorSample ?? state.parkingEvidence?.anchorSample,
           anchor.timestamp <= endDate,
           !usableSamples.contains(anchor) {
            usableSamples.append(anchor)
            usableSamples.sort { $0.timestamp < $1.timestamp }
        }
        let distance = DistanceCalculator.routeDistanceMeters(
            samples: usableSamples,
            maxAccuracy: state.configuration.maxHorizontalAccuracyMeters,
            maxSegmentSpeedMetersPerSecond: state.configuration.maxSegmentSpeedMetersPerSecond
        )
        var reasons = state.attentionReasons
        reasons.append(contentsOf: attentionReasons(for: usableSamples, distanceMeters: distance))
        return TripDraft(
            id: state.pendingTripID ?? UUID(),
            startDate: startedAt,
            endDate: max(endDate, startedAt),
            samples: usableSamples,
            distanceMeters: distance,
            attentionReasons: reasons.uniqued(),
            classification: state.pendingClassification,
            businessPurpose: state.pendingClassification == .business ? state.pendingBusinessPurpose : nil,
            fees: state.pendingFees,
            notes: state.pendingNote,
            vehicleID: state.startVehicleHint,
            vehicleAssignmentSource: vehicleHintSource,
            conflictingVehicleIDs: state.conflictingVehicleIDs,
            cyclingMotionDates: cyclingMotionDates(from: startedAt, to: endDate),
            vehicleConnectionObserved: vehicleConnectionObserved(from: startedAt, to: endDate)
        )
    }

    /// The remembered cycling snapshots that fall inside the classifier's
    /// window around a capture: its lead-in before `start`, the capture
    /// itself, and the tail after `end`.
    private func cyclingMotionDates(from start: Date, to end: Date) -> [Date] {
        let windowStart = start.addingTimeInterval(-CyclingTripClassifier.leadInSeconds)
        let windowEnd = end.addingTimeInterval(CyclingTripClassifier.tailSeconds)
        return state.recentCyclingMotionDates
            .filter { $0 >= windowStart && $0 <= windowEnd }
            .sorted()
    }

    /// Whether a trusted vehicle connection was live at any point from
    /// `CyclingTripClassifier.vehicleConnectionLeadSeconds` before `start`
    /// through `end`. A disconnection inside that window counts as well: the
    /// link was live entering it. Errs toward "a car was here", which keeps
    /// the trip.
    private func vehicleConnectionObserved(from start: Date, to end: Date) -> Bool {
        let windowStart = start.addingTimeInterval(-CyclingTripClassifier.vehicleConnectionLeadSeconds)
        if state.vehicleAudioConnectionActive {
            return true
        }
        if let activeAt = state.lastVehicleConnectionActiveAt,
           activeAt >= windowStart,
           activeAt <= end {
            return true
        }
        if let automationAt = state.lastVehicleAutomationSignalAt,
           automationAt >= windowStart,
           automationAt <= end {
            return true
        }
        return false
    }

    /// Remembers a high-confidence cycling snapshot for the completion
    /// classifiers. Retention is anchored on the capture start while
    /// recording, so a long drive cannot age out the evidence that preceded
    /// it; while idle it is anchored on the newest snapshot.
    private mutating func recordCyclingMotion(at date: Date) {
        state.recentCyclingMotionDates.append(date)
        pruneCyclingMotionDates(anchor: state.startedAt ?? date)
    }

    private mutating func pruneCyclingMotionDates(anchor: Date) {
        let floor = anchor.addingTimeInterval(
            -CyclingTripClassifier.leadInSeconds - Self.cyclingMotionRetentionSlackSeconds
        )
        var dates = state.recentCyclingMotionDates.filter { $0 >= floor }.sorted()
        if dates.count > Self.maximumRetainedCyclingMotionDates {
            dates.removeFirst(dates.count - Self.maximumRetainedCyclingMotionDates)
        }
        state.recentCyclingMotionDates = dates
    }

    private static let cyclingMotionRetentionSlackSeconds: TimeInterval = 60
    /// CoreMotion reports a few snapshots a minute at most; this bounds the
    /// checkpoint even if it chattered for the whole lead-in.
    private static let maximumRetainedCyclingMotionDates = 256

    /// Attribution source for a draft carrying `startVehicleHint`: a live-bar
    /// pick is `.manual` (protected from re-attribution), a Shortcut's vehicle
    /// is `.shortcut`.
    private var vehicleHintSource: VehicleAssignmentSource? {
        guard state.startVehicleHint != nil else { return nil }
        return state.startVehicleAssignmentSource
            ?? (state.startVehicleIsManual ? .manual : .shortcut)
    }

    private mutating func clearPendingReviewFields() {
        state.pendingFees = []
        state.pendingClassification = nil
        state.pendingBusinessPurpose = nil
        state.pendingNote = nil
    }

    private mutating func updateParkedStartAnchorIfNeeded(_ sample: LocationSample) {
        guard sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= startPolicy.parkedStartInference.maximumAnchorAccuracyMeters,
              hasStationaryHint(sample) || effectiveSpeed(for: sample)?.value ?? 0 <= state.configuration.stationarySpeedMetersPerSecond else {
            return
        }
        state.parkedStartAnchor = sample
    }

    /// Records a parking anchor only after a capture path has already proven this
    /// to be a completed vehicle trip. Generic idle locations deliberately do not
    /// call this helper.
    private mutating func updateVehicleParkingAnchorIfEligible(_ sample: LocationSample) {
        guard sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= startPolicy.parkedStartInference.maximumAnchorAccuracyMeters,
              hasStationaryHint(sample) || effectiveSpeed(for: sample)?.value ?? 0 <= state.configuration.stationarySpeedMetersPerSecond else {
            return
        }
        state.vehicleParkingAnchor = sample
    }

    private func classify(
        _ sample: LocationSample,
        context: TripDetectionContext,
        allowsPedestrianSpeedOverride: Bool = false
    ) -> SampleClassification {
        let speed = effectiveSpeed(for: sample)
        let allowsTrustedSpeedOverride = allowsPedestrianSpeedOverride && hasTrustedVehicleEvidence(context: context)
        if hasAutomotiveHint(sample) {
            return .vehicle(.automotiveMotion)
        }
        if hasPedestrianHint(sample) {
            if allowsTrustedSpeedOverride,
               let speed,
               speed.value >= startPolicy.locationConfirmation.motionContradictionSpeedMetersPerSecond {
                return .vehicle(speedEvidence(for: speed))
            }
            return .nonVehicle(.pedestrianMotion)
        }
        if hasStationaryHint(sample) {
            if allowsTrustedSpeedOverride,
               let speed,
               speed.value >= startPolicy.locationConfirmation.motionContradictionSpeedMetersPerSecond {
                return .vehicle(speedEvidence(for: speed))
            }
            return .nonVehicle(.stationaryMotion)
        }

        guard let speed, speed.value >= 0 else {
            return .unknown
        }

        if speed.value >= state.configuration.minimumStartSpeedMetersPerSecond {
            return .vehicle(speedEvidence(for: speed))
        }
        if let assist = vehicleAssistEvidence(context: context),
           speed.value >= assist.speedThreshold {
            return .vehicle(.assistedSpeed)
        }
        if speed.value <= state.configuration.stationarySpeedMetersPerSecond {
            return .nonVehicle(.stationaryMotion)
        }
        if speed.value <= pedestrianExitSpeedMetersPerSecond {
            return .nonVehicle(.lowSpeedMovement)
        }
        return .unknown
    }

    private func speedEvidence(for speed: MeasuredSpeed) -> VehicleEvidence {
        switch speed.source {
        case .reported: .reportedSpeed
        case .derived: .derivedSpeed
        }
    }

    private func hasBluetoothAssistHint(_ context: TripDetectionContext) -> Bool {
        context.trustedBluetoothVehicleHint
    }

    private func hasPowerAssistHint(_ context: TripDetectionContext) -> Bool {
        context.powerConnected || context.recentPowerConnected
    }

    private mutating func applyStartSignalContributions(_ signal: DriveStartSignal) {
        state.candidateHadBluetoothHint = state.candidateHadBluetoothHint || (signal.bluetoothContributed && signal.confidence != .weak)
        state.candidateHadPowerHint = state.candidateHadPowerHint || signal.powerContributed
        recordVehicleAutomationEvidence(signal)
    }

    /// Called only after the signal passes mode, expiry, pause and duplicate
    /// admission checks. Never turns a declared trigger into a live connection.
    private mutating func recordVehicleAutomationEvidence(_ signal: DriveStartSignal) {
        guard signal.isVehicleAutomation else { return }
        state.lastVehicleAutomationSignalAt = max(state.lastVehicleAutomationSignalAt ?? signal.startedAt, signal.startedAt)
    }

    private func signalDetectionContext() -> TripDetectionContext {
        TripDetectionContext(
            trustedBluetoothVehicleHint: state.candidateHadBluetoothHint,
            powerConnected: state.candidateHadPowerHint,
            recentPowerConnected: state.candidateHadPowerHint,
            recentPowerDisconnected: false
        )
    }

    private mutating func recordCandidateAssistHints(_ context: TripDetectionContext) {
        state.candidateHadBluetoothHint = state.candidateHadBluetoothHint || hasBluetoothAssistHint(context)
        state.candidateHadPowerHint = state.candidateHadPowerHint || hasPowerAssistHint(context)
    }

    private func hasTrustedVehicleEvidence(context: TripDetectionContext) -> Bool {
        state.candidateHadBluetoothHint
            || hasBluetoothAssistHint(context)
            || state.startSignal?.source == .trustedBluetooth
            || state.startSignal?.source == .externalVehicleAutomation
            || (state.startSignal?.bluetoothContributed == true && state.startSignal?.confidence != .weak)
    }

    /// Whether the current candidate should be immune to parked-stationary
    /// contradiction kills right now: it hasn't seen real movement yet, it was
    /// armed by a vehicle trigger (trusted/external Bluetooth, or charger/power),
    /// and it is still within the pre-movement grace window measured from
    /// `candidateStartedAt`.
    ///
    /// Deliberately distinct from `hasTrustedVehicleEvidence` and never fed into
    /// `candidateConfirmationEvidence`, `vehicleAssistEvidence`, or
    /// `DriveCandidateConfirmationPolicy.disposition` — granting a
    /// charger-triggered candidate patience must not also grant it instant
    /// fast-path confirmation. `testPowerOnlyMovementDoesNotConfirmVisibleTrip`
    /// guards that power alone must never confirm a visible trip; this helper
    /// only ever suppresses a contradiction-kill, it never confirms anything.
    /// Whether the device is demonstrably at (or in) a running vehicle right
    /// now: the trusted Bluetooth vehicle hint is live, or the candidate's
    /// merged start signal carries an unexpired strong Bluetooth contribution
    /// (trusted route / per-car Shortcut automation). Deliberately stricter
    /// than `isVehicleTriggerArmedCandidate` — power history alone must not
    /// neutralize a pedestrian contradiction, because a phone can stay on a
    /// charger while its owner walks away; a live vehicle Bluetooth link
    /// cannot follow them.
    private func hasActiveVehicleConnection(context: TripDetectionContext, at date: Date) -> Bool {
        if hasBluetoothAssistHint(context) { return true }
        guard let signal = state.startSignal else { return false }
        return signal.confidence == .strong
            && signal.bluetoothContributed
            && date <= signal.expiresAt
    }

    private func isVehicleTriggerArmedCandidate(at date: Date, context: TripDetectionContext) -> Bool {
        guard state.candidateFirstMovementAt == nil else { return false }
        let isVehicleTriggered = hasTrustedVehicleEvidence(context: context)
            || state.candidateHadPowerHint
            || state.startSignal?.source == .externalChargerAutomation
        guard isVehicleTriggered else { return false }
        let sinceStart = date.timeIntervalSince(state.candidateStartedAt ?? date)
        return sinceStart >= 0 && sinceStart <= startPolicy.candidateResilience.preMovementGraceSeconds
    }

    /// Whether a vehicle classification reflects genuine measured movement, as
    /// opposed to an ambiguous CoreMotion automotive label. Speed-based evidence
    /// (`.reportedSpeed`/`.derivedSpeed`/`.assistedSpeed`) is always genuine -
    /// `classify()` only returns those when a real measured speed already
    /// cleared a movement threshold. A bare `.automotiveMotion` hint is genuine
    /// too, *unless* the same sample also carries a `.stationary` hint:
    /// CoreMotion can report automotive+stationary simultaneously on an idling
    /// parked car (engine vibration reads as automotive before the device has
    /// displaced), and that ambiguous co-occurrence must not be trusted to mark
    /// first movement - `candidateFirstMovementAt` anchors the assisted-start
    /// elapsed clock, and anchoring it too early would let a later real drive
    /// confirm instantly instead of after a sustained window of actual movement.
    private func isGenuineMovementEvidence(_ classification: SampleClassification, sample: LocationSample) -> Bool {
        guard classification.isVehicle else { return false }
        if classification.vehicleEvidence == .automotiveMotion, hasStationaryHint(sample) {
            return false
        }
        return true
    }

    private func candidateConfirmationEvidence(
        metrics: CandidateMetrics,
        context: TripDetectionContext,
        at date: Date
    ) -> DriveCandidateEvidence {
        // Tolerated contradictions never enter candidateSamples, so a fresh
        // contradiction hold ORs into the hint flags — strictly stronger
        // pedestrian/cycling blocking than the sample scan alone.
        DriveCandidateEvidence(
            elapsed: metrics.elapsed,
            sampleCount: metrics.sampleCount,
            distanceMeters: metrics.distanceMeters,
            hasMovementEvidence: metrics.hasMovementEvidence,
            hasReportedSpeedEvidence: metrics.hasReportedSpeedEvidence,
            hasDerivedSpeedEvidence: metrics.hasDerivedSpeedEvidence,
            hasMeaningfulDisplacement: metrics.hasMeaningfulDisplacement,
            hasAutomotiveHint: state.candidateSamples.contains(where: hasAutomotiveHint),
            hasCyclingHint: state.candidateSamples.contains { hasHint(.cycling, in: $0) },
            hasPedestrianHint: state.candidateSamples.contains(where: hasPedestrianHint)
                || hasFreshContradiction(.pedestrian, at: date),
            hasStationaryHint: state.candidateSamples.contains(where: hasStationaryHint)
                || hasFreshContradiction(.stationary, at: date),
            hasTrustedVehicleEvidence: hasTrustedVehicleEvidence(context: context)
        )
    }

    private func startSpeedThreshold(context: TripDetectionContext) -> Double {
        vehicleAssistEvidence(
            context: context,
            includeCandidateBluetoothHistory: state.candidateHadBluetoothHint,
            includeCandidatePowerHistory: state.candidateHadPowerHint
        )?.speedThreshold
            ?? state.configuration.minimumStartSpeedMetersPerSecond
    }

    private func vehicleAssistEvidence(
        context: TripDetectionContext,
        includeCandidateBluetoothHistory: Bool = false,
        includeCandidatePowerHistory: Bool = false
    ) -> VehicleAssistEvidence? {
        var thresholds: [Double] = []
        var durations: [TimeInterval] = []
        if hasBluetoothAssistHint(context) || includeCandidateBluetoothHistory {
            thresholds.append(state.configuration.bluetoothAssistedStartSpeedMetersPerSecond)
            durations.append(state.configuration.bluetoothAssistedStartDuration)
        }
        if hasPowerAssistHint(context) || includeCandidatePowerHistory {
            thresholds.append(state.configuration.powerAssistedStartSpeedMetersPerSecond)
            durations.append(state.configuration.powerAssistedStartDuration)
        }
        guard let speedThreshold = thresholds.min(),
              let startDuration = durations.min() else {
            return nil
        }
        return VehicleAssistEvidence(
            speedThreshold: min(state.configuration.minimumStartSpeedMetersPerSecond, speedThreshold),
            startDuration: min(state.configuration.minimumStartDuration, startDuration)
        )
    }

    private var pedestrianExitSpeedMetersPerSecond: Double {
        max(state.configuration.stationarySpeedMetersPerSecond, 2.2)
    }

    private func hasAutomotiveHint(_ sample: LocationSample) -> Bool {
        hasHint(.automotive, in: sample)
    }

    private func hasStationaryHint(_ sample: LocationSample) -> Bool {
        hasHint(.stationary, in: sample)
    }

    private func hasPedestrianHint(_ sample: LocationSample) -> Bool {
        hasHint(.walking, in: sample) || hasHint(.running, in: sample) || hasHint(.cycling, in: sample)
    }

    private func hasHint(_ hint: MotionHint, in sample: LocationSample) -> Bool {
        if sample.motionHint == hint {
            return true
        }
        return sample.motionActivity?.contains(hint) == true
    }

    private func effectiveSpeed(for sample: LocationSample) -> MeasuredSpeed? {
        if let speed = sample.speedMetersPerSecond, speed >= 0 {
            return MeasuredSpeed(value: speed, source: .reported)
        }
        guard let previous = state.lastAcceptedSample else {
            return nil
        }
        return segmentSpeed(from: previous, to: sample)
            .map { MeasuredSpeed(value: $0, source: .derived) }
    }

    private mutating func shouldIgnoreAsImpossibleJump(_ sample: LocationSample) -> Bool {
        guard let previous = state.lastAcceptedSample,
              isImpossibleJump(from: previous, to: sample) else {
            state.pendingImpossibleSample = nil
            return false
        }

        if let pendingImpossibleSample = state.pendingImpossibleSample,
           isPlausibleRelocation(from: pendingImpossibleSample, to: sample) {
            state.lastAcceptedSample = pendingImpossibleSample
            state.pendingImpossibleSample = nil
            return false
        }

        state.pendingImpossibleSample = sample
        return true
    }

    private mutating func recordImpossibleJumpAttention(rejectedAt: Date) {
        if state.phase == .recording {
            state.attentionReasons.appendUnique(IgnoreReason.impossibleGPSJump.message)
        } else {
            stashRecentCandidate(rejectedAt: rejectedAt)
            resetCandidate()
            state.phase = .idle
        }
    }

    private func isImpossibleJump(from previous: LocationSample, to sample: LocationSample) -> Bool {
        let elapsed = sample.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return false }
        let displacement = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: previous.latitude, longitude: previous.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        guard displacement.isFinite,
              displacement / elapsed > state.configuration.maxSegmentSpeedMetersPerSecond else {
            return false
        }
        // An impossible *implied speed* is only a real teleport when the displacement
        // itself exceeds the two fixes' combined horizontal accuracy. Duplicate or
        // near-simultaneous deliveries (Δt ≈ ms) turn sub-meter GPS jitter at a
        // standstill into thousands of m/s; that is sensor noise, not motion, and
        // must not flag the trip (2026-06-18: a 0.14 m / 1 ms parked jitter pair sent
        // an otherwise-clean drive to needsAttention as "Impossible GPS jump").
        let accuracyFloor = max(previous.horizontalAccuracy, 0) + max(sample.horizontalAccuracy, 0)
        return displacement > accuracyFloor
    }

    private func isPlausibleRelocation(from previous: LocationSample, to sample: LocationSample) -> Bool {
        guard let speed = segmentSpeed(from: previous, to: sample) else { return false }
        return speed <= state.configuration.maxSegmentSpeedMetersPerSecond
    }

    /// Minimum baseline for deriving speed from two fixes. A GPS cold-start
    /// burst delivers several fixes inside one second; dividing centimeters of
    /// jitter by hundredths of a second manufactures vehicle-grade "speed"
    /// from a stationary phone (2026-07-07 17 Pro: two fixes 0 m apart set
    /// `candidateFirstMovementAt`, which disqualified every pre-movement grace
    /// and let a walking burst kill a Shortcut+trusted-Bluetooth candidate one
    /// second after ignition). Consumer GPS cannot resolve speed over less
    /// than a second; real driving at any speed still produces ≥1 s pairs.
    private static let minimumDerivedSpeedBaselineSeconds: TimeInterval = 1

    private func segmentSpeed(from previous: LocationSample, to sample: LocationSample) -> Double? {
        let elapsed = sample.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed >= Self.minimumDerivedSpeedBaselineSeconds else { return nil }
        let distance = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: previous.latitude, longitude: previous.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        guard distance.isFinite else { return nil }
        return distance / elapsed
    }

    private mutating func resetCandidate(keepsPendingTrip: Bool = false) {
        state.candidateStartedAt = nil
        state.candidateSamples = []
        state.startSignal = nil
        state.candidateHadBluetoothHint = false
        state.candidateHadPowerHint = false
        state.candidateContradictionCount = 0
        state.lastCandidateContradiction = nil
        state.candidateFirstMovementAt = nil
        if !keepsPendingTrip, state.phase != .recording, state.pendingCompletionDraft == nil {
            state.pendingTripID = nil
            // The vehicle hint is bound to the abandoned capture; a promotion to
            // recording (keepsPendingTrip) deliberately keeps it.
            state.startVehicleHint = nil
            state.startVehicleIsManual = false
            state.startVehicleAssignmentSource = nil
            state.conflictingVehicleIDs = []
        }
    }

    private mutating func recordCandidateContradiction(_ classification: SampleClassification, at date: Date) {
        state.candidateContradictionCount += 1
        state.lastCandidateContradiction = CandidateContradiction(
            at: date,
            kind: contradictionKind(for: classification)
        )
    }

    private func contradictionKind(for classification: SampleClassification) -> CandidateContradiction.Kind {
        if classification.isPedestrianMotion {
            return .pedestrian
        }
        if classification.isStationary {
            return .stationary
        }
        return .lowSpeed
    }

    /// Preserves the dying candidate's evidence so an immediate restart can
    /// inherit it instead of rediscovering the drive from scratch.
    private mutating func stashRecentCandidate(rejectedAt: Date) {
        guard state.phase == .candidate else { return }
        let rejectedAt = max(rejectedAt, state.candidateStartedAt ?? rejectedAt)
        state.recentCandidate = RecentCandidateSnapshot(
            candidateStartedAt: state.candidateStartedAt,
            samples: state.candidateSamples,
            startSignal: state.startSignal,
            hadBluetoothHint: state.candidateHadBluetoothHint,
            hadPowerHint: state.candidateHadPowerHint,
            contradictionCount: state.candidateContradictionCount,
            lastContradiction: state.lastCandidateContradiction,
            killedAt: rejectedAt,
            firstMovementAt: state.candidateFirstMovementAt,
            vehicleID: state.startVehicleHint,
            vehicleAssignmentSource: state.startVehicleAssignmentSource,
            conflictingVehicleIDs: state.conflictingVehicleIDs
        )
    }

    /// Merges a freshly killed candidate's evidence into the one being armed.
    /// The contradiction hold is inherited deliberately — revival must not
    /// launder a pedestrian/cycling block into a clean fallback confirmation.
    private mutating func inheritRecentCandidateIfFresh(at date: Date) {
        guard let snapshot = state.recentCandidate else { return }
        let sinceKill = date.timeIntervalSince(snapshot.killedAt)
        guard sinceKill >= 0 else { return }
        guard sinceKill <= startPolicy.candidateResilience.reviveWindow else {
            // The candidate evidence (samples, elapsed clock) is stale, but an
            // unexpired strong start signal outlives the revive window on its
            // own terms: the car declared itself on, and that claim is bounded
            // by the signal's expiresAt, not by how quickly the next wake
            // arrived (2026-07-07: the 17 Pro's kill discarded a trusted-
            // Bluetooth signal with 5 minutes of validity left, so the
            // geofence-exit wake three minutes later re-armed as weak).
            if let salvaged = unexpiredStrongSignal(from: snapshot, at: date) {
                state.startSignal = state.startSignal?.merged(with: salvaged) ?? salvaged
                applyStartSignalContributions(salvaged)
                restoreSnapshotVehicleIfUnlatched(snapshot, fallback: salvaged.vehicleID)
            }
            state.recentCandidate = nil
            return
        }
        if let snapshotStart = snapshot.candidateStartedAt {
            state.candidateStartedAt = min(state.candidateStartedAt ?? snapshotStart, snapshotStart)
        }
        if !snapshot.samples.isEmpty {
            state.candidateSamples = (snapshot.samples + state.candidateSamples)
                .sorted { $0.timestamp < $1.timestamp }
        }
        if let snapshotSignal = snapshot.startSignal {
            state.startSignal = state.startSignal?.merged(with: snapshotSignal) ?? snapshotSignal
        }
        restoreSnapshotVehicleIfUnlatched(snapshot, fallback: state.startSignal?.vehicleID)
        state.candidateHadBluetoothHint = state.candidateHadBluetoothHint || snapshot.hadBluetoothHint
        state.candidateHadPowerHint = state.candidateHadPowerHint || snapshot.hadPowerHint
        // Revival is vehicle evidence, so the consecutive count restarts; the
        // hold timestamp does not.
        state.candidateContradictionCount = 0
        state.lastCandidateContradiction = snapshot.lastContradiction ?? state.lastCandidateContradiction
        // A revived candidate that had already moved before being killed must not
        // reopen pre-movement grace or lose its elapsed-clock anchor.
        if let snapshotFirstMovement = snapshot.firstMovementAt {
            state.candidateFirstMovementAt = min(state.candidateFirstMovementAt ?? snapshotFirstMovement, snapshotFirstMovement)
        }
        state.recentCandidate = nil
    }

    private mutating func restoreSnapshotVehicleIfUnlatched(
        _ snapshot: RecentCandidateSnapshot,
        fallback: UUID?
    ) {
        guard state.startVehicleHint == nil else { return }
        state.startVehicleHint = snapshot.vehicleID ?? fallback
        guard state.startVehicleHint != nil else { return }
        state.startVehicleAssignmentSource = snapshot.vehicleAssignmentSource ?? .shortcut
        state.startVehicleIsManual = state.startVehicleAssignmentSource == .manual
        state.conflictingVehicleIDs = Array(Set(snapshot.conflictingVehicleIDs ?? []))
            .filter { $0 != state.startVehicleHint }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func isDuplicateRecentCandidateStart(
        source: DriveStartSignalSource,
        startedAt: Date,
        observedAt: Date,
        coordinate: Coordinate? = nil
    ) -> Bool {
        guard let snapshot = state.recentCandidate,
              let snapshotStartedAt = snapshot.candidateStartedAt,
              let snapshotSignal = snapshot.startSignal,
              snapshotSignal.source == source,
              abs(observedAt.timeIntervalSince(snapshot.killedAt)) <= 1,
              Calendar(identifier: .gregorian).compare(snapshotStartedAt, to: startedAt, toGranularity: .second) == .orderedSame else {
            return false
        }
        guard let coordinate else { return true }
        guard let first = snapshot.samples.first else { return true }
        let distance = DistanceCalculator.distanceMeters(from: first.coordinate, to: coordinate)
        return distance.isFinite && distance <= 10
    }

    private func hasFreshContradiction(_ kind: CandidateContradiction.Kind, at date: Date) -> Bool {
        guard let contradiction = state.lastCandidateContradiction,
              contradiction.kind == kind else {
            return false
        }
        return date.timeIntervalSince(contradiction.at) <= startPolicy.candidateResilience.contradictionHoldSeconds
    }

    /// Passive location-wake sources that the post-kill cooldown gates in
    /// `handleStartSignal` (mirrored by the runtime's pre-apply gate).
    package static let postKillCooldownGatedSources: Set<DriveStartSignalSource> = [
        .parkedAnchorExit, .significantLocationChange, .visitDeparture, .coarseLocationWake
    ]

    /// A candidate that never moved was just killed by a pedestrian/stationary
    /// contradiction: passive location wakes (anchor exit, SLC, visit
    /// departure, coarse wake) alone must not re-arm a fresh probe until the
    /// cooldown lapses. Breaks the 2026-07-05 walk-away loop (kill → level
    /// drops → geofence re-arms → exit re-fires → new candidate → GPS
    /// cold-start, ~20×/min) and backstops the 2026-07-06 stationary-at-home
    /// SLC churn. Candidates that had genuine movement keep the revive path
    /// untouched, and motion/Bluetooth/power/strong sources still arm.
    ///
    /// A dead candidate whose merged signal still carries an unexpired strong
    /// contribution is exempt: "strong signals stay ungated" is the cooldown's
    /// contract, and that must include a strong signal the kill itself
    /// discarded — otherwise a mis-killed ignition candidate (2026-07-07
    /// 17 Pro) silences the very geofence exit that would catch the drive.
    /// The churn loops this cooldown exists for are armed by assist-grade
    /// passive wakes, never by strong sources, so the exemption cannot reopen
    /// them.
    public func isParkedExitRearmSuppressed(at now: Date) -> Bool {
        guard let snapshot = state.recentCandidate,
              snapshot.firstMovementAt == nil,
              let kind = snapshot.lastContradiction?.kind,
              kind == .pedestrian || kind == .stationary else {
            return false
        }
        if unexpiredStrongSignal(from: snapshot, at: now) != nil {
            return false
        }
        let sinceKill = now.timeIntervalSince(snapshot.killedAt)
        return sinceKill >= 0 && sinceKill <= startPolicy.candidateResilience.postKillParkedExitCooldownSeconds
    }

    /// The dying candidate's merged start signal, if it is still within its
    /// own validity window and reached strong confidence (trusted Bluetooth,
    /// per-car automation, confirmed motion). Weak/assist signals are never
    /// salvaged — they are exactly the sources whose churn the post-kill
    /// cooldown suppresses.
    private func unexpiredStrongSignal(from snapshot: RecentCandidateSnapshot, at date: Date) -> DriveStartSignal? {
        guard let signal = snapshot.startSignal,
              signal.confidence == .strong,
              date <= signal.expiresAt else {
            return nil
        }
        return signal
    }

    private enum VehicleParkingStartInferenceResult {
        /// A trustworthy backdated origin to prepend to the trip.
        case inferred(LocationSample)
        /// A fresh, accurate anchor exists but sits implausibly far from the first
        /// trip sample (e.g. a delayed wake) — discard the backdate and flag it.
        case rejectedExcessiveDisplacement
        /// No usable parked anchor to infer from.
        case unavailable
    }

    private func prepareTripStart() -> (startedAt: Date, samples: [LocationSample], attentionReasons: [String]) {
        let sortedSamples = state.candidateSamples.sorted { $0.timestamp < $1.timestamp }
        let defaultStartedAt = state.candidateStartedAt ?? sortedSamples.first?.timestamp ?? Date()
        switch inferredVehicleParkingAnchor(from: state.vehicleParkingAnchor, firstTripSample: sortedSamples.first) {
        case let .inferred(inferredAnchor):
            return (
                inferredAnchor.timestamp,
                ([inferredAnchor] + sortedSamples).sorted { $0.timestamp < $1.timestamp },
                [Self.inferredStartAttentionReason]
            )
        case .rejectedExcessiveDisplacement:
            return (defaultStartedAt, sortedSamples, [Self.excessiveParkedDisplacementAttentionReason])
        case .unavailable:
            return (defaultStartedAt, sortedSamples, [])
        }
    }

    private mutating func applyDeferredVehicleParkingAnchorIfNeeded(firstTripSample: LocationSample) {
        guard state.samples.isEmpty, state.vehicleParkingAnchor != nil else { return }
        switch inferredVehicleParkingAnchor(from: state.vehicleParkingAnchor, firstTripSample: firstTripSample) {
        case let .inferred(inferredAnchor):
            state.startedAt = inferredAnchor.timestamp
            state.samples.append(inferredAnchor)
            state.attentionReasons = (state.attentionReasons + [Self.inferredStartAttentionReason]).uniqued()
        case .rejectedExcessiveDisplacement:
            state.attentionReasons = (state.attentionReasons + [Self.excessiveParkedDisplacementAttentionReason]).uniqued()
        case .unavailable:
            break
        }
        state.vehicleParkingAnchor = nil
    }

    private func inferredVehicleParkingAnchor(
        from vehicleParkingAnchor: LocationSample?,
        firstTripSample: LocationSample?
    ) -> VehicleParkingStartInferenceResult {
        guard let vehicleParkingAnchor,
              let firstTripSample,
              vehicleParkingAnchor.horizontalAccuracy >= 0,
              vehicleParkingAnchor.horizontalAccuracy <= startPolicy.parkedStartInference.maximumAnchorAccuracyMeters else {
            return .unavailable
        }

        let age = firstTripSample.timestamp.timeIntervalSince(vehicleParkingAnchor.timestamp)
        guard age > 0, age <= startPolicy.parkedStartInference.maximumAnchorAge else {
            return .unavailable
        }

        let distance = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: vehicleParkingAnchor.latitude, longitude: vehicleParkingAnchor.longitude),
            to: Coordinate(latitude: firstTripSample.latitude, longitude: firstTripSample.longitude)
        )
        guard distance.isFinite,
              distance >= startPolicy.parkedStartInference.minimumDisplacementMeters,
              distance / age <= state.configuration.maxSegmentSpeedMetersPerSecond else {
            return .unavailable
        }
        // The anchor is fresh and accurate but too distant to trust as the origin:
        // backdating here would place the start far from the resume point.
        guard distance <= startPolicy.parkedStartInference.maximumDisplacementMeters else {
            return .rejectedExcessiveDisplacement
        }

        let inferredSpeed = inferredParkedStartSpeedMetersPerSecond()
        let unclampedLeadTime = max(startPolicy.parkedStartInference.minimumLeadTime, distance / inferredSpeed)
        let inferredLeadTime = min(age, min(startPolicy.parkedStartInference.maximumLeadTime, unclampedLeadTime))
        return .inferred(vehicleParkingAnchor.retimestamped(to: firstTripSample.timestamp.addingTimeInterval(-inferredLeadTime)))
    }

    private func inferredParkedStartSpeedMetersPerSecond() -> Double {
        let speeds = state.candidateSamples
            .sorted { $0.timestamp < $1.timestamp }
            .prefix(5)
            .compactMap(\.speedMetersPerSecond)
            .filter { $0.isFinite && $0 > state.configuration.stationarySpeedMetersPerSecond }
            .sorted()
        guard !speeds.isEmpty else {
            return startPolicy.parkedStartInference.fallbackSpeedMetersPerSecond
        }
        let median = speeds[speeds.count / 2]
        return min(
            startPolicy.parkedStartInference.maximumSpeedMetersPerSecond,
            max(startPolicy.parkedStartInference.minimumSpeedMetersPerSecond, median)
        )
    }

    private mutating func rescuedShortTrip(
        endingWith sample: LocationSample,
        classification: SampleClassification,
        context: TripDetectionContext
    ) -> TripDraft? {
        guard hasTrustedVehicleEvidence(context: context) else { return nil }
        guard classification.isStationary || classification.isExitMovement else { return nil }
        let sortedSamples = state.candidateSamples.sorted { $0.timestamp < $1.timestamp }
        guard let first = sortedSamples.first,
              let last = sortedSamples.last else {
            return nil
        }
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        guard elapsed >= startPolicy.shortTripRescue.minimumDuration,
              elapsed <= startPolicy.shortTripRescue.maximumDuration else {
            return nil
        }
        let distance = DistanceCalculator.routeDistanceMeters(
            samples: sortedSamples,
            maxAccuracy: state.configuration.maxHorizontalAccuracyMeters,
            maxSegmentSpeedMetersPerSecond: state.configuration.maxSegmentSpeedMetersPerSecond
        )
        let hasAssist = state.candidateHadBluetoothHint || state.candidateHadPowerHint || hasBluetoothAssistHint(context) || hasPowerAssistHint(context)
        let minimumDistance = hasAssist
            ? startPolicy.shortTripRescue.minimumStrongAssistDistanceMeters
            : startPolicy.shortTripRescue.minimumDistanceMeters
        guard distance >= minimumDistance else { return nil }
        return TripDraft(
            id: state.pendingTripID ?? UUID(),
            startDate: first.timestamp,
            endDate: max(sample.timestamp, first.timestamp),
            samples: sortedSamples + [sample],
            distanceMeters: distance,
            attentionReasons: [Self.shortTripInferredAttentionReason],
            vehicleID: state.startVehicleHint,
            vehicleAssignmentSource: vehicleHintSource,
            cyclingMotionDates: cyclingMotionDates(from: first.timestamp, to: max(sample.timestamp, first.timestamp)),
            vehicleConnectionObserved: vehicleConnectionObserved(from: first.timestamp, to: max(sample.timestamp, first.timestamp))
        )
    }

    private func silentStopEndDate(before sample: LocationSample, lastSample: LocationSample) -> Date? {
        let gap = sample.timestamp.timeIntervalSince(lastSample.timestamp)
        guard gap >= max(startPolicy.locationConfirmation.minimumSilentStopGap, state.configuration.stopTimeout * 3) else { return nil }
        let displacement = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: lastSample.latitude, longitude: lastSample.longitude),
            to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
        )
        guard displacement / gap <= state.configuration.stationarySpeedMetersPerSecond else { return nil }
        return lastSample.timestamp
    }

    private func candidateMetrics(context: TripDetectionContext) -> CandidateMetrics {
        let samples = state.candidateSamples.sorted { $0.timestamp < $1.timestamp }
        let first = samples.first
        let last = samples.last
        let elapsed = last?.timestamp.timeIntervalSince(first?.timestamp ?? last?.timestamp ?? Date()) ?? 0
        let distance = DistanceCalculator.routeDistanceMeters(
            samples: samples,
            maxAccuracy: state.configuration.maxHorizontalAccuracyMeters,
            maxSegmentSpeedMetersPerSecond: state.configuration.maxSegmentSpeedMetersPerSecond
        )
        let threshold = startSpeedThreshold(context: context)
        let speeds = samples.enumerated().compactMap { index, sample in
            effectiveSpeed(forCandidate: sample, previous: index > 0 ? samples[index - 1] : nil)
        }
        let hasReportedSpeedEvidence = samples.contains { ($0.speedMetersPerSecond ?? -1) >= threshold }
        let hasNormalReportedSpeedEvidence = samples.contains { ($0.speedMetersPerSecond ?? -1) >= state.configuration.minimumStartSpeedMetersPerSecond }
        let hasDerivedSpeedEvidence = speeds.contains { $0.value >= threshold && $0.source == .derived }
        let hasMeaningfulDisplacement = distance >= startPolicy.locationConfirmation.minimumCandidateDisplacementMeters
        let hasAutomotiveEvidence = samples.contains(where: hasAutomotiveHint)
        let hasMovementEvidence = hasAutomotiveEvidence
            || hasNormalReportedSpeedEvidence
            || (hasReportedSpeedEvidence && hasMeaningfulDisplacement)
            || (hasDerivedSpeedEvidence && hasMeaningfulDisplacement)
        return CandidateMetrics(
            elapsed: elapsed,
            sampleCount: samples.count,
            distanceMeters: distance,
            hasMovementEvidence: hasMovementEvidence,
            hasReportedSpeedEvidence: hasReportedSpeedEvidence,
            hasDerivedSpeedEvidence: hasDerivedSpeedEvidence,
            hasMeaningfulDisplacement: hasMeaningfulDisplacement,
            hasAutomotiveEvidence: hasAutomotiveEvidence
        )
    }

    private func effectiveSpeed(forCandidate sample: LocationSample, previous: LocationSample?) -> MeasuredSpeed? {
        if let speed = sample.speedMetersPerSecond, speed >= 0 {
            return MeasuredSpeed(value: speed, source: .reported)
        }
        guard let previous else {
            return nil
        }
        return segmentSpeed(from: previous, to: sample)
            .map { MeasuredSpeed(value: $0, source: .derived) }
    }

    private func candidateDiagnosticReason(prefix: String, context: TripDetectionContext, at now: Date) -> String {
        candidateDiagnosticReason(prefix: prefix, metrics: candidateMetrics(context: context), at: now)
    }

    private func candidateDiagnosticReason(prefix: String, metrics: CandidateMetrics, at now: Date) -> String {
        // `elapsed` is the candidate-sample span (a confirmation-policy input);
        // `age` is wall-clock since arming — a sampleless candidate that lived
        // 5 minutes reports elapsed=0s but age=300s (2026-07-05 incident read
        // "elapsed=0s" as instant death).
        let age = state.candidateStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? metrics.elapsed
        return "\(prefix): samples=\(metrics.sampleCount), elapsed=\(Int(metrics.elapsed))s, age=\(Int(age))s, distance=\(Int(metrics.distanceMeters))m, automotive=\(metrics.hasAutomotiveEvidence), reportedSpeed=\(metrics.hasReportedSpeedEvidence), derivedSpeed=\(metrics.hasDerivedSpeedEvidence), displacement=\(metrics.hasMeaningfulDisplacement)"
    }

    private func attentionReasons(for samples: [LocationSample], distanceMeters: Double) -> [String] {
        guard let first = samples.first,
              let last = samples.last else {
            return []
        }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration < startPolicy.shortTripRescue.minimumDuration || samples.count < 3 else {
            return []
        }
        return distanceMeters > 0 ? [Self.shortTripInferredAttentionReason] : []
    }
}

private extension LocationSample {
    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    func retimestamped(to timestamp: Date) -> LocationSample {
        LocationSample(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            speedMetersPerSecond: speedMetersPerSecond,
            speedAccuracyMetersPerSecond: speedAccuracyMetersPerSecond,
            courseDegrees: courseDegrees,
            motionHint: motionHint,
            motionActivity: motionActivity
        )
    }
}

private extension Array where Element == String {
    mutating func appendUnique(_ value: String) {
        guard !contains(value) else { return }
        append(value)
    }

    func uniqued() -> [String] {
        reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }
}
