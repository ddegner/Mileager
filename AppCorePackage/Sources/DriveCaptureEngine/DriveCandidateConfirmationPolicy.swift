import AppCoreModels
import Foundation

struct DriveCandidateEvidence: Equatable, Sendable {
    var elapsed: TimeInterval
    var sampleCount: Int
    var distanceMeters: Double
    var hasMovementEvidence: Bool
    var hasReportedSpeedEvidence: Bool
    var hasDerivedSpeedEvidence: Bool
    var hasMeaningfulDisplacement: Bool
    var hasAutomotiveHint: Bool
    var hasCyclingHint: Bool
    var hasPedestrianHint: Bool
    var hasStationaryHint: Bool
    var hasTrustedVehicleEvidence: Bool
}

enum DriveCandidateDisposition: Equatable, Sendable {
    case confirmVisible
    case continueCollecting
    case deferToDiagnostics(DriveCandidateDeferralReason)
}

package enum DriveCandidateDeferralReason: String, Codable, Equatable, Sendable {
    case noTrustedVehicleEvidence
    case cyclingMotionConflict
    case pedestrianMotionConflict
    case stationaryMotionConflict
    case automotiveOnlyNoAssist
    case speedOnlyNoAssist

    package static let diagnosticPrefix = "Diagnostic-only drive candidate"

    var message: String {
        "\(Self.diagnosticPrefix): \(rawValue)"
    }
}

struct DriveCandidateConfirmationPolicy: Equatable, Sendable {
    /// Fallback thresholds for confirming without a trusted vehicle: sustained
    /// well past the assisted-start gates (45s elapsed, 4 samples, and more than
    /// 2x the 75m minimum candidate displacement) while still comfortably inside
    /// the 180s signal high-fidelity window, so a short unassisted real drive can
    /// confirm before the candidate expires.
    static let fallbackMinimumElapsed: TimeInterval = 45
    static let fallbackMinimumDistanceMeters: Double = 200
    static let fallbackMinimumSampleCount = 4

    func disposition(for evidence: DriveCandidateEvidence) -> DriveCandidateDisposition {
        guard evidence.hasMovementEvidence else {
            return .continueCollecting
        }
        if evidence.hasTrustedVehicleEvidence {
            return .confirmVisible
        }
        if hasStrongSignalAgreement(evidence) {
            // Keep collecting (instead of deferring) until the sustained
            // thresholds are met: the reducer evaluates this policy at the
            // first sample past the minimum start duration and kills the
            // candidate on deferral, so deferring here would make the
            // fallback unreachable with continuous GPS. Candidates that never
            // cross the thresholds still die at the candidate expiry timeout
            // and surface through diagnostics recovery.
            return meetsSustainedFallbackThresholds(evidence) ? .confirmVisible : .continueCollecting
        }
        // An automotive classification without an actively contradicting
        // pedestrian/cycling one is a drive still gathering evidence, not a
        // false positive — the first evaluation often lands right after a
        // wake or at ignition, when the car is creeping below the speed
        // thresholds, displacement is under the bar, and CoreMotion's
        // stationary hint from the parked period hasn't aged out (2026-07-07:
        // the 12 mini was killed four times in six seconds mid-drive at
        // 68–74 m with reported speed, then again the same afternoon at
        // 29–32 m with no measured speed while creeping out of a driveway —
        // each kill clearing signals and restarting the churn). Keep
        // collecting: displacement resolves it, or the candidate expiry
        // discards it into diagnostics. Confirmation rules are unchanged —
        // visibility still requires trusted evidence or reported speed plus
        // sustained displacement.
        if evidence.hasAutomotiveHint,
           !evidence.hasCyclingHint,
           !evidence.hasPedestrianHint {
            return .continueCollecting
        }
        return .deferToDiagnostics(deferralReason(for: evidence))
    }

    /// A candidate may confirm without trusted-vehicle evidence only when
    /// three independent signals agree — CoreMotion automotive classification,
    /// GPS-reported (Doppler) speed, and meaningful displacement — and nothing
    /// contradicts (cycling/pedestrian). Derived speed is excluded because it
    /// is computed from displacement and would double-count that signal.
    /// Stationary hints are tolerated: they legitimately co-occur with real
    /// drives at red lights. Power assist deliberately plays no part here —
    /// power alone must never confirm a visible trip.
    private func hasStrongSignalAgreement(_ evidence: DriveCandidateEvidence) -> Bool {
        evidence.hasAutomotiveHint
            && evidence.hasReportedSpeedEvidence
            && evidence.hasMeaningfulDisplacement
            && !evidence.hasCyclingHint
            && !evidence.hasPedestrianHint
    }

    private func meetsSustainedFallbackThresholds(_ evidence: DriveCandidateEvidence) -> Bool {
        evidence.elapsed >= Self.fallbackMinimumElapsed
            && evidence.distanceMeters >= Self.fallbackMinimumDistanceMeters
            && evidence.sampleCount >= Self.fallbackMinimumSampleCount
    }

    private func deferralReason(for evidence: DriveCandidateEvidence) -> DriveCandidateDeferralReason {
        if evidence.hasCyclingHint {
            return .cyclingMotionConflict
        }
        if evidence.hasPedestrianHint {
            return .pedestrianMotionConflict
        }
        if evidence.hasStationaryHint {
            return .stationaryMotionConflict
        }
        if evidence.hasAutomotiveHint {
            return .automotiveOnlyNoAssist
        }
        if evidence.hasReportedSpeedEvidence || evidence.hasDerivedSpeedEvidence || evidence.hasMeaningfulDisplacement {
            return .speedOnlyNoAssist
        }
        return .noTrustedVehicleEvidence
    }
}
