import AppCoreModels
import Foundation

/// Whole-trip GPS-quality evidence extracted from a finished draft and the
/// diagnostic samples recorded around it. Subway and train rides leave a
/// distinctive signature — pervasively degraded accuracy across the trip plus
/// a boarding blackout or re-acquisition jump — that a real drive, even one
/// through a tunnel, does not reproduce.
public struct TransitTripEvidence: Equatable, Sendable {
    public var tripDurationSeconds: TimeInterval
    public var diagnosticSampleCount: Int
    /// Fraction of in-trip samples with usable accuracy (0...65 m).
    public var usableAccuracyFraction: Double
    /// Fraction of 30-second trip windows containing at least one usable sample.
    public var coverageFraction: Double
    public var impossibleJumpCount: Int
    /// Gap between the last pre-trip sample and the trip start. `nil` means no
    /// sample appeared in the whole lookback — at least that long a blackout.
    public var preTripGapSeconds: TimeInterval?
    public var trustedBluetoothSampleCount: Int
    public var powerConnectedSampleCount: Int

    public init(
        tripDurationSeconds: TimeInterval,
        diagnosticSampleCount: Int,
        usableAccuracyFraction: Double,
        coverageFraction: Double,
        impossibleJumpCount: Int,
        preTripGapSeconds: TimeInterval?,
        trustedBluetoothSampleCount: Int,
        powerConnectedSampleCount: Int
    ) {
        self.tripDurationSeconds = tripDurationSeconds
        self.diagnosticSampleCount = diagnosticSampleCount
        self.usableAccuracyFraction = usableAccuracyFraction
        self.coverageFraction = coverageFraction
        self.impossibleJumpCount = impossibleJumpCount
        self.preTripGapSeconds = preTripGapSeconds
        self.trustedBluetoothSampleCount = trustedBluetoothSampleCount
        self.powerConnectedSampleCount = powerConnectedSampleCount
    }

    /// `diagnosticSamples` should cover `[start − lookback, end]`; samples
    /// outside that range are tolerated and ignored.
    public static func extract(draft: TripDraft, diagnosticSamples: [DiagnosticLocationSample]) -> TransitTripEvidence {
        let start = draft.startDate
        let end = draft.endDate
        let duration = max(0, end.timeIntervalSince(start))

        let inTrip = diagnosticSamples.filter { $0.sample.timestamp >= start && $0.sample.timestamp <= end }
        let usable = inTrip.filter { Self.isUsableAccuracy($0.sample.horizontalAccuracy) }

        let windowCount = max(1, Int(ceil(duration / TransitTripClassifier.coverageWindowSeconds)))
        var coveredWindows = Set<Int>()
        for sample in usable {
            let offset = sample.sample.timestamp.timeIntervalSince(start)
            coveredWindows.insert(min(windowCount - 1, Int(offset / TransitTripClassifier.coverageWindowSeconds)))
        }

        let draftJumps = draft.attentionReasons.filter { $0.contains(TransitTripClassifier.impossibleJumpReason) }.count
        let diagnosticJumps = inTrip.filter {
            $0.detectionReason?.contains(TransitTripClassifier.impossibleJumpReason) == true
        }.count

        let lookbackStart = start.addingTimeInterval(-TransitTripClassifier.preTripLookbackSeconds)
        let lastBeforeTrip = diagnosticSamples
            .filter { $0.sample.timestamp >= lookbackStart && $0.sample.timestamp < start }
            .map(\.sample.timestamp)
            .max()

        let bluetoothWindowStart = start.addingTimeInterval(-TransitTripClassifier.bluetoothVetoLeadTime)
        let trustedBluetoothCount = diagnosticSamples.filter {
            $0.trustedBluetoothVehicleHint
                && $0.sample.timestamp >= bluetoothWindowStart
                && $0.sample.timestamp <= end
        }.count

        return TransitTripEvidence(
            tripDurationSeconds: duration,
            diagnosticSampleCount: inTrip.count,
            usableAccuracyFraction: inTrip.isEmpty ? 1 : Double(usable.count) / Double(inTrip.count),
            coverageFraction: Double(coveredWindows.count) / Double(windowCount),
            impossibleJumpCount: draftJumps + diagnosticJumps,
            preTripGapSeconds: lastBeforeTrip.map { start.timeIntervalSince($0) },
            trustedBluetoothSampleCount: trustedBluetoothCount,
            powerConnectedSampleCount: inTrip.filter(\.powerConnected).count
        )
    }

