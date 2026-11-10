import Foundation

public struct DriveCompletionResult: Equatable, Sendable {
    public var trip: TripSummary
    public var samples: [LocationSample]
    public var conflictingVehicleIDs: [UUID]

    public init(
        trip: TripSummary,
        samples: [LocationSample],
        conflictingVehicleIDs: [UUID] = []
    ) {
        self.trip = trip
        self.samples = samples
        self.conflictingVehicleIDs = conflictingVehicleIDs
    }
}

public enum DriveCompletionOutcome: Sendable {
    case saved(DriveCompletionResult)
    case discardedAutomaticCapture(source: TripClassificationSource, reason: String)
}

public extension DriveCompletionOutcome {
    var savedResult: DriveCompletionResult? {
        guard case .saved(let result) = self else { return nil }
        return result
    }
}

public protocol DriveCompletionCoordinating: AnyObject {
    @discardableResult
    func complete(_ draft: TripDraft, monitoringSessionID: UUID?) throws -> DriveCompletionOutcome
    func clearActiveStateIfIdle(_ state: DriveCaptureState) throws
    /// True when any saved trip other than `excludedID` overlaps the window.
    /// Diagnostic possible-drive recovery uses this as its duplicate
    /// backstop before materializing a candidate; normal live completion
    /// never consults it.
    func hasTripOverlapping(start: Date, end: Date, excluding excludedID: UUID) throws -> Bool
}

public final class DriveCompletionCoordinator: DriveCompletionCoordinating {
    private enum AutomaticCaptureClassifier: CaseIterable {
        /// First because its evidence is the most decisive and the cheapest:
        /// a flight leg that also looks transit-like should be reported as a
        /// flight, and it needs no store round-trip.
        case aircraft
        /// Second: its evidence rides on the draft, and a bracketed ride that
        /// is also tiny should be reported as cycling, not as a parking blip.
        case cycling
        case shortTrip
        case transit
    }

    private enum ConfinedPostParkingPolicy {
        static let maximumPriorGapSeconds: TimeInterval = 15 * 60
        static let maximumPriorEndpointDistanceMeters = 250.0
        static let maximumCaptureDistanceMeters = DistanceConversion.meters(fromMiles: 0.5)
        static let maximumCaptureDurationSeconds: TimeInterval = 20 * 60
        static let maximumFootprintDiagonalMeters = 125.0
        static let maximumEndpointDisplacementMeters = 50.0
        // Haversine round-trips can land a fraction of a micron above an
        // inclusive boundary even when the source coordinate is exactly on it.
        static let geometryBoundaryToleranceMeters = 0.001
        static let pedestrianSpeedCeilingMetersPerSecond = 4.0
        static let minimumSlowSpeedFraction = 0.95
        static let minimumUsableSampleCount = 3
        // A sub-30-second capture cannot carry 20 speed fixes, so the general
        // sample-count floor below would keep every one of them regardless of
        // evidence. The tiny-artifact tier instead bounds the distance by
        // physics: 30 s at the 4 m/s pedestrian ceiling is 120 m, and 150 m
        // leaves room for GPS scatter. A 25 m bound previously let a
        // 21-second stationary capture through after GPS reported a 113 m path
        // near the parking endpoint at pedestrian speeds.
        static let tinyArtifactMaximumDistanceMeters = 150.0
        static let tinyArtifactMaximumDurationSeconds: TimeInterval = 30
        static let minimumTinyArtifactSpeedSampleCount = 2
        static let minimumConfinedMovementSpeedSampleCount = 20
    }

    private struct ConfinedPostParkingEvidence {
        var priorGapSeconds: TimeInterval
        var priorEndpointDistanceMeters: Double
        var footprintDiagonalMeters: Double
        var endpointDisplacementMeters: Double
        var slowSpeedFraction: Double

        var reason: String {
            String(
                format: "Confined post-parking movement gap=%.0fs priorDistance=%.0fm footprint=%.0fm displacement=%.0fm slowSpeedFraction=%.2f",
                priorGapSeconds,
                priorEndpointDistanceMeters,
                footprintDiagonalMeters,
                endpointDisplacementMeters,
                slowSpeedFraction
            )
        }
    }

    private struct AutomaticDiscardDecision {
        var source: TripClassificationSource
        var reason: String
    }

