import AppCoreModels
import Foundation

public struct DriveStartPolicy: Codable, Equatable, Sendable {
    public var signalHighFidelityWindow: TimeInterval
    public var idlePrimingWindow: TimeInterval
    /// Deprecated: candidate expiry is now governed solely by
    /// `signalHighFidelityWindow` (via `DriveStartSignal.expiresAt`), shared by the
    /// timer-driven and location-driven expiry paths. Retained for checkpoint
    /// compatibility; no longer read by the reducer.
    public var unconfirmedCandidateTimeout: TimeInterval
    public var minimumMotionConfidenceToArm: MotionConfidence
    public var parkedAnchorRadiusMeters: Double
    public var locationConfirmation: LocationConfirmation
    public var assistConfirmation: AssistConfirmation
    public var parkedStartInference: ParkedStartInference
    public var shortTripRescue: ShortTripRescue
    public var parkingEnd: ParkingEnd
    public var candidateResilience: CandidateResilience

    public static let balanced = DriveStartPolicy(
        signalHighFidelityWindow: 180,
        idlePrimingWindow: 45,
        unconfirmedCandidateTimeout: 300,
        minimumMotionConfidenceToArm: .medium,
        parkedAnchorRadiusMeters: 250,
        locationConfirmation: LocationConfirmation(
            minimumCandidateDisplacementMeters: 75,
            minimumSilentStopGap: 10 * 60,
            motionContradictionSpeedMetersPerSecond: 6,
            postParkingSpeedOnlySuppressionWindow: 30 * 60,
            postParkingSpeedOnlySuppressionDistanceMeters: 1_000
        ),
        assistConfirmation: AssistConfirmation(),
        parkedStartInference: ParkedStartInference(
            maximumAnchorAge: 12 * 60 * 60,
            maximumAnchorAccuracyMeters: 30,
            minimumDisplacementMeters: 150,
            maximumDisplacementMeters: 5_000,
            minimumLeadTime: 10,
            maximumLeadTime: 5 * 60,
            minimumSpeedMetersPerSecond: 8.9,
            fallbackSpeedMetersPerSecond: 13.4,
            maximumSpeedMetersPerSecond: 26.8
        ),
        shortTripRescue: ShortTripRescue(
            minimumDuration: 15,
            maximumDuration: 10 * 60,
            minimumStrongAssistDistanceMeters: 250,
            minimumDistanceMeters: 500
        ),
        parkingEnd: ParkingEnd(
            hardParkingGrace: 20,
            postDisconnectCoordinateGrace: 15,
            motionParkingTransitionWindow: 150,
            continuationDistanceMeters: 100,
            continuationSpeedMetersPerSecond: 5
        ),
        candidateResilience: CandidateResilience()
    )

    public init(
        signalHighFidelityWindow: TimeInterval,
        idlePrimingWindow: TimeInterval,
        unconfirmedCandidateTimeout: TimeInterval,
        minimumMotionConfidenceToArm: MotionConfidence,
        parkedAnchorRadiusMeters: Double,
        locationConfirmation: LocationConfirmation,
        assistConfirmation: AssistConfirmation,
        parkedStartInference: ParkedStartInference,
        shortTripRescue: ShortTripRescue,
        parkingEnd: ParkingEnd,
        candidateResilience: CandidateResilience = CandidateResilience()
    ) {
        self.signalHighFidelityWindow = signalHighFidelityWindow
        self.idlePrimingWindow = idlePrimingWindow
        self.unconfirmedCandidateTimeout = unconfirmedCandidateTimeout
        self.minimumMotionConfidenceToArm = minimumMotionConfidenceToArm
        self.parkedAnchorRadiusMeters = parkedAnchorRadiusMeters
        self.locationConfirmation = locationConfirmation
        self.assistConfirmation = assistConfirmation
        self.parkedStartInference = parkedStartInference
        self.shortTripRescue = shortTripRescue
        self.parkingEnd = parkingEnd
        self.candidateResilience = candidateResilience
    }