    static func isUsableAccuracy(_ accuracy: Double) -> Bool {
        accuracy >= 0 && accuracy <= TransitTripClassifier.usableAccuracyCeilingMeters
    }
}

public enum TransitTripVerdict: Equatable, Sendable {
    case transit(reason: String)
    case noMatch
}

/// Post-completion classifier for high-confidence transit (subway/train)
/// captures. Pure function over `TransitTripEvidence`; the completion
/// coordinator does the I/O. Calibrated against June 2026 device data: the
/// real subway ride scored usable=0.33 / coverage=0.40 with a jump and a
/// 35-minute boarding blackout, while real drives — including a simulated
/// 3-minute tunnel blackout — stay above 0.8 on both fractions.
public struct TransitTripClassifier: Sendable {
    /// Mirrors the live gate `DriveCaptureConfiguration.maxHorizontalAccuracyMeters`.
    public static let usableAccuracyCeilingMeters: Double = 65
    public static let coverageWindowSeconds: TimeInterval = 30
    /// Matches the reducer's `IgnoreReason.impossibleGPSJump` message.
    public static let impossibleJumpReason = "Impossible GPS jump"

    /// Short fragments never auto-mark: enough evidence volume is required.
    public static let minimumTripDurationSeconds: TimeInterval = 480
    public static let minimumDiagnosticSampleCount = 30
    /// A transit ride delivers junk samples throughout; a tunnel just goes dark.
    public static let maximumUsableAccuracyFraction = 0.5
    /// A single blackout alone can never drag coverage this low.
    public static let maximumCoverageFraction = 0.6
    /// Corroborator: boarding blackout before the trip began.
    public static let minimumPreTripGapSeconds: TimeInterval = 600
    /// How far back `extract` looks for the last pre-trip sample.
    public static let preTripLookbackSeconds: TimeInterval = 45 * 60
    /// Trusted-Bluetooth veto window reaches before the backdated start.
    public static let bluetoothVetoLeadTime: TimeInterval = 10 * 60

    public init() {}

    public func verdict(for evidence: TransitTripEvidence) -> TransitTripVerdict {
        guard evidence.tripDurationSeconds >= Self.minimumTripDurationSeconds,
              evidence.diagnosticSampleCount >= Self.minimumDiagnosticSampleCount,
              evidence.usableAccuracyFraction <= Self.maximumUsableAccuracyFraction,
              evidence.coverageFraction <= Self.maximumCoverageFraction else {
            return .noMatch
        }

        // No sample in the whole lookback is at least that long a blackout.
        let preTripGapPresent: Bool
        if let gap = evidence.preTripGapSeconds {
            preTripGapPresent = gap >= Self.minimumPreTripGapSeconds
        } else {
            preTripGapPresent = true
        }
        guard evidence.impossibleJumpCount >= 1 || preTripGapPresent else {
            return .noMatch
        }

        // Any trusted-vehicle or charging evidence vetoes: that's a car.
        guard evidence.trustedBluetoothSampleCount == 0,
              evidence.powerConnectedSampleCount == 0 else {
            return .noMatch
        }

        let usable = String(format: "%.2f", evidence.usableAccuracyFraction)
        let coverage = String(format: "%.2f", evidence.coverageFraction)
        let gap = evidence.preTripGapSeconds.map { String(format: "%.0fs", $0) } ?? ">=lookback"
        return .transit(reason: "usable=\(usable) coverage=\(coverage) jumps=\(evidence.impossibleJumpCount) preGap=\(gap)")
    }
}
