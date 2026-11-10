import AppCoreEnrichment
import AppCoreModels
import Foundation
import FoundationModels
#if os(macOS)
import Security
#endif

/// Apple Foundation Models: opted-in PCC first, then on-device fallback.
/// A thin adapter — prompt construction and output mapping live in AppCore
/// (`TripSuggestionPromptBuilder`/`TripSuggestionOutputMapper`) where they are
/// unit-tested. Every model failure returns nil per the protocol's soft-fail
/// contract; failures are recorded to diagnostics for field debugging.
@MainActor
public final class FoundationModelsSuggestionProvider: TripSuggestionProviding {
    /// The default general-purpose model, not `.contentTagging`: suggestions
    /// need a free-text rationale and purpose derivation, which the tagging
    /// adapter is not built for. If quality disappoints with calendar
    /// evidence off, `.contentTagging` is the experiment to try.
    /// Field order is load-bearing: guided generation fills properties in
    /// declaration order, so the evidence commitments (which event, what kind
    /// of engagement its title describes) are extracted BEFORE the
    /// classification and purpose — the ID comes from a closed vocabulary, so
    /// a fabricated citation is impossible and every claim resolves to
    /// code-computed ground truth (2026-08-27 field eval: the model otherwise
    /// invents "at destination" rationales and cites preset names as events).
    @Generable
    fileprivate struct SuggestionOutput {
        @Guide(description: "ID of the one calendar event that best explains this trip, or none", .anyOf(["none", "L1", "L2", "L3", "C1", "C2", "C3", "C4"]))
        var citedEventID: String
        @Guide(description: "What kind of engagement the cited event's title describes", .anyOf(["none", "work-engagement", "personal", "ambiguous"]))
        var citedEventNature: String
        @Guide(description: "Most likely classification for this trip", .anyOf(["business", "personal"]))
        var classification: String
        @Guide(description: "Short business purpose, only when business — derived from the cited calendar event when there is one; otherwise prefer one of the user's presets")
        var businessPurpose: String?
        @Guide(description: "Plain 4-8 word evidence phrase; do not repeat classification or business purpose")
        var rationale: String
        @Guide(description: "Confidence from 1 (a guess) to 5 (near certain); 2 when unsure")
        var confidence: Int
    }

    private let record: (String) -> Void
    private var lastAvailabilityDescription: String?

    /// Prefer Private Cloud Compute for generation when the OS offers it
    /// (iOS 27+, entitled build, Apple Intelligence ready). Off by default:
    /// on-device is the product's privacy baseline, PCC is an opt-in quality
    /// upgrade, and every PCC failure (quota, network, availability) falls
    /// back to the on-device model within the same request. The preference
    /// joins SuggestionFingerprint and changing it cancels queued work.
    public var preferPrivateCloudCompute: Bool

    public init(record: @escaping (String) -> Void, preferPrivateCloudCompute: Bool = false) {
        self.record = record
        self.preferPrivateCloudCompute = preferPrivateCloudCompute
    }