    private enum CodingKeys: String, CodingKey {
        case signalHighFidelityWindow
        case idlePrimingWindow
        case unconfirmedCandidateTimeout
        case minimumMotionConfidenceToArm
        case parkedAnchorRadiusMeters
        case locationConfirmation
        case assistConfirmation
        case parkedStartInference
        case shortTripRescue
        case parkingEnd
        case candidateResilience
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            signalHighFidelityWindow: try container.decode(TimeInterval.self, forKey: .signalHighFidelityWindow),
            idlePrimingWindow: try container.decode(TimeInterval.self, forKey: .idlePrimingWindow),
            unconfirmedCandidateTimeout: try container.decode(TimeInterval.self, forKey: .unconfirmedCandidateTimeout),
            minimumMotionConfidenceToArm: try container.decode(MotionConfidence.self, forKey: .minimumMotionConfidenceToArm),
            parkedAnchorRadiusMeters: try container.decode(Double.self, forKey: .parkedAnchorRadiusMeters),
            locationConfirmation: try container.decode(LocationConfirmation.self, forKey: .locationConfirmation),
            assistConfirmation: try container.decode(AssistConfirmation.self, forKey: .assistConfirmation),
            parkedStartInference: try container.decode(ParkedStartInference.self, forKey: .parkedStartInference),
            shortTripRescue: try container.decode(ShortTripRescue.self, forKey: .shortTripRescue),
            parkingEnd: try container.decode(ParkingEnd.self, forKey: .parkingEnd),
            // Added after checkpoints with the earlier policy shape shipped.
            candidateResilience: try container.decodeIfPresent(CandidateResilience.self, forKey: .candidateResilience) ?? CandidateResilience()
        )
    }
}

public extension DriveStartPolicy {
    struct LocationConfirmation: Codable, Equatable, Sendable {
        public var minimumCandidateDisplacementMeters: Double
        public var minimumSilentStopGap: TimeInterval
        public var motionContradictionSpeedMetersPerSecond: Double
        public var postParkingSpeedOnlySuppressionWindow: TimeInterval
        public var postParkingSpeedOnlySuppressionDistanceMeters: Double

        public init(
            minimumCandidateDisplacementMeters: Double,
            minimumSilentStopGap: TimeInterval,
            motionContradictionSpeedMetersPerSecond: Double,
            postParkingSpeedOnlySuppressionWindow: TimeInterval,
            postParkingSpeedOnlySuppressionDistanceMeters: Double
        ) {
            self.minimumCandidateDisplacementMeters = minimumCandidateDisplacementMeters
            self.minimumSilentStopGap = minimumSilentStopGap
            self.motionContradictionSpeedMetersPerSecond = motionContradictionSpeedMetersPerSecond
            self.postParkingSpeedOnlySuppressionWindow = postParkingSpeedOnlySuppressionWindow
            self.postParkingSpeedOnlySuppressionDistanceMeters = postParkingSpeedOnlySuppressionDistanceMeters
        }
    }

    struct AssistConfirmation: Codable, Equatable, Sendable {
        public init() {}
    }

    struct ParkedStartInference: Codable, Equatable, Sendable {
        public var maximumAnchorAge: TimeInterval
        public var maximumAnchorAccuracyMeters: Double
        public var minimumDisplacementMeters: Double
        /// Upper bound on how far the parked anchor may sit from the first trip
        /// sample and still be trusted as the backdated start origin. Beyond this,
        /// the straight-line backdate is implausible (e.g. a delayed wake that
        /// teleports the origin 100+ km away), so the trip starts at the resume
        /// point and is flagged for review instead.
        public var maximumDisplacementMeters: Double
        public var minimumLeadTime: TimeInterval
        public var maximumLeadTime: TimeInterval
        public var minimumSpeedMetersPerSecond: Double
        public var fallbackSpeedMetersPerSecond: Double
        public var maximumSpeedMetersPerSecond: Double