    /// Stored on the trip when Bluetooth observations match more than one
    /// vehicle. Persisted verbatim as a logic key; the UI maps it to localized
    /// copy at display time (TripDetailView.displayAttentionReason).
    public static let ambiguousVehicleAttentionReason = "Multiple vehicles detected near start"

    private let tripStore: TripStore
    private let activeDriveStore: ActiveDriveStore
    private let diagnosticSampleStore: (any DiagnosticSamplePersisting)?
    private let bluetoothHintStore: BluetoothDriveHintStore?
    private let configuration: DriveCaptureConfiguration
    private let transitClassifier: TransitTripClassifier
    private let aircraftClassifier: AircraftTripClassifier
    private let cyclingClassifier: CyclingTripClassifier
    private let attributionResolver: VehicleAttributionResolver

    public init(
        tripStore: TripStore,
        activeDriveStore: ActiveDriveStore,
        diagnosticSampleStore: (any DiagnosticSamplePersisting)? = nil,
        bluetoothHintStore: BluetoothDriveHintStore? = nil,
        configuration: DriveCaptureConfiguration = .automatic,
        transitClassifier: TransitTripClassifier = TransitTripClassifier(),
        aircraftClassifier: AircraftTripClassifier = AircraftTripClassifier(),
        cyclingClassifier: CyclingTripClassifier = CyclingTripClassifier(),
        attributionResolver: VehicleAttributionResolver = VehicleAttributionResolver()
    ) {
        self.tripStore = tripStore
        self.activeDriveStore = activeDriveStore
        self.diagnosticSampleStore = diagnosticSampleStore
        self.bluetoothHintStore = bluetoothHintStore
        self.configuration = configuration
        self.transitClassifier = transitClassifier
        self.aircraftClassifier = aircraftClassifier
        self.cyclingClassifier = cyclingClassifier
        self.attributionResolver = attributionResolver
    }

    @discardableResult
    public func hasTripOverlapping(
        start: Date,
        end: Date,
        excluding excludedID: UUID
    ) throws -> Bool {
        try tripStore.fetchTrips(from: start, to: end).contains { $0.id != excludedID }
    }

    public func complete(
        _ draft: TripDraft,
        monitoringSessionID: UUID?
    ) throws -> DriveCompletionOutcome {
        let existing = try tripStore.fetchTripIfExists(id: draft.id)
        // User decisions always win over machine classifiers: a manual
        // classification (idempotent recompletion or a post-save edit) and a
        // classification/fee/purpose/note entered mid-drive before a short or
        // transit-like capture completes both count. Untouched rows can be
        // discarded or removed safely because the classifier is the only
        // source of truth for them.
        let hasUserDecision = Self.hasUserDecision(existing: existing, draft: draft)
        if !hasUserDecision, let decision = automaticDiscardDecision(for: draft) {
            if existing != nil {
                try tripStore.deleteTrip(id: draft.id)
            }
            return .discardedAutomaticCapture(
                source: decision.source,
                reason: decision.reason
            )
        }

        var trip = try tripStore.saveCompletedTrip(draft, configuration: configuration)
        // Tagging is diagnostics-only, and the trip row above is already
        // committed — a tagging failure must never abort the completion
        // (mirrors the hint stamping below: store failures must never block
        // the save). Throwing here left the saved trip's draft retrying
        // forever, because only a normal return clears it.
        if let monitoringSessionID {
            _ = try? diagnosticSampleStore?.tagSamples(
                monitoringSessionID: monitoringSessionID,
                tripID: trip.id,
                from: draft.startDate,
                to: draft.endDate
            )
        } else {
            _ = try? diagnosticSampleStore?.tagSamples(
                tripID: trip.id,
                from: draft.startDate,
                to: draft.endDate
            )
        }
        // Stamp the devices observed around the drive's start so a review
        // decision can train vehicle trust long after the observations expire.
        if let bluetoothHintStore,
           let hashes = try? bluetoothHintStore.observations(near: draft.startDate).map(\.identifierHash),
           !hashes.isEmpty {
            trip = try tripStore.setStartBluetoothHints(tripID: trip.id, identifierHashes: hashes)
        }
        // Attribute the trip to a vehicle from the arming Shortcut or a mapped
        // Bluetooth device. Never override a manual assignment; resolver or
        // store failures must never block the save (mirrors the hint stamping
        // above).
        var conflictingVehicleIDs = draft.conflictingVehicleIDs
        if existing?.vehicleAssignmentSource != .manual {
            let mappedHints: [BluetoothDriveHint]
            if let bluetoothHintStore {
                mappedHints = ((try? bluetoothHintStore.fetchHints(
                    matching: Set(trip.startBluetoothHintHashes)
                )) ?? []).filter(\.canIdentifyVehicleSilently)
            } else {
                mappedHints = []
            }
            let resolution = attributionResolver.resolve(
                draftVehicleID: draft.vehicleID,
                draftVehicleAssignmentSource: draft.vehicleAssignmentSource,
                observedHints: mappedHints
            )
            if let vehicleID = resolution.vehicleID, let source = resolution.source {
                trip = (try? tripStore.applyAutomaticVehicleAssignment(
                    tripID: trip.id,
                    vehicleID: vehicleID,
                    source: source
                )) ?? trip
            } else if !resolution.conflictingVehicleIDs.isEmpty {
                trip = (try? tripStore.appendAttentionReason(
                    tripID: trip.id,
                    reason: Self.ambiguousVehicleAttentionReason
                )) ?? trip
            }
            conflictingVehicleIDs.append(contentsOf: resolution.conflictingVehicleIDs)
        }
        conflictingVehicleIDs = Array(Set(conflictingVehicleIDs))
            .filter { $0 != trip.vehicleID }
            .sorted { $0.uuidString < $1.uuidString }
        return .saved(DriveCompletionResult(
            trip: trip,
            samples: draft.samples,
            conflictingVehicleIDs: conflictingVehicleIDs
        ))
    }

