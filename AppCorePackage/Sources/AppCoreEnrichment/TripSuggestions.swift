import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation

/// The endpoint's relationship to the user's explicitly shared own card.
/// Arbitrary contact addresses must never stand in for the user's own home
/// or workplace when deciding whether a trip is a direct commute.
public enum TripSuggestionEndpointIdentity: Equatable, Sendable {
    case other
    case userHome
    case userWorkplace
}

/// Everything a suggestion provider needs for one trip. Evidence is
/// prefetched so providers stay thin adapters over the model call.
///
/// Limited to the current trip, one adjacent reciprocal drive's inferred
/// stop, calendar events, and contact addresses. The companion drive is used
/// only to derive a stop interval; its raw details never enter the prompt.
public struct TripSuggestionRequest: Sendable {
    public var trip: TripSummary
    public var businessPurposePresets: [String]
    public var calendarEvidenceEnabled: Bool
    public var pairedDriveStop: PairedDriveStop?
    public var localeIdentifier: String
    /// Prompt-facing note identifying the origin, from contact matching:
    /// "the user's home address", "the address of contact “Dana Reyes”".
    public var originContactNote: String?
    public var destinationContactNote: String?
    /// Deterministic contact-address fact used by the Business output gate.
    /// Kept separate from the prompt-facing prose so a home or arbitrary
    /// personal-contact match can never be mistaken for a workplace.
    public var destinationIsWorkplace: Bool
    public var originEndpointIdentity: TripSuggestionEndpointIdentity
    public var destinationEndpointIdentity: TripSuggestionEndpointIdentity
    /// A conservative Business-output exclusion for direct home/work travel.
    /// Combined trips can include a client stop, so their outside endpoints
    /// alone never establish a commute. Legacy direct trips have no legs.
    public var isDirectHomeWorkTrip: Bool {
        guard trip.legs.count <= 1 else { return false }
        return switch (originEndpointIdentity, destinationEndpointIdentity) {
        case (.userHome, .userWorkplace), (.userWorkplace, .userHome): true
        default: false
        }
    }
    /// True when contact evidence is active for this request (adds the
    /// contact-interpretation guidance to the instructions).
    public var contactEvidenceEnabled: Bool

    public init(
        trip: TripSummary,
        businessPurposePresets: [String],
        calendarEvidenceEnabled: Bool,
        localeIdentifier: String,
        pairedDriveStop: PairedDriveStop? = nil,
        originContactNote: String? = nil,
        destinationContactNote: String? = nil,
        destinationIsWorkplace: Bool = false,
        contactEvidenceEnabled: Bool = false,
        originEndpointIdentity: TripSuggestionEndpointIdentity = .other,
        destinationEndpointIdentity: TripSuggestionEndpointIdentity = .other
    ) {
        self.trip = trip
        self.businessPurposePresets = businessPurposePresets
        self.calendarEvidenceEnabled = calendarEvidenceEnabled
        self.pairedDriveStop = pairedDriveStop
        self.localeIdentifier = localeIdentifier
        self.originContactNote = originContactNote
        self.destinationContactNote = destinationContactNote
        self.destinationIsWorkplace = destinationIsWorkplace
        self.originEndpointIdentity = originEndpointIdentity
        self.destinationEndpointIdentity = destinationEndpointIdentity
        self.contactEvidenceEnabled = contactEvidenceEnabled
    }
}

/// One deterministic piece of evidence backing a suggestion — exactly what
/// the band renders when it can cite something more specific than the model's
/// short rationale.
public enum TripSuggestionEvidenceItem: Equatable, Sendable {
    case calendarEvent(title: String)
}

/// An advisory classification suggestion. Never applied automatically; the
/// user accepts it through the normal review write path.
public struct TripClassificationSuggestion: Equatable, Sendable {
    public var tripID: UUID
    /// Only `.business` or `.personal`; the deterministic transit/short-trip
    /// classifiers own `.notADrive`.
    public var classification: TripClassification
    public var businessPurpose: String?
    /// A short, localized explanation from the on-device model. Optional so
    /// deterministic providers and older disposable cache entries can still
    /// supply a structured suggestion without inventing prose.
    public var rationale: String?
    public var evidence: [TripSuggestionEvidenceItem]
    public var generatedAt: Date

    public init(
        tripID: UUID,
        classification: TripClassification,
        businessPurpose: String?,
        rationale: String? = nil,
        evidence: [TripSuggestionEvidenceItem],
        generatedAt: Date
    ) {
        self.tripID = tripID
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.rationale = rationale
        self.evidence = evidence
        self.generatedAt = generatedAt
    }
}

/// Seam for the on-device AI suggestion engine. The production implementation
/// is `FoundationModelsSuggestionProvider` in the `AppCoreSuggestions` target
/// (FoundationModels ships in both the iOS and macOS 26 SDKs); tests inject
/// fakes.
@MainActor
public protocol TripSuggestionProviding: AnyObject {
    /// False hides the entire feature: device ineligible, Apple Intelligence
    /// off, model assets not ready, or locale unsupported.
    var isAvailable: Bool { get }
    /// Configuration remains reachable while a supported model downloads or
    /// cloud quota is exhausted; generation still uses isAvailable.
    var supportsConfiguration: Bool { get }
    func prewarm()
    /// Returns nil on any model failure (guardrail, refusal, rate limit,
    /// context overflow) or low confidence — callers show nothing.
    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion?
}

public extension TripSuggestionProviding {
    var supportsConfiguration: Bool { isAvailable }
}