        public init(
            maximumAnchorAge: TimeInterval,
            maximumAnchorAccuracyMeters: Double,
            minimumDisplacementMeters: Double,
            maximumDisplacementMeters: Double = 5_000,
            minimumLeadTime: TimeInterval,
            maximumLeadTime: TimeInterval,
            minimumSpeedMetersPerSecond: Double,
            fallbackSpeedMetersPerSecond: Double,
            maximumSpeedMetersPerSecond: Double
        ) {
            self.maximumAnchorAge = maximumAnchorAge
            self.maximumAnchorAccuracyMeters = maximumAnchorAccuracyMeters
            self.minimumDisplacementMeters = minimumDisplacementMeters
            self.maximumDisplacementMeters = maximumDisplacementMeters
            self.minimumLeadTime = minimumLeadTime
            self.maximumLeadTime = maximumLeadTime
            self.minimumSpeedMetersPerSecond = minimumSpeedMetersPerSecond
            self.fallbackSpeedMetersPerSecond = fallbackSpeedMetersPerSecond
            self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond
        }

        private enum CodingKeys: String, CodingKey {
            case maximumAnchorAge
            case maximumAnchorAccuracyMeters
            case minimumDisplacementMeters
            case maximumDisplacementMeters
            case minimumLeadTime
            case maximumLeadTime
            case minimumSpeedMetersPerSecond
            case fallbackSpeedMetersPerSecond
            case maximumSpeedMetersPerSecond
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                maximumAnchorAge: try container.decode(TimeInterval.self, forKey: .maximumAnchorAge),
                maximumAnchorAccuracyMeters: try container.decode(Double.self, forKey: .maximumAnchorAccuracyMeters),
                minimumDisplacementMeters: try container.decode(Double.self, forKey: .minimumDisplacementMeters),
                // Added after checkpoints with the earlier inference shape shipped.
                maximumDisplacementMeters: try container.decodeIfPresent(Double.self, forKey: .maximumDisplacementMeters) ?? 5_000,
                minimumLeadTime: try container.decode(TimeInterval.self, forKey: .minimumLeadTime),
                maximumLeadTime: try container.decode(TimeInterval.self, forKey: .maximumLeadTime),
                minimumSpeedMetersPerSecond: try container.decode(Double.self, forKey: .minimumSpeedMetersPerSecond),
                fallbackSpeedMetersPerSecond: try container.decode(Double.self, forKey: .fallbackSpeedMetersPerSecond),
                maximumSpeedMetersPerSecond: try container.decode(Double.self, forKey: .maximumSpeedMetersPerSecond)
            )
        }
    }

    struct ShortTripRescue: Codable, Equatable, Sendable {
        public var minimumDuration: TimeInterval
        public var maximumDuration: TimeInterval
        public var minimumStrongAssistDistanceMeters: Double
        public var minimumDistanceMeters: Double

        public init(
            minimumDuration: TimeInterval,
            maximumDuration: TimeInterval,
            minimumStrongAssistDistanceMeters: Double,
            minimumDistanceMeters: Double
        ) {
            self.minimumDuration = minimumDuration
            self.maximumDuration = maximumDuration
            self.minimumStrongAssistDistanceMeters = minimumStrongAssistDistanceMeters
            self.minimumDistanceMeters = minimumDistanceMeters
        }
    }

    /// Keeps drive candidates alive through brief contradictory evidence and
    /// allows a freshly killed candidate to be revived, so GPS/motion flicker
    /// while actually driving doesn't discard accumulated start evidence.
    struct CandidateResilience: Codable, Equatable, Sendable {
        /// Consecutive non-vehicle samples tolerated before the candidate dies.
        public var maximumConsecutiveContradictions: Int
        /// How long a contradiction keeps blocking no-trust confirmation.
        public var contradictionHoldSeconds: TimeInterval
        /// How long after a kill the candidate's evidence can be revived.
        public var reviveWindow: TimeInterval
        /// How long a vehicle-triggered candidate (Bluetooth/CarPlay/charger) tolerates
        /// stationary evidence with zero contradiction cost before first movement, measured
        /// from `candidateStartedAt`. Covers the gap between the car starting (trigger time)
        /// and the user actually driving away (seatbelt, defrost, warmup), so a parked car
        /// doesn't burn the contradiction budget before the drive begins.
        public var preMovementGraceSeconds: TimeInterval
        /// Whether `.lowSpeedMovement` samples (1.2-2.2 m/s, no motion hint - GPS jitter or
        /// a slow crawl out of a parking spot) are also tolerated during the pre-movement
        /// grace, alongside stationary samples.
        public var preMovementToleratesLowSpeed: Bool
        /// After a candidate that never moved is killed by a pedestrian/stationary
        /// contradiction, passive location wakes (`.parkedAnchorExit`,
        /// `.significantLocationChange`, `.visitDeparture`, `.coarseLocationWake`)
        /// cannot re-arm a fresh candidate for this long. Breaks the walk-away churn
        /// loop (2026-07-05: ~20 arm/kill cycles per minute, each cold-starting GPS
        /// and a service session, because the device stays outside the anchor while
        /// the user walks) and backstops the 2026-07-06 stationary-at-home SLC wake
        /// churn. Motion/Bluetooth/power signals are NOT gated, so a real drive
        /// still arms instantly. Sized >= signalHighFidelityWindow (a probe can't
        /// restart inside its own window) and <= preMovementGraceSeconds.
        public var postKillParkedExitCooldownSeconds: TimeInterval

        public init(
            maximumConsecutiveContradictions: Int = 3,
            contradictionHoldSeconds: TimeInterval = 60,
            reviveWindow: TimeInterval = 90,
            preMovementGraceSeconds: TimeInterval = 300,
            preMovementToleratesLowSpeed: Bool = true,
            postKillParkedExitCooldownSeconds: TimeInterval = 180
        ) {
            self.maximumConsecutiveContradictions = maximumConsecutiveContradictions
            self.contradictionHoldSeconds = contradictionHoldSeconds
            self.reviveWindow = reviveWindow
            self.preMovementGraceSeconds = preMovementGraceSeconds
            self.preMovementToleratesLowSpeed = preMovementToleratesLowSpeed
            self.postKillParkedExitCooldownSeconds = postKillParkedExitCooldownSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case maximumConsecutiveContradictions, contradictionHoldSeconds, reviveWindow
            case preMovementGraceSeconds, preMovementToleratesLowSpeed
            case postKillParkedExitCooldownSeconds
        }

        // Legacy-safe: every field falls back to its default so a checkpoint written by a
        // build without the pre-movement keys still decodes.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maximumConsecutiveContradictions = try c.decodeIfPresent(Int.self, forKey: .maximumConsecutiveContradictions) ?? 3
            contradictionHoldSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .contradictionHoldSeconds) ?? 60
            reviveWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .reviveWindow) ?? 90
            preMovementGraceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .preMovementGraceSeconds) ?? 300
            preMovementToleratesLowSpeed = try c.decodeIfPresent(Bool.self, forKey: .preMovementToleratesLowSpeed) ?? true
            postKillParkedExitCooldownSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .postKillParkedExitCooldownSeconds) ?? 180
        }
    }

    struct ParkingEnd: Codable, Equatable, Sendable {
        public var hardParkingGrace: TimeInterval
        public var postDisconnectCoordinateGrace: TimeInterval
        public var motionParkingTransitionWindow: TimeInterval
        public var continuationDistanceMeters: Double
        public var continuationSpeedMetersPerSecond: Double
        /// Traffic-stop protection: if the vehicle was at road speed within
        /// `trafficStopProtectionWindow`, a brief slowdown (toll, jam, drive-thru)
        /// must not complete the trip on weak parking evidence - a disconnect flap
        /// or a false `walking`/stationary sample. The trip is held in
        /// recording/parking for up to `trafficStopHold` and continues if the
        /// vehicle resumes; it completes only on a confirmed pedestrian exit
        /// (`pedestrianExit*`, both required) or when the hold expires.
        public var trafficStopProtectionWindow: TimeInterval
        public var trafficStopMinimumSpeedMetersPerSecond: Double
        public var trafficStopHold: TimeInterval
        public var pedestrianExitMinimumDistanceMeters: Double
        public var pedestrianExitMinimumDuration: TimeInterval

        public init(
            hardParkingGrace: TimeInterval,
            postDisconnectCoordinateGrace: TimeInterval,
            motionParkingTransitionWindow: TimeInterval,
            continuationDistanceMeters: Double,
            continuationSpeedMetersPerSecond: Double,
            trafficStopProtectionWindow: TimeInterval = 180,
            trafficStopMinimumSpeedMetersPerSecond: Double = 8.0,
            trafficStopHold: TimeInterval = 600,
            pedestrianExitMinimumDistanceMeters: Double = 25,
            pedestrianExitMinimumDuration: TimeInterval = 10
        ) {
            self.hardParkingGrace = hardParkingGrace
            self.postDisconnectCoordinateGrace = postDisconnectCoordinateGrace
            self.motionParkingTransitionWindow = motionParkingTransitionWindow
            self.continuationDistanceMeters = continuationDistanceMeters
            self.continuationSpeedMetersPerSecond = continuationSpeedMetersPerSecond
            self.trafficStopProtectionWindow = trafficStopProtectionWindow
            self.trafficStopMinimumSpeedMetersPerSecond = trafficStopMinimumSpeedMetersPerSecond
            self.trafficStopHold = trafficStopHold
            self.pedestrianExitMinimumDistanceMeters = pedestrianExitMinimumDistanceMeters
            self.pedestrianExitMinimumDuration = pedestrianExitMinimumDuration
        }

        private enum CodingKeys: String, CodingKey {
            case hardParkingGrace, postDisconnectCoordinateGrace, motionParkingTransitionWindow
            case continuationDistanceMeters, continuationSpeedMetersPerSecond
            case trafficStopProtectionWindow, trafficStopMinimumSpeedMetersPerSecond, trafficStopHold
            case pedestrianExitMinimumDistanceMeters, pedestrianExitMinimumDuration
        }

        // Legacy-safe: every field falls back to its `.balanced` default so a
        // checkpoint written by a build without these keys still decodes (covers
        // both the traffic-stop keys and the earlier continuation keys).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hardParkingGrace = try c.decodeIfPresent(TimeInterval.self, forKey: .hardParkingGrace) ?? 20
            postDisconnectCoordinateGrace = try c.decodeIfPresent(TimeInterval.self, forKey: .postDisconnectCoordinateGrace) ?? 15
            motionParkingTransitionWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .motionParkingTransitionWindow) ?? 150
            continuationDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .continuationDistanceMeters) ?? 100
            continuationSpeedMetersPerSecond = try c.decodeIfPresent(Double.self, forKey: .continuationSpeedMetersPerSecond) ?? 5
            trafficStopProtectionWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .trafficStopProtectionWindow) ?? 180
            trafficStopMinimumSpeedMetersPerSecond = try c.decodeIfPresent(Double.self, forKey: .trafficStopMinimumSpeedMetersPerSecond) ?? 8.0
            trafficStopHold = try c.decodeIfPresent(TimeInterval.self, forKey: .trafficStopHold) ?? 600
            pedestrianExitMinimumDistanceMeters = try c.decodeIfPresent(Double.self, forKey: .pedestrianExitMinimumDistanceMeters) ?? 25
            pedestrianExitMinimumDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .pedestrianExitMinimumDuration) ?? 10
        }
    }
}