    /// True once a real person has put anything into this capture — a manual
    /// classification on the persisted row, a fee/purpose/note on either the
    /// row or the in-flight draft. The short-trip and transit classifiers only
    /// get the last word over an untouched, machine-only capture.
    private static func hasUserDecision(existing: TripSummary?, draft: TripDraft) -> Bool {
        if let existing {
            if existing.manualDistanceOverrideMeters != nil
                || existing.vehicleAssignmentSource == .manual {
                return true
            }
            if existing.startAddressEnrichmentState == .userManaged
                || existing.endAddressEnrichmentState == .userManaged
                || existing.routeEnrichmentState == .userManaged {
                return true
            }
            if existing.classification != nil, existing.classificationSource == nil {
                return true
            }
            if existing.tollsAmount > 0
                || existing.parkingAmount > 0
                || existing.businessPurpose != nil
                || existing.notes != nil {
                return true
            }
        }
        return draft.vehicleAssignmentSource == .manual
            || draft.classification != nil
            || !draft.fees.isEmpty
            || draft.businessPurpose != nil
            || draft.notes != nil
    }

    /// A single ordered pre-persistence seam for every machine classifier
    /// whose terminal decision means the capture must not become a trip.
    private func automaticDiscardDecision(for draft: TripDraft) -> AutomaticDiscardDecision? {
        for classifier in AutomaticCaptureClassifier.allCases {
            switch classifier {
            case .aircraft:
                let evidence = AircraftTripEvidence.extract(draft: draft)
                if case .aircraft(let reason) = aircraftClassifier.verdict(for: evidence) {
                    return AutomaticDiscardDecision(source: .autoAircraft, reason: reason)
                }
            case .cycling:
                let evidence = CyclingTripEvidence.extract(
                    draft: draft,
                    vehicleConnectionObserved: vehicleConnectionObservedOutsideReducer(for: draft)
                )
                if case .cycling(let reason) = cyclingClassifier.verdict(for: evidence) {
                    return AutomaticDiscardDecision(source: .autoCycling, reason: reason)
                }
            case .shortTrip:
                if let evidence = confinedPostParkingEvidence(for: draft) {
                    return AutomaticDiscardDecision(
                        source: .autoShortTrip,
                        reason: evidence.reason
                    )
                }
            case .transit:
                guard let diagnosticSampleStore,
                      let diagnosticSamples = try? diagnosticSampleStore.fetchSamples(
                          since: draft.startDate.addingTimeInterval(-TransitTripClassifier.preTripLookbackSeconds),
                          until: draft.endDate
                      ) else {
                    continue
                }
                let evidence = TransitTripEvidence.extract(
                    draft: draft,
                    diagnosticSamples: diagnosticSamples
                )
                if case .transit(let reason) = transitClassifier.verdict(for: evidence) {
                    return AutomaticDiscardDecision(source: .autoTransit, reason: reason)
                }
            }
        }
        return nil
    }

