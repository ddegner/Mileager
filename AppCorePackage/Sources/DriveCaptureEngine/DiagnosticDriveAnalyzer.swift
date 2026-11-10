import AppCoreModels
import Foundation

package struct PossibleDriveTripDraft: Equatable {
    package var candidate: PossibleDriveCandidate
    package var draft: TripDraft
    package var monitoringSessionID: UUID?
}

public enum DiagnosticDriveAnalyzer {
    public static let burstGap: TimeInterval = 5 * 60
    public static let staleDelayThreshold: TimeInterval = 90
    static let strictRecoveryMinimumDistanceMeters = 200.0
    static let strictRecoveryMinimumSpeedSampleCount = 4
    /// A speed-only burst must peak above sustained cycling speed before it is
    /// recovered. The cycling motion hint is absence-of-evidence in the
    /// background (CoreMotion is not reliably attached to deferred candidates),
    /// so 4 m/s let bike rides through as review trips (August 2026 field
    /// reports); 8 m/s (~18 mph) sits above a typical rider's cruising speed.
    static let strictRecoveryMinimumPeakSpeedMetersPerSecond = 8.0
    private static let minimumSparseCandidateSamples = 4
    private static let minimumStaleRecoverySamples = 5
    private static let minimumPossibleDriveDuration: TimeInterval = 10
    private static let minimumDeferredCandidateDistanceMeters = 75.0
    private static let maximumRecoveryAccuracyMeters = 65.0

    public static func burstSummaries(
        from samples: [DiagnosticLocationSample],
        gap: TimeInterval = burstGap
    ) -> [DiagnosticSampleBurstSummary] {
        bursts(from: samples, gap: gap).compactMap { summary(for: $0) }
    }

    public static func possibleDriveCandidates(
        from samples: [DiagnosticLocationSample],
        gap: TimeInterval = burstGap
    ) -> [PossibleDriveCandidate] {
        possibleDriveDrafts(from: samples, gap: gap).map(\.candidate)
    }

    static func possibleDriveDrafts(
        from samples: [DiagnosticLocationSample],
        gap: TimeInterval = burstGap
    ) -> [PossibleDriveTripDraft] {
        bursts(from: samples, gap: gap, excludesSuppressedStarts: true).compactMap(possibleDriveDraft)
    }

    /// The deliberately narrow subset that is safe to materialize as an
    /// unclassified Needs Review trip. Historical replay found two matches in
    /// 36.31 covered days: both had sustained GPS-reported speed and route
    /// displacement, while the broader speed-only population included walking
    /// and cycling conflicts. Trusted-vehicle and automotive evidence remain
    /// required for silent confirmation in the normal capture path.
    package static func strictRecoveryDrafts(
        from samples: [DiagnosticLocationSample],
        gap: TimeInterval = burstGap
    ) -> [PossibleDriveTripDraft] {
        bursts(from: samples, gap: gap, excludesSuppressedStarts: true).compactMap(strictRecoveryDraft)
    }

    private static func bursts(
        from samples: [DiagnosticLocationSample],
        gap: TimeInterval,
        excludesSuppressedStarts: Bool = false
    ) -> [[DiagnosticLocationSample]] {
        let sorted = samples.sorted {
            if $0.sample.timestamp == $1.sample.timestamp {
                $0.receivedAt < $1.receivedAt
            } else {
                $0.sample.timestamp < $1.sample.timestamp
            }
        }
        var grouped: [[DiagnosticLocationSample]] = []
        var current: [DiagnosticLocationSample] = []
        var previousTimestamp: Date?
        for sample in sorted {
            if excludesSuppressedStarts,
               sample.detectionReason?.contains(DriveCaptureReducer.automaticStartSuppressedReason) == true
                || sample.detectionReason?.contains(DriveCaptureReducer.legacyAutomaticStartSuppressedReason) == true {
                // A policy exclusion is a boundary, not a missing GPS fix.
                // Never bridge permitted stretches across an excluded trip.
                if !current.isEmpty { grouped.append(current) }
                current = []
                previousTimestamp = nil
                continue
            }
            if let previousTimestamp,
               sample.sample.timestamp.timeIntervalSince(previousTimestamp) > gap,
               !current.isEmpty {
                grouped.append(current)
                current = []
            }
            current.append(sample)
            previousTimestamp = sample.sample.timestamp
        }
        if !current.isEmpty {
            grouped.append(current)
        }
        return grouped
    }