public enum DriveStartExternalTrigger: String, Codable, CaseIterable, Equatable, Sendable {
    case vehicleBluetooth
    case carPlay
    case charger
    case manual

    public var displayName: String {
        switch self {
        case .vehicleBluetooth:
            "Vehicle Bluetooth"
        case .carPlay:
            "CarPlay"
        case .charger:
            "Charger"
        case .manual:
            "Manual"
        }
    }
}

public enum DriveStartEngine {
    public static func signal(
        source: DriveStartSignalSource,
        startedAt: Date,
        policy: DriveStartPolicy = .balanced,
        pendingSignalID: UUID? = nil
    ) -> DriveStartSignal {
        DriveStartSignal(
            source: source,
            confidence: confidence(for: source),
            startedAt: startedAt,
            expiresAt: startedAt.addingTimeInterval(highFidelityWindow(for: source, policy: policy)),
            pendingSignalID: pendingSignalID
        )
    }

    /// Vehicle-trigger sources (Bluetooth/charger connect, whether live or via a
    /// Shortcut automation) get a longer high-fidelity window so a candidate
    /// armed at car-start survives the parked pre-movement period instead of
    /// expiring while the user is still buckling in. The window is capped at
    /// `preMovementGraceSeconds`, not extended indefinitely, so a
    /// connect-without-drive (e.g. CarPlay audio while parked) bounds worst-case
    /// high-fidelity GPS rather than draining it without limit. This also
    /// lengthens the shelf life of the persisted `PendingDriveStartSignal` row
    /// itself (see `PendingDriveStartSignalStore.save`, which derives the row's
    /// `expiresAt` from this same call), giving every background wake path more
    /// time to consume it before it expires unconsumed.
    private static func highFidelityWindow(for source: DriveStartSignalSource, policy: DriveStartPolicy) -> TimeInterval {
        switch source {
        case .trustedBluetooth, .usbPower, .externalVehicleAutomation, .externalChargerAutomation:
            max(policy.signalHighFidelityWindow, policy.candidateResilience.preMovementGraceSeconds)
        case .motionAutomotive, .weakBluetoothName, .parkedAnchorExit, .acceptedVehicleLocation,
             .coarseLocationWake, .significantLocationChange, .visitDeparture:
            policy.signalHighFidelityWindow
        }
    }

