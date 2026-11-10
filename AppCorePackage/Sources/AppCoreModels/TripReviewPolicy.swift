import Foundation

/// What a drive still needs from the user, and whether its mileage may be
/// exported.
///
/// **Engine attention flags gate neither.** `needsAttention` is the engine
/// flagging *itself* — a footnote about how a capture went, raised without the
/// user asking and clearable by no action they can take. It is shown on Trip
/// Detail and the Mac inspector, and it is deliberately absent from both
/// predicates below: a drive the user has already classified is reviewed, and
/// a Business drive with a purpose is exportable, whatever the engine noticed
/// while recording it.
///
/// Withholding on a flag under-claimed mileage silently, which is worse than a
/// number the user can inspect — the drive keeps the distance it was captured
/// with either way.
public enum TripReviewPolicy {
    /// Stamped into `TripSummary.attentionReasons` when the engine backdates a
    /// trip start to the parked location. The canonical constant lives here so
    /// review policy never depends upward on the capture engine; the reducer
    /// re-exports it.
    public static let inferredStartAttentionReason = "Start inferred from parked location"

    private static let nonActionableAttentionReasons: Set<String> = [
        inferredStartAttentionReason
    ]

    package static func actionableAttentionReasons(from reasons: [String]) -> [String] {
        reasons.filter { !nonActionableAttentionReasons.contains($0) }
    }

    package static func isActionableAttentionReason(_ reason: String) -> Bool {
        !nonActionableAttentionReasons.contains(reason)
    }

    public static func normalizedBusinessPurpose(_ purpose: String?) -> String? {
        guard let purpose else { return nil }
        let normalized = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public static func isMissingBusinessPurpose(
        classification: TripClassification?,
        businessPurpose: String?
    ) -> Bool {
        classification == .business && normalizedBusinessPurpose(businessPurpose) == nil
    }

    public static func normalizedStatus(
        classification: TripClassification?,
        businessPurpose: String?,
        hasActionableAttention: Bool,
        requestedStatus: ReviewStatus? = nil
    ) -> ReviewStatus {
        if classification == .notADrive {
            return .readyToExport
        }
        if hasActionableAttention || requestedStatus == .needsAttention {
            return .needsAttention
        }
        if classification == nil || isMissingBusinessPurpose(
            classification: classification,
            businessPurpose: businessPurpose
        ) {
            return .needsReview
        }
        return .readyToExport
    }

    /// Whether the drive belongs in Needs Review: work the user has not done.
    /// Missing purpose counts — that is a classification gap only they can
    /// close. An engine flag does not.
    public static func isUnresolved(
        classification: TripClassification?,
        businessPurpose: String?
    ) -> Bool {
        classification == nil
            || isMissingBusinessPurpose(
                classification: classification,
                businessPurpose: businessPurpose
            )
    }

    /// Whether the drive's mileage enters a report. The user's classification
    /// decides this, not the engine's opinion of its own recording.
    public static func isExportableBusiness(
        classification: TripClassification?,
        businessPurpose: String?
    ) -> Bool {
        classification == .business
            && normalizedBusinessPurpose(businessPurpose) != nil
    }
}