    private static func summary(for samples: [DiagnosticLocationSample]) -> DiagnosticSampleBurstSummary? {
        guard let first = samples.first,
              let last = samples.last else {
            return nil
        }
        let locationSamples = samples.map(\.sample)
        let acceptedCount = samples.filter(\.acceptedForDetection).count
        let staleCount = samples.filter(isStale).count
        let delays = samples.map(staleDelaySeconds)
        let speeds = locationSamples.compactMap(\.speedMetersPerSecond).filter { $0 >= 0 }
        let accuracies = locationSamples.map(\.horizontalAccuracy).filter { $0 >= 0 }
        let monitoringSessionIDs = unique(samples.map(\.monitoringSessionID))
        let tripIDs = unique(samples.compactMap(\.tripID))
        return DiagnosticSampleBurstSummary(
            id: deterministicID(sessionID: monitoringSessionIDs.first, date: first.sample.timestamp),
            startDate: first.sample.timestamp,
            endDate: last.sample.timestamp,
            firstReceivedAt: samples.map(\.receivedAt).min() ?? first.receivedAt,
            lastReceivedAt: samples.map(\.receivedAt).max() ?? last.receivedAt,
            sampleCount: samples.count,
            acceptedSampleCount: acceptedCount,
            staleSampleCount: staleCount,
            maxStaleDelaySeconds: delays.max() ?? 0,
            distanceMeters: DistanceCalculator.routeDistanceMeters(
                samples: locationSamples,
                maxAccuracy: maximumRecoveryAccuracyMeters,
                maxSegmentSpeedMetersPerSecond: 60
            ),
            maxSpeedMetersPerSecond: speeds.max(),
            medianHorizontalAccuracyMeters: median(accuracies),
            monitoringSessionIDs: monitoringSessionIDs,
            tripIDs: tripIDs,
            trackingPhases: counts(samples.map(\.trackingPhase)),
            motionHints: counts(locationSamples.map { $0.motionHint.rawValue }),
            detectionOutputs: counts(samples.compactMap(\.detectionOutput)),
            detectionReasons: counts(samples.compactMap(\.detectionReason)),
            trustedBluetoothSampleCount: samples.filter(\.trustedBluetoothVehicleHint).count,
            powerConnectedSampleCount: samples.filter(\.powerConnected).count,
            recentPowerConnectedSampleCount: samples.filter(\.recentPowerConnected).count,
            recentPowerDisconnectedSampleCount: samples.filter(\.recentPowerDisconnected).count
        )
    }