    /// Vehicle evidence the reducer cannot see: a vehicle already attached to
    /// the draft, a mapped or trusted car observed near the start, or a
    /// trusted hint stamped on the diagnostic samples around the capture. Any
    /// of them vetoes the cycling discard and keeps the trip.
    private func vehicleConnectionObservedOutsideReducer(for draft: TripDraft) -> Bool {
        if draft.vehicleID != nil || draft.vehicleAssignmentSource != nil {
            return true
        }
        if let bluetoothHintStore,
           let observations = try? bluetoothHintStore.observations(near: draft.startDate),
           !observations.isEmpty,
           let hints = try? bluetoothHintStore.fetchHints(
               matching: Set(observations.map(\.identifierHash))
           ),
           hints.contains(where: { $0.canIdentifyVehicleSilently || ($0.trusted && $0.contributesDriveDetection) }) {
            return true
        }
        if let diagnosticSampleStore,
           let samples = try? diagnosticSampleStore.fetchSamples(
               since: draft.startDate.addingTimeInterval(-CyclingTripClassifier.vehicleConnectionLeadSeconds),
               until: draft.endDate
           ),
           samples.contains(where: \.trustedBluetoothVehicleHint) {
            return true
        }
        return false
    }

    /// A fail-open replacement for the old distance-only short-trip rule.
    /// A capture is discarded only when recent parking context, compact route
    /// geometry, low speeds, and the complete absence of automotive motion all
    /// agree that the phone moved locally after a vehicle trip ended.
    private func confinedPostParkingEvidence(for draft: TripDraft) -> ConfinedPostParkingEvidence? {
        let duration = draft.endDate.timeIntervalSince(draft.startDate)
        guard draft.distanceMeters.isFinite,
              draft.distanceMeters >= 0,
              draft.distanceMeters <= ConfinedPostParkingPolicy.maximumCaptureDistanceMeters,
              duration > 0,
              duration <= ConfinedPostParkingPolicy.maximumCaptureDurationSeconds else {
            return nil
        }

        let usableSamples = draft.samples
            .filter {
                $0.timestamp >= draft.startDate
                    && $0.timestamp <= draft.endDate
                    && Self.isUsableCoordinateSample(
                        $0,
                        maximumHorizontalAccuracyMeters: configuration.maxHorizontalAccuracyMeters
                    )
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard usableSamples.count >= ConfinedPostParkingPolicy.minimumUsableSampleCount,
              let firstSample = usableSamples.first,
              let lastSample = usableSamples.last,
              let priorTrip = mostRecentPriorTrip(for: draft),
              let priorEndpoint = priorTrip.endCoordinate,
              Self.isValidCoordinate(priorEndpoint) else {
            return nil
        }

        let priorGap = draft.startDate.timeIntervalSince(priorTrip.endDate)
        guard priorGap >= 0,
              priorGap <= ConfinedPostParkingPolicy.maximumPriorGapSeconds else {
            return nil
        }

        let firstCoordinate = Coordinate(
            latitude: firstSample.latitude,
            longitude: firstSample.longitude
        )
        let priorEndpointDistance = DistanceCalculator.distanceMeters(
            from: priorEndpoint,
            to: firstCoordinate
        )
        guard priorEndpointDistance.isFinite,
              priorEndpointDistance
                <= ConfinedPostParkingPolicy.maximumPriorEndpointDistanceMeters
                    + ConfinedPostParkingPolicy.geometryBoundaryToleranceMeters,
              let footprintDiagonal = Self.boundingBoxDiagonalMeters(for: usableSamples),
              footprintDiagonal
                <= ConfinedPostParkingPolicy.maximumFootprintDiagonalMeters
                    + ConfinedPostParkingPolicy.geometryBoundaryToleranceMeters else {
            return nil
        }

        let lastCoordinate = Coordinate(
            latitude: lastSample.latitude,
            longitude: lastSample.longitude
        )
        let endpointDisplacement = DistanceCalculator.distanceMeters(
            from: firstCoordinate,
            to: lastCoordinate
        )
        guard endpointDisplacement.isFinite,
              endpointDisplacement
                <= ConfinedPostParkingPolicy.maximumEndpointDisplacementMeters
                    + ConfinedPostParkingPolicy.geometryBoundaryToleranceMeters,
              !draft.samples.contains(where: Self.hasAutomotiveMotion) else {
            return nil
        }

        let speeds = usableSamples.compactMap { sample -> Double? in
            guard let speed = sample.speedMetersPerSecond,
                  speed.isFinite,
                  speed >= 0 else {
                return nil
            }
            return speed
        }
        let isTinyArtifact = draft.distanceMeters <= ConfinedPostParkingPolicy.tinyArtifactMaximumDistanceMeters
            && duration <= ConfinedPostParkingPolicy.tinyArtifactMaximumDurationSeconds
        let minimumSpeedSampleCount = isTinyArtifact
            ? ConfinedPostParkingPolicy.minimumTinyArtifactSpeedSampleCount
            : ConfinedPostParkingPolicy.minimumConfinedMovementSpeedSampleCount
        guard speeds.count >= minimumSpeedSampleCount else {
            return nil
        }
        let slowSpeedCount = speeds.lazy.filter {
            $0 < ConfinedPostParkingPolicy.pedestrianSpeedCeilingMetersPerSecond
        }.count
        let slowSpeedFraction = Double(slowSpeedCount) / Double(speeds.count)
        guard slowSpeedFraction >= ConfinedPostParkingPolicy.minimumSlowSpeedFraction else {
            return nil
        }

        return ConfinedPostParkingEvidence(
            priorGapSeconds: priorGap,
            priorEndpointDistanceMeters: priorEndpointDistance,
            footprintDiagonalMeters: footprintDiagonal,
            endpointDisplacementMeters: endpointDisplacement,
            slowSpeedFraction: slowSpeedFraction
        )
    }

    /// `fetchTrips` uses overlap semantics, so explicitly require a predecessor
    /// that ended before this draft and choose by end date rather than fetch order.
    private func mostRecentPriorTrip(for draft: TripDraft) -> TripSummary? {
        let lookbackStart = draft.startDate.addingTimeInterval(
            -ConfinedPostParkingPolicy.maximumPriorGapSeconds
        )
        guard let trips = try? tripStore.fetchTrips(
            from: lookbackStart,
            to: draft.startDate
        ) else {
            return nil
        }
        return trips
            .filter {
                $0.id != draft.id
                    && $0.endDate <= draft.startDate
                    && $0.classification != .notADrive
            }
            .max { lhs, rhs in
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate < rhs.endDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func isUsableCoordinateSample(
        _ sample: LocationSample,
        maximumHorizontalAccuracyMeters: Double
    ) -> Bool {
        sample.latitude.isFinite
            && (-90...90).contains(sample.latitude)
            && sample.longitude.isFinite
            && (-180...180).contains(sample.longitude)
            && sample.horizontalAccuracy.isFinite
            && sample.horizontalAccuracy >= 0
            && sample.horizontalAccuracy <= maximumHorizontalAccuracyMeters
    }

    private static func isValidCoordinate(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && coordinate.longitude.isFinite
            && (-180...180).contains(coordinate.longitude)
    }

    /// The latitude/longitude bounding-box diagonal is an O(n) conservative
    /// upper bound on the exact pairwise footprint diameter: overestimation
    /// saves borderline captures rather than making them easier to discard.
    private static func boundingBoxDiagonalMeters(for samples: [LocationSample]) -> Double? {
        guard let minimumLatitude = samples.map(\.latitude).min(),
              let maximumLatitude = samples.map(\.latitude).max(),
              let minimumLongitude = samples.map(\.longitude).min(),
              let maximumLongitude = samples.map(\.longitude).max(),
              maximumLongitude - minimumLongitude <= 180 else {
            return nil
        }
        let diagonal = DistanceCalculator.distanceMeters(
            from: Coordinate(latitude: minimumLatitude, longitude: minimumLongitude),
            to: Coordinate(latitude: maximumLatitude, longitude: maximumLongitude)
        )
        return diagonal.isFinite ? diagonal : nil
    }

    private static func hasAutomotiveMotion(_ sample: LocationSample) -> Bool {
        sample.motionHint == .automotive
            || sample.motionActivity?.contains(.automotive) == true
    }

    public func clearActiveStateIfIdle(_ state: DriveCaptureState) throws {
        guard state.phase == .idle,
              state.pendingCompletionDraft == nil,
              state.parkedStartAnchor == nil,
              state.vehicleParkingAnchor == nil else {
            try activeDriveStore.save(state)
            return
        }
        try activeDriveStore.clear()
    }
}
