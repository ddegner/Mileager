import AppCore
import Foundation

/// The uncommon message shared by a drive row and Trip Detail. Classification
/// is already carried by the leading glyph, so the trailing rail stays quiet
/// unless the drive needs action or the user gave it a note.
///
/// A blocker always wins over a note. Suggestions are retained only while an
/// unclassified drive is blocked on review; once settled, purpose, vehicle,
/// provenance, and routine classification/export copy do not spend this space.
struct DriveRowPreviewLine: Equatable {
    enum Kind: Equatable {
        /// A decision the user still needs to make.
        case blocking
        /// Advisory AI suggestion for an unresolved drive. Never tappable.
        case suggestion
        /// User-authored context on an otherwise-settled drive.
        case note
    }

    var kind: Kind
    /// Classification for a suggestion; primary copy for other preview kinds.
    /// Calendar-backed suggestions display their cited title via inlineText.
    var text: String
    /// The cited calendar event's title, without generated explanation.
    var detail: String? = nil
    /// Presentation metadata kept in the pure formatter so the sparkle is part
    /// of the suggestion contract, not an incidental view decoration.
    var systemImage: String? = nil
    /// Set only for `.suggestion`, so VoiceOver can name the proposed
    /// classification without spending visible space on it.
    var suggestedClassification: TripClassification?

    /// Visible suggestion copy is deliberately one line. The view can truncate
    /// this for space while VoiceOver retains every component below.
    var inlineText: String {
        guard kind == .suggestion else { return text }
        return detail ?? text
    }

    static func make(
        trip: TripSummary,
        suggestion: TripClassificationSuggestion?,
        includesGenericReviewStatus: Bool = true
    ) -> DriveRowPreviewLine? {
        // The inbox title already supplies this state. Specific work such as
        // a missing purpose and advisory suggestions still earns its space.
        guard includesGenericReviewStatus || trip.classification != nil || suggestion != nil else {
            return nil
        }
        return make(
            classification: trip.classification,
            businessPurpose: trip.businessPurpose,
            notes: trip.notes,
            suggestion: suggestion
        )
    }

    static func make(
        classification: TripClassification?,
        businessPurpose: String?,
        notes: String?,
        suggestion: TripClassificationSuggestion?
    ) -> DriveRowPreviewLine? {
        if TripReviewPolicy.isMissingBusinessPurpose(
            classification: classification,
            businessPurpose: businessPurpose
        ) {
            return DriveRowPreviewLine(
                kind: .blocking,
                text: String(localized: "Add a purpose")
            )
        }

        if classification == nil, let suggestion {
            let suggestedType = suggestion.classification.displayName
            let eventTitle = suggestion.evidence.compactMap { item -> String? in
                if case let .calendarEvent(title) = item {
                    return normalizedSuggestionFragment(title)
                }
                return nil
            }.first

            return DriveRowPreviewLine(
                kind: .suggestion,
                text: suggestedType,
                detail: eventTitle,
                systemImage: "sparkles",
                suggestedClassification: suggestion.classification
            )
        }

        if classification == nil {
            return DriveRowPreviewLine(
                kind: .blocking,
                text: String(localized: "Need Review")
            )
        }

        if let note = normalizedNote(notes) {
            return DriveRowPreviewLine(
                kind: .note,
                text: note
            )
        }

        return nil
    }

    private static func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedSuggestionFragment(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    /// What VoiceOver hears. Suggestions already identify themselves visibly;
    /// unlike the sparkle, the advisory state must also be spoken explicitly.
    var accessibilityText: String {
        guard kind == .suggestion,
              let suggestedClassification else { return text }
        if let title = detail {
            return String(localized: "Suggested: \(suggestedClassification.displayName), \(title)")
        }
        return String(localized: "Suggested: \(suggestedClassification.displayName)")
    }
}

/// Shared visible copy for the list row and Trip Detail hero. Keeping these
/// labels in one place makes opening a trip feel like expanding the selected
/// row instead of switching to a separately formatted summary.
enum TripHierarchyPresentation {
    static func timelineLabel(
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let start = startDate.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        let end = if calendar.isDate(startDate, inSameDayAs: endDate) {
            endDate.formatted(.dateTime.hour().minute())
        } else {
            endDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        let duration = Duration.seconds(max(0, endDate.timeIntervalSince(startDate))).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
        return "\(start) – \(end) · \(duration)"
    }
}
