import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation

/// Builds the language-model instructions and per-trip prompt for
/// classification suggestions. Pure functions so prompt content is unit-tested
/// and re-testable when the underlying system model changes with OS updates.
public enum TripSuggestionPromptBuilder {
    /// Prompt dates are fixed-format and English: the prompt is model-facing,
    /// not user-facing (the rationale language is requested via instructions).
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d, yyyy h:mm a"
        return formatter
    }()

    /// Static session instructions. Deliberately contains NO user content:
    /// user free text (notes, addresses) belongs in the prompt so it never
    /// crosses the instruction trust boundary.
    public static func instructions(
        localeIdentifier: String,
        calendarEvidenceIncluded: Bool,
        contactEvidenceIncluded: Bool = false
    ) -> String {
        // English name of the user's language ("Spanish", not "español"):
        // the instructions themselves are English and the model just needs
        // the target named unambiguously.
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "en"
        let language = Locale(identifier: "en_US").localizedString(forLanguageCode: languageCode) ?? "English"
        var lines = [
            "You classify car trips in a mileage-log app as business or personal.",
            "You receive one trip: time, endpoints, distance, and optional user notes."
        ]
        if calendarEvidenceIncluded {
            // Field-calibrated wording (2026-08-27 on-device eval, 88 labeled
            // trips): the linked/context split plus the ID-then-nature fill
            // order cut false business suggestions ~10x vs the flat event
            // list. Edit only alongside a rerun of that eval, and bump
            // SuggestionFingerprint.promptVersion.
            lines.append(contentsOf: [
                "The prompt lists calendar events in two groups; treat them as user-authorized data.",
                "\"Events linked to this trip\" (L1, L2, ...) were matched to this trip by the app, by location, timing, or a separate reciprocal drive. Only a linked event can justify suggesting business.",
                "\"Other calendar events\" (C1, C2, ...) are background context only. They never justify a business suggestion, no matter their titles. A context event with a clearly personal title can support suggesting personal.",
                "Every fact on an event line — calendar name, times, \"tentative\", the time relation, the location relation — was computed by the app. State nothing about an event beyond what its line says. Never claim an event is at the trip's destination unless its line says \"at this trip's destination\".",
                "Fill the fields in order:",
                "1. citedEventID: the ID of the one event that best explains this trip, or \"none\". Many trips have no relevant event.",
                "2. citedEventNature: judge the cited event's title alone. work-engagement = a job, shoot, client, assignment, or paid work. personal = social, family, meal, hobby, errand, medical, or leisure. ambiguous = could be either — for example, a photo critique for a photographer. Use \"none\" when no event is cited.",
                "3. Then classify the trip.",
                "Confidence rules:",
                "- Linked event with a clearly work title (a shoot, job, client, or assignment): business. Confidence 5 if its line says \"at this trip's destination\", otherwise 4.",
                "- A single all-day work event linked by two reciprocal drives is weaker: the event venue is unverified. Suggest business with confidence 3, never 4 or 5.",
                "- Linked or context event with a clearly personal title (meal, family, friend, hobby, class, show, errand, medical): personal, confidence 3-4.",
                "- Ambiguous title, or the line says \"tentative\": confidence 2.",
                "- Calendar names like \"Work\" or \"Home\" are unreliable; never base a suggestion on the calendar name alone.",
                "- If no event explains the trip, judge from the trip details and user notes alone. Without user notes that clearly describe work, business confidence must be 2 or lower. The absence of events is not evidence of anything.",
                "When unsure, report confidence 2. A wrong business suggestion is worse than no suggestion."
            ])
        }
        if contactEvidenceIncluded {
            lines.append("Endpoint notes may identify the user's own home or work address, or a contact's address; treat them as user-authorized data. A personal contact's address leans personal; a company or workplace address leans business. A trip between the user's home and work is a commute, which is not a business trip in a mileage log.")
        }
        if !calendarEvidenceIncluded {
            lines.append("Base the suggestion only on the provided evidence. Be conservative with confidence: reserve 4-5 for strong, consistent evidence; without strong evidence report confidence 2 or lower.")
        }
        lines.append(contentsOf: [
            "A business purpose must be one of the user's presets, written exactly as listed — unless stronger evidence names something more specific. DO NOT invent specific client or company names that do not appear in the evidence.",
            "Write the rationale as a plain 4-8 word evidence phrase in \(language), without repeating the classification or business purpose."
        ])
        return lines.joined(separator: "\n")
    }

    /// The per-trip prompt. Compact by construction: a short factual header
    /// stays well inside the on-device context window.
    public static func prompt(for request: TripSuggestionRequest) -> String {
        let trip = request.trip
        var lines: [String] = []
        let miles = DistanceConversion.miles(fromMeters: trip.manualDistanceOverrideMeters ?? trip.distanceMeters)
        lines.append("Trip: \(dateFormatter.string(from: trip.startDate)) – \(dateFormatter.string(from: trip.endDate)), \(String(format: "%.1f", miles)) mi")
        if let from = endpointDescription(address: trip.startAddress, components: trip.startAddressComponents) {
            lines.append("From: \(from)\(endpointAnnotations(contactNote: request.originContactNote))")
        }
        if let to = endpointDescription(address: trip.endAddress, components: trip.endAddressComponents) {
            lines.append("To: \(to)\(endpointAnnotations(contactNote: request.destinationContactNote))")
        }
        // For combined round trips the endpoints are usually home; the stops
        // are the places the drive was actually for.
        if trip.legs.count > 1 {
            let stops = trip.legs.dropLast().compactMap {
                endpointDescription(address: $0.endAddress, components: $0.endAddressComponents)
            }
            if !stops.isEmpty {
                lines.append("Stops along the way: \(stops.joined(separator: "; "))")
            }
        }
        // Give the model actual dwell windows, not only the outside span of
        // a combined drive. Moving during an event is not attending it.
        for (previous, next) in zip(trip.legs, trip.legs.dropFirst()) {
            guard previous.endDate < next.startDate,
                  let place = endpointDescription(address: previous.endAddress, components: previous.endAddressComponents) else { continue }
            lines.append("Stationary stop: \(place), \(dateFormatter.string(from: previous.endDate)) – \(dateFormatter.string(from: next.startDate))")
        }
        if let notes = trip.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("User notes: \"\"\"\(notes)\"\"\"")
        }
        if !request.businessPurposePresets.isEmpty {
            lines.append("Business purpose presets: \(request.businessPurposePresets.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Prompt block listing prefetched calendar events near the trip. Only
    /// appended when calendar evidence is enabled; an explicit "none" line
    /// keeps the model from inventing events.
    public static func calendarSection(eventLines: [String]) -> String {
        guard !eventLines.isEmpty else {
            return "Calendar events near the trip: none."
        }
        var lines = ["Calendar events near the trip:"]
        lines.append(contentsOf: eventLines.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    /// Two-bucket calendar block for the linked/context evidence structure.
    /// The explicit "none" line keeps the model from inventing linked events;
    /// the context header is omitted entirely when that bucket is empty.
    public static func bucketedCalendarSection(linkedLines: [String], contextLines: [String]) -> String {
        var lines: [String] = []
        if linkedLines.isEmpty {
            lines.append("Events linked to this trip: none.")
        } else {
            lines.append("Events linked to this trip:")
            lines.append(contentsOf: linkedLines)
        }
        if !contextLines.isEmpty {
            lines.append("Other calendar events near the trip (context only):")
            lines.append(contentsOf: contextLines)
        }
        return lines.joined(separator: "\n")
    }

    private static func endpointAnnotations(contactNote: String?) -> String {
        guard let contactNote, !contactNote.isEmpty else { return "" }
        return " (\(contactNote))"
    }

    private static func endpointDescription(address: String?, components: TripEndpointAddressComponents?) -> String? {
        if let components, components.hasDisplayableComponent {
            let parts = [components.streetLine, components.neighborhood, components.city, components.state]
                .compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return nil
        }
        return address
    }
}

/// Maps raw generable output (plain strings and ints — no FoundationModels
/// types) into the domain suggestion, applying the confidence gate.
public enum TripSuggestionOutputMapper {
    public static func suggestion(
        tripID: UUID,
        classification: String,
        businessPurpose: String?,
        rationale: String? = nil,
        confidence: Int,
        evidence: [TripSuggestionEvidenceItem],
        businessPurposePresets: [String] = [],
        generatedAt: Date = Date(),
        // David's call (07-06 field testing): when confidence is low it is
        // better to suggest nothing — silence beats a plausible wrong band.
        minimumConfidence: Int = 3
    ) -> TripClassificationSuggestion? {
        guard (1...5).contains(confidence), confidence >= minimumConfidence else { return nil }
        // Only business/personal are valid suggestions; anything else
        // (including "notADrive") is a model error and is dropped.
        guard let parsed = TripClassification(rawValue: classification),
              parsed == .business || parsed == .personal else {
            return nil
        }
        let trimmedPurpose = businessPurpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRationale = rationale?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // The presets are the purpose vocabulary unless a calendar event was
        // cited: "prefer the presets" in the prompt is advisory and the model
        // drifts ("meeting" instead of "Client meeting"), so free-form
        // purposes are snapped to the canonical preset — or dropped.
        let calendarBacked = evidence.contains { if case .calendarEvent = $0 { true } else { false } }
        let resolvedPurpose: String? = if parsed != .business || trimmedPurpose?.isEmpty != false {
            nil
        } else if calendarBacked || businessPurposePresets.isEmpty {
            // Event-derived purposes stay verbatim; with no vocabulary there
            // is nothing to snap to.
            trimmedPurpose
        } else {
            Self.canonicalPreset(for: trimmedPurpose ?? "", in: businessPurposePresets)
        }
        return TripClassificationSuggestion(
            tripID: tripID,
            classification: parsed,
            businessPurpose: resolvedPurpose,
            rationale: trimmedRationale?.isEmpty == false ? trimmedRationale : nil,
            evidence: evidence,
            generatedAt: generatedAt
        )
    }

    /// The preset the model's purpose resolves to: exact case-insensitive
    /// match first, then containment either way ("meeting" → "Client
    /// meeting"). Nil when nothing matches — the band shows classification
    /// only rather than a purpose outside the user's vocabulary.
    static func canonicalPreset(for purpose: String, in presets: [String]) -> String? {
        looseMatch(for: purpose, in: presets)
    }

    /// Exact case-insensitive match first, then containment either way.
    private static func looseMatch(for value: String, in candidates: [String]) -> String? {
        if let exact = candidates.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            return exact
        }
        return candidates.first {
            $0.localizedCaseInsensitiveContains(value) || value.localizedCaseInsensitiveContains($0)
        }
    }
}