    /// Availability alone does not validate the managed entitlement: Apple's
    /// runtime can trap rather than throw for an unauthorized macOS CLI.
    private var cloudHostAuthorized: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.private-cloud-compute" as CFString, nil
        ) as? Bool == true
        #else
        // The iOS app's signed entitlement and provisioning profile are
        // validated by installation. Only the main app includes this provider.
        return true
        #endif
    }

    private func availableRoutes(locale: Locale) -> [SuggestionModelRoute] {
        let localModel = SystemLanguageModel.default
        let localAvailable = localModel.isAvailable && localModel.supportsLocale(locale)
        var cloudAvailable = false
        var cloudQuotaReached = false
        #if compiler(>=6.4) && (os(iOS) || os(macOS))
        if preferPrivateCloudCompute, cloudHostAuthorized, #available(iOS 27.0, macOS 27.0, *) {
            let cloudModel = PrivateCloudComputeLanguageModel()
            cloudAvailable = cloudModel.isAvailable
            cloudQuotaReached = cloudModel.quotaUsage.isLimitReached
        }
        #endif
        let routes = SuggestionModelRouting.routes(
            preferCloud: preferPrivateCloudCompute,
            cloudAvailable: cloudAvailable,
            cloudAuthorized: cloudHostAuthorized,
            cloudQuotaReached: cloudQuotaReached,
            localAvailable: localAvailable
        )
        let description = "Suggestion models: on-device=\(localModel.availability), locale=\(locale.identifier), PCC preferred=\(preferPrivateCloudCompute), available=\(cloudAvailable), quota reached=\(cloudQuotaReached), routes=\(routes.map(\.rawValue))"
        if description != lastAvailabilityDescription {
            lastAvailabilityDescription = description
            record(description)
            #if DEBUG
            print("[suggestion-models] \(description)")
            #endif
        }
        return routes
    }

    public var supportsConfiguration: Bool {
        Self.supportsConfiguration(availability: SystemLanguageModel.default.availability)
    }

    static func supportsConfiguration(availability: SystemLanguageModel.Availability) -> Bool {
        if case .unavailable(.deviceNotEligible) = availability { return false }
        return true
    }

    public var isAvailable: Bool {
        !availableRoutes(locale: .current).isEmpty
    }

    public func prewarm() {
        // Prewarming never sends evidence or spends cloud quota.
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.supportsLocale(.current) else { return }
        LanguageModelSession(model: model).prewarm()
    }

    private enum ModelReadinessError: Error {
        case unavailable, unsupportedLocale
    }

    private func generate(
        route: SuggestionModelRoute,
        instructions: String,
        prompt: String,
        locale: Locale
    ) async throws -> SuggestionOutput {
        let session: LanguageModelSession
        switch route {
        case .privateCloudCompute:
            guard cloudHostAuthorized else { throw ModelReadinessError.unavailable }
            #if compiler(>=6.4) && (os(iOS) || os(macOS))
            if #available(iOS 27.0, macOS 27.0, *) {
                let model = PrivateCloudComputeLanguageModel()
                guard model.isAvailable, !model.quotaUsage.isLimitReached else {
                    throw ModelReadinessError.unavailable
                }
                guard try await model.supportsLocale(locale) else {
                    throw ModelReadinessError.unsupportedLocale
                }
                try Task.checkCancellation()
                // The preference can change while the locale lookup awaits.
                guard preferPrivateCloudCompute else { throw CancellationError() }
                session = LanguageModelSession(model: model) { instructions }
            } else {
                throw ModelReadinessError.unavailable
            }
            #else
            throw ModelReadinessError.unavailable
            #endif
        case .onDevice:
            let model = SystemLanguageModel.default
            guard model.isAvailable, model.supportsLocale(locale) else {
                throw ModelReadinessError.unavailable
            }
            session = LanguageModelSession(model: model) { instructions }
        }
        try Task.checkCancellation()
        return try await session.respond(to: prompt, generating: SuggestionOutput.self).content
    }

    public func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        let locale = Locale(identifier: request.localeIdentifier)
        let routes = availableRoutes(locale: locale)
        guard !routes.isEmpty else { return nil }
        #if DEBUG
        print("[suggestion] generating trip=\(request.trip.id) calendar=\(request.calendarEvidenceEnabled) contacts=\(request.contactEvidenceEnabled)")
        #endif

        // Prefetched, not a tool: the lookup is deterministic (window known
        // up front), and a tool here sent the model into a call loop. Wide
        // window on purpose — the drive usually happens BEFORE an event
        // starts (driving there) or AFTER it ends (driving back), so a window
        // hugging the drive itself finds nothing. Event times are in the
        // lines, so the model can judge proximity.
        let buckets: CalendarEventEvidenceBuilder.BucketedEvents
        if request.calendarEvidenceEnabled {
            // Synchronous EKEventStore query — off the main actor.
            let windowStart = request.trip.startDate.addingTimeInterval(-4 * 3_600)
            let windowEnd = request.trip.endDate.addingTimeInterval(4 * 3_600)
            let candidates = await Task.detached {
                CalendarSuggestionEvidence.candidates(windowStart: windowStart, windowEnd: windowEnd)
            }.value
            buckets = Self.buckets(for: request, candidates: candidates)
        } else {
            buckets = CalendarEventEvidenceBuilder.BucketedEvents(linked: [], context: [])
        }
        let instructions = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: request.localeIdentifier,
            calendarEvidenceIncluded: request.calendarEvidenceEnabled,
            contactEvidenceIncluded: request.contactEvidenceEnabled
        )
        var prompt = TripSuggestionPromptBuilder.prompt(for: request)
        if request.calendarEvidenceEnabled {
            prompt += "\n" + TripSuggestionPromptBuilder.bucketedCalendarSection(
                linkedLines: buckets.linked.map(\.line),
                contextLines: buckets.context.map(\.line)
            )
        }
        do {
            guard let output = try await SuggestionModelRouting.generate(
                routes: routes,
                record: record,
                using: { route in
                    try await self.generate(route: route, instructions: instructions, prompt: prompt, locale: locale)
                }
            ) else { return nil }
            return mappedSuggestion(output: output, request: request, buckets: buckets)
        } catch is CancellationError {
            return nil
        } catch {
            // Guardrail violations, refusals, rate limits, context overflow —
            // all fail soft (the row simply doesn't appear).
            #if DEBUG
            print("[suggestion] error trip=\(request.trip.id): \(error)")
            #endif
            record("Suggestion generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func buckets(
        for request: TripSuggestionRequest,
        candidates: [CalendarEventCandidate]
    ) -> CalendarEventEvidenceBuilder.BucketedEvents {
        // Intermediate stops are legs.dropLast() (the final leg's end IS
        // the destination); combined round trips are usually home-to-home,
        // so the stops are where the drive was actually for.
        let stops = request.trip.legs.dropLast()
        return CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: candidates,
            tripStart: request.trip.startDate,
            tripEnd: request.trip.endDate,
            tripEndCoordinate: request.trip.endCoordinate,
            tripEndComponents: request.trip.endAddressComponents,
            stopCoordinates: stops.map(\.endCoordinate),
            stopComponents: stops.map(\.endAddressComponents),
            stopIntervals: zip(request.trip.legs, request.trip.legs.dropFirst()).map { previous, next in
                guard previous.endDate < next.startDate else { return nil }
                return DateInterval(start: previous.endDate, end: next.startDate)
            },
            pairedDriveStop: request.pairedDriveStop?.interval,
            travelIntervals: request.trip.legs.compactMap {
                $0.startDate < $0.endDate ? DateInterval(start: $0.startDate, end: $0.endDate) : nil
            },
            originCoordinate: request.trip.startCoordinate,
            originComponents: request.trip.startAddressComponents
        )
    }

    private func mappedSuggestion(
        output: SuggestionOutput,
        request: TripSuggestionRequest,
        buckets: CalendarEventEvidenceBuilder.BucketedEvents
    ) -> TripClassificationSuggestion? {
        // The cited ID resolves against the prompted buckets — "none" and
        // out-of-range IDs both come back nil, so no hallucinated title
        // can ever become evidence.
        let cited = buckets.event(withID: output.citedEventID)
        let hasNotes = request.trip.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        #if DEBUG
        print("[suggestion] output trip=\(request.trip.id) class=\(output.classification) confidence=\(output.confidence) citedID=\(output.citedEventID) nature=\(output.citedEventNature) linked=\(buckets.linked.count) context=\(buckets.context.count)")
        #endif
        guard let confidence = SuggestionBusinessGate.adjustedConfidence(
            classification: output.classification,
            cited: cited,
            citedEventNature: output.citedEventNature,
            confidence: output.confidence,
            hasNotes: hasNotes,
            destinationIsWorkplace: request.destinationIsWorkplace,
            isDirectHomeWorkTrip: request.isDirectHomeWorkTrip
        ) else {
            record("Suggestion withheld: business classification lacked supporting evidence.")
            return nil
        }
        if confidence < 3 {
            record("Suggestion withheld: confidence \(confidence) is below 3.")
        }

        var evidence: [TripSuggestionEvidenceItem] = []
        if let cited {
            evidence.append(.calendarEvent(title: cited.title))
        }
        #if DEBUG
        print("[suggestion] result trip=\(request.trip.id) class=\(output.classification) purpose=\(output.businessPurpose ?? "-") conf=\(output.confidence)->\(confidence) citedID=\(output.citedEventID) nature=\(output.citedEventNature) rationale=\(output.rationale)")
        #endif
        return TripSuggestionOutputMapper.suggestion(
            tripID: request.trip.id,
            classification: output.classification,
            businessPurpose: output.businessPurpose,
            rationale: output.rationale,
            confidence: confidence,
            evidence: evidence,
            businessPurposePresets: request.businessPurposePresets
        )
    }

    #if DEBUG
    /// Read-only, PCC-only measurement using the same schema, bucketing,
    /// prompt, evidence gate and output mapper as normal suggestions. Labels
    /// are joined on the host afterwards; no fallback can contaminate PCC scores.
    public func evaluatePrivateCloudCompute(
        request: TripSuggestionRequest,
        candidates: [CalendarEventCandidate]
    ) async -> PCCEvaluationOutcome {
        let started = Date()
        let buckets = Self.buckets(for: request, candidates: candidates)
        let instructions = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: request.localeIdentifier,
            calendarEvidenceIncluded: request.calendarEvidenceEnabled,
            contactEvidenceIncluded: request.contactEvidenceEnabled
        )
        let prompt = TripSuggestionPromptBuilder.prompt(for: request) + "\n"
            + TripSuggestionPromptBuilder.bucketedCalendarSection(
                linkedLines: buckets.linked.map(\.line), contextLines: buckets.context.map(\.line)
            )
        do {
            let output = try await generate(
                route: .privateCloudCompute, instructions: instructions, prompt: prompt,
                locale: Locale(identifier: request.localeIdentifier)
            )
            try Task.checkCancellation()
            let result = mappedSuggestion(output: output, request: request, buckets: buckets)
            return PCCEvaluationOutcome(
                id: request.trip.id, actual: result?.classification.rawValue,
                error: nil, duration: Date().timeIntervalSince(started),
                raw: output.classification, confidence: output.confidence,
                citedID: output.citedEventID, citedTitle: buckets.event(withID: output.citedEventID)?.title,
                nature: output.citedEventNature, rationale: output.rationale,
                linked: buckets.linked.count, context: buckets.context.count, prompt: prompt
            )
        } catch {
            return PCCEvaluationOutcome(
                id: request.trip.id, actual: nil, error: String(describing: error),
                duration: Date().timeIntervalSince(started), raw: nil, confidence: nil,
                citedID: nil, citedTitle: nil, nature: nil, rationale: nil,
                linked: buckets.linked.count, context: buckets.context.count, prompt: prompt
            )
        }
    }
    #endif

}