    public static func signal(
        forVehicleConnection source: VehicleConnectionSource,
        at date: Date,
        policy: DriveStartPolicy = .balanced
    ) -> DriveStartSignal {
        signal(
            source: source == .usbPower ? .usbPower : .trustedBluetooth,
            startedAt: date,
            policy: policy
        )
    }

    public static func signal(
        forExternalTrigger trigger: DriveStartExternalTrigger,
        at date: Date,
        policy: DriveStartPolicy = .balanced,
        pendingSignalID: UUID? = nil
    ) -> DriveStartSignal {
        let source: DriveStartSignalSource
        switch trigger {
        case .charger:
            source = .externalChargerAutomation
        case .vehicleBluetooth, .carPlay, .manual:
            source = .externalVehicleAutomation
        }
        var signal = signal(source: source, startedAt: date, policy: policy, pendingSignalID: pendingSignalID)
        signal.externalTrigger = trigger
        return signal
    }

    public static func signal(
        forMotion snapshot: MotionActivitySnapshot,
        policy: DriveStartPolicy = .balanced
    ) -> DriveStartSignal? {
        guard shouldArmCandidate(from: snapshot, policy: policy) else { return nil }
        return DriveStartSignal(
            source: .motionAutomotive,
            confidence: snapshot.confidence == .high ? .strong : .assist,
            startedAt: snapshot.startDate,
            expiresAt: snapshot.startDate.addingTimeInterval(policy.signalHighFidelityWindow)
        )
    }

    public static func shouldArmCandidate(
        from snapshot: MotionActivitySnapshot,
        policy: DriveStartPolicy = .balanced
    ) -> Bool {
        snapshot.contains(.automotive) && snapshot.confidence >= policy.minimumMotionConfidenceToArm
    }

    public static func confidence(for source: DriveStartSignalSource) -> DriveStartSignalConfidence {
        switch source {
        case .trustedBluetooth, .acceptedVehicleLocation, .externalVehicleAutomation:
            .strong
        case .motionAutomotive, .usbPower, .parkedAnchorExit, .coarseLocationWake,
             .significantLocationChange, .visitDeparture, .externalChargerAutomation:
            .assist
        case .weakBluetoothName:
            .weak
        }
    }
}

public extension MotionConfidence {
    static func < (lhs: MotionConfidence, rhs: MotionConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    static func >= (lhs: MotionConfidence, rhs: MotionConfidence) -> Bool {
        !(lhs < rhs)
    }

    private var rank: Int {
        switch self {
        case .unknown:
            -1
        case .low:
            0
        case .medium:
            1
        case .high:
            2
        }
    }
}
