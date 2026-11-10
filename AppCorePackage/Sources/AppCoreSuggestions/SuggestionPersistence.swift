import AppCoreEnrichment
import AppCoreModels
import CryptoKit
import Foundation

public enum SuggestionCacheFreshness: Equatable, Sendable {
    case fresh
    case stale
}

public struct SuggestionCacheHit: Sendable {
    public var suggestion: TripClassificationSuggestion
    public var fingerprint: String
    public var freshness: SuggestionCacheFreshness

    public init(
        suggestion: TripClassificationSuggestion,
        fingerprint: String,
        freshness: SuggestionCacheFreshness
    ) {
        self.suggestion = suggestion
        self.fingerprint = fingerprint
        self.freshness = freshness
    }
}

/// Optional persistence policy for the suggestion engine. The iPhone plugs in
/// its Class-C-protected disk cache; the Mac passes nil and suggestions stay
/// in memory (they are never saved on the desktop, per its Settings copy).
/// Every method is best-effort: a failed read degrades to a cache miss.
public protocol SuggestionPersisting: Actor {
    func load(matching expectedFingerprints: [UUID: String]) async -> [UUID: SuggestionCacheHit]
    func save(_ suggestion: TripClassificationSuggestion, fingerprint: String, tripUpdatedAt: Date) async
    func remove(tripIDs: Set<UUID>) async
    func remove(entriesMatching fingerprints: [UUID: String]) async
    func removeAll() async throws
}

/// SHA-256 digest over every input that shaped a suggestion. A cached
/// suggestion replays only while its fingerprint still matches, so any change
/// to the trip, presets, locale, evidence toggles, permissions, or the user's
/// card invalidates exactly the affected rows.
public struct SuggestionFingerprint {
    public static let schemaVersion = 1
    /// Increment when prompt wording, provider behavior, or output mapping
    /// changes enough that an old suggestion should not be replayed.
    /// 12 = a coherent timed work event may back a Business suggestion
    /// without a Calendar Location field. Includes stationary-stop times,
    /// reciprocal-drive stops, and independent PCC readiness.
    public static let promptVersion = 12

    public static func make(
        trip: TripSummary,
        localeIdentifier: String,
        businessPurposePresets: [String],
        calendarEvidenceEnabled: Bool,
        calendarPermissionGranted: Bool,
        contactEvidenceEnabled: Bool,
        contactsPermissionRawValue: Int,
        userCardName: String?,
        userHomeStreetLine: String?,
        userHomeCity: String?,
        userWorkStreetLine: String?,
        userWorkCity: String?,
        privateCloudComputeEnabled: Bool = false,
        pairedDriveStop: PairedDriveStop? = nil
    ) -> String {
        let card = MyCardConfiguration(
            name: userCardName,
            homeStreetLine: userHomeStreetLine,
            homeCity: userHomeCity,
            workStreetLine: userWorkStreetLine,
            workCity: userWorkCity
        )
        let input = Input(
            schemaVersion: schemaVersion,
            promptVersion: promptVersion,
            tripID: trip.id,
            tripUpdatedAt: trip.updatedAt,
            localeIdentifier: localeIdentifier,
            businessPurposePresets: businessPurposePresets,
            calendarEvidenceEnabled: calendarEvidenceEnabled,
            calendarPermissionGranted: calendarPermissionGranted,
            contactEvidenceEnabled: contactEvidenceEnabled,
            contactsPermissionRawValue: contactsPermissionRawValue,
            myCardConfigurationDigest: digest(card),
            privateCloudComputeEnabled: privateCloudComputeEnabled,
            pairedDriveStop: pairedDriveStop
        )
        return digest(input)
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Input: Encodable {
        var schemaVersion: Int
        var promptVersion: Int
        var tripID: UUID
        var tripUpdatedAt: Date
        var localeIdentifier: String
        var businessPurposePresets: [String]
        var calendarEvidenceEnabled: Bool
        var calendarPermissionGranted: Bool
        var contactEvidenceEnabled: Bool
        var contactsPermissionRawValue: Int
        var myCardConfigurationDigest: String
        var privateCloudComputeEnabled: Bool
        var pairedDriveStop: PairedDriveStop?
    }

    private struct MyCardConfiguration: Encodable {
        var name: String?
        var homeStreetLine: String?
        var homeCity: String?
        var workStreetLine: String?
        var workCity: String?
    }
}