/// Deterministic Business-output authority gate, separate from model
/// generation so every calendar-permission state follows the same rule and
/// the behavior can be regression-tested without invoking Foundation Models.
enum SuggestionBusinessGate {
    static func adjustedConfidence(
        classification: String,
        cited: CalendarEventEvidenceBuilder.BucketedEvent?,
        citedEventNature: String,
        confidence: Int,
        hasNotes: Bool,
        destinationIsWorkplace: Bool,
        isDirectHomeWorkTrip: Bool = false
    ) -> Int? {
        // Both classes must respect a known conflict with the cited event;
        // a family visit or dinner while driving must not hide business miles.
        guard cited?.hasTravelConflict != true else { return nil }
        guard classification == TripClassification.business.rawValue else { return confidence }
        // A workplace destination alone must never turn an ordinary commute
        // into a Business suggestion, even if a nearby work event is cited.
        guard !isDirectHomeWorkTrip else { return nil }

        // Business needs a linked citation. Context and absent events are not
        // evidence (uncited Business from bare endpoints measured 23%
        // precision). Explicit trip notes or a deterministically identified
        // workplace destination can stand in when no event is cited.
        if let cited {
            guard cited.isLinked else { return nil }
            // A citation is only Business authority when the model first
            // committed that its title clearly describes work. `ambiguous`,
            // `personal`, and inconsistent `none` all fail closed.
            guard citedEventNature == "work-engagement" else { return nil }
            if cited.isTentative { return min(confidence, 2) }
            if cited.hasPairedDriveStop { return min(confidence, 3) }
            // A coherent timed event can explain travel even when the user
            // did not fill in Calendar's Location field. The evidence builder
            // already keeps unrelated times, remote events, and conflicting
            // places out of the linked bucket. Keep timing-only evidence
            // advisory rather than treating it as a verified venue match.
            if !cited.hasPlaceOrStopMatch && !hasNotes && !destinationIsWorkplace {
                return min(confidence, 4)
            }
            return confidence
        }
        guard hasNotes || destinationIsWorkplace else { return nil }
        return confidence
    }
}

#if DEBUG
/// Contains model output and routing evidence, never the saved answer.
public struct PCCEvaluationOutcome: Codable, Sendable {
    public let id: UUID
    public var route: String = "Private Cloud Compute"
    public var promptVersion: Int = SuggestionFingerprint.promptVersion
    public let actual: String?
    public let error: String?
    public let duration: Double
    public let raw: String?
    public let confidence: Int?
    public let citedID: String?
    public let citedTitle: String?
    public let nature: String?
    public let rationale: String?
    public let linked: Int
    public let context: Int
    public let prompt: String
}
#endif