    private static func possibleDriveDraft(for samples: [DiagnosticLocationSample]) -> PossibleDriveTripDraft? {
        guard let summary = summary(for: samples),
              summary.tripIDs.isEmpty,
              summary.sampleCount >= minimumSparseCandidateSamples else {
            return nil
        }

        let duration = summary.endDate.timeIntervalSince(summary.startDate)
        let hasCandidateStart = samples.contains { $0.detectionOutput?.contains("candidateStarted") == true }
        let hasSparseCandidateFailure = samples.contains {
            ($0.detectionReason?.contains("samples=") == true)
                || ($0.detectionReason?.contains("Unconfirmed candidate timed out") == true)
        }
        let hasDiagnosticOnlyDeferral = samples.contains {
            $0.detectionReason?.contains(DriveCandidateDeferralReason.diagnosticPrefix) == true
        }
        let automotiveCount = samples.filter { sample in
            sample.sample.motionHint == .automotive
                || sample.sample.motionActivity?.contains(.automotive) == true
        }.count
        let speedEvidenceCount = samples.filter { ($0.sample.speedMetersPerSecond ?? -1) >= 2.0 }.count
        let staleCount = summary.staleSampleCount
        let accurateCount = samples.filter {
            $0.sample.horizontalAccuracy >= 0
                && $0.sample.horizontalAccuracy <= maximumRecoveryAccuracyMeters
        }.count

        let sparseCandidateQualifies = hasCandidateStart
            && hasSparseCandidateFailure
            && automotiveCount >= 2
            && duration >= minimumPossibleDriveDuration
        let staleReplayQualifies = staleCount >= minimumStaleRecoverySamples
            && (hasCandidateStart || automotiveCount >= 2 || speedEvidenceCount >= 2)
            && duration >= minimumPossibleDriveDuration
        let diagnosticOnlyDeferralQualifies = hasCandidateStart
            && hasDiagnosticOnlyDeferral
            && (automotiveCount >= 1 || speedEvidenceCount >= 2 || summary.distanceMeters >= minimumDeferredCandidateDistanceMeters)
            && duration >= minimumPossibleDriveDuration

        guard accurateCount >= minimumSparseCandidateSamples,
              sparseCandidateQualifies || staleReplayQualifies || diagnosticOnlyDeferralQualifies else {
            return nil
        }

        let draftSamples = samples
            .map(\.sample)
            .filter {
                $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= maximumRecoveryAccuracyMeters
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = draftSamples.first,
              let last = draftSamples.last else {
            return nil
        }

        var reasons = [PossibleDriveCandidate.attentionReason]
        if sparseCandidateQualifies {
            reasons.append("Sparse drive candidate never reached normal confirmation")
        }
        if staleCount > 0 {
            reasons.append("Delayed cached location samples were replayed for review")
        }
        if diagnosticOnlyDeferralQualifies {
            reasons.append("Deferred from visible trips because trusted vehicle evidence was missing")
        }
        if summary.trustedBluetoothSampleCount == 0 {
            reasons.append("No trusted vehicle Bluetooth hint was active")
        }
        reasons = unique(reasons)

        let distance = DistanceCalculator.routeDistanceMeters(
            samples: draftSamples,
            maxAccuracy: maximumRecoveryAccuracyMeters,
            maxSegmentSpeedMetersPerSecond: 60
        )
        let id = deterministicID(
            sessionID: summary.monitoringSessionIDs.first,
            date: first.timestamp
        )
        let candidate = PossibleDriveCandidate(
            id: id,
            startDate: first.timestamp,
            endDate: last.timestamp,
            sampleCount: summary.sampleCount,
            acceptedSampleCount: summary.acceptedSampleCount,
            staleSampleCount: summary.staleSampleCount,
            distanceMeters: distance,
            reasons: reasons,
            monitoringSessionIDs: summary.monitoringSessionIDs,
            linkedTripIDs: summary.tripIDs
        )
        let draft = TripDraft(
            id: id,
            startDate: first.timestamp,
            endDate: last.timestamp,
            samples: draftSamples,
            distanceMeters: distance,
            attentionReasons: reasons
        )
        return PossibleDriveTripDraft(
            candidate: candidate,
            draft: draft,
            monitoringSessionID: summary.monitoringSessionIDs.first
        )
    }

    private static func strictRecoveryDraft(
        for samples: [DiagnosticLocationSample]
    ) -> PossibleDriveTripDraft? {
        guard let draft = possibleDriveDraft(for: samples),
              samples.contains(where: {
                  $0.detectionReason?.contains(DriveCandidateDeferralReason.speedOnlyNoAssist.message) == true
              }),
              draft.candidate.distanceMeters >= strictRecoveryMinimumDistanceMeters else {
            return nil
        }

        let speedEvidence = samples.compactMap { sample -> Double? in
            guard let speed = sample.sample.speedMetersPerSecond,
                  speed.isFinite,
                  speed >= 2 else {
                return nil
            }
            return speed
        }
        guard speedEvidence.count >= strictRecoveryMinimumSpeedSampleCount,
              (speedEvidence.max() ?? 0) >= strictRecoveryMinimumPeakSpeedMetersPerSecond,
              !samples.contains(where: hasPedestrianOrCyclingConflict) else {
            return nil
        }
        return draft
    }

    private static func hasPedestrianOrCyclingConflict(
        _ sample: DiagnosticLocationSample
    ) -> Bool {
        let directHint = sample.sample.motionHint
        if directHint == .walking || directHint == .running || directHint == .cycling {
            return true
        }
        return sample.sample.motionActivity?.hints.contains(where: {
            $0 == .walking || $0 == .running || $0 == .cycling
        }) == true
    }

    private static func isStale(_ sample: DiagnosticLocationSample) -> Bool {
        !sample.acceptedForDetection || staleDelaySeconds(sample) > staleDelayThreshold
    }

    private static func staleDelaySeconds(_ sample: DiagnosticLocationSample) -> Double {
        max(0, sample.receivedAt.timeIntervalSince(sample.sample.timestamp))
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Namespace for sessionless deterministic IDs; parsed once, not per call.
    private static let fallbackSessionID = UUID(uuidString: "8DFDB8CE-CE4E-48E4-8DDF-97D45C9F4E21")!

    private static func deterministicID(sessionID: UUID?, date: Date) -> UUID {
        var uuid = (sessionID ?? fallbackSessionID).uuid
        let seconds = UInt64(max(0, date.timeIntervalSinceReferenceDate.rounded()))
        uuid.0 ^= UInt8((seconds >> 56) & 0xff)
        uuid.1 ^= UInt8((seconds >> 48) & 0xff)
        uuid.2 ^= UInt8((seconds >> 40) & 0xff)
        uuid.3 ^= UInt8((seconds >> 32) & 0xff)
        uuid.4 ^= UInt8((seconds >> 24) & 0xff)
        uuid.5 ^= UInt8((seconds >> 16) & 0xff)
        uuid.6 ^= UInt8((seconds >> 8) & 0xff)
        uuid.7 ^= UInt8(seconds & 0xff)
        return UUID(uuid: uuid)
    }
}
