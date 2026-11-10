import AppCore
import Foundation

struct DeferredVehicleConnectionConflict: Codable, Equatable {
    var tripID: UUID
    var vehicleIDs: [UUID]
    var latchedVehicleID: UUID?
    var createdAt: Date
}

/// Typed access to the handful of `UserDefaults` values the app persists. One
/// source of truth for keys; no `didSet` ladder needed in `MileageAppModel`.
struct Preferences {
    private static let automaticTrackingEnabledKey = "AutomaticTrackingEnabled"
    private static let automaticTripStartModeKey = "AutomaticTripStartMode"
    private static let lastVehicleAutomationReceivedAtKey = "LastVehicleAutomationReceivedAt"
    private static let syncEnabledKey = "SyncEnabled"
    private static let vehicleBluetoothHintsEnabledKey = "VehicleBluetoothHintsEnabled"
    private static let currentDriveLiveActivitiesEnabledKey = "CurrentDriveLiveActivitiesEnabled"
    private static let detailedDiagnosticsEnabledKey = "DetailedDiagnosticsEnabled"
    private static let hasCompletedOnboardingKey = "HasCompletedOnboarding"
    private static let appLockEnabledKey = "AppLockEnabled"
    private static let siriIndexingEnabledKey = "SiriIndexingEnabled"
    private static let tripCompletionNotificationsEnabledKey = "TripCompletionNotificationsEnabled"
    private static let displayDistanceUnitKey = "DisplayDistanceUnit"
    private static let handledVehicleConnectionTripIDsKey = "HandledVehicleConnectionTripIDs"
    private static let deferredVehicleConnectionConflictsKey = "DeferredVehicleConnectionConflicts"
    private static let irsRateLastAttemptKey = "IRSRateLastAttempt"
    private static let irsRateLastSuccessfulCheckKey = "IRSRateLastSuccessfulCheck"
    private static let irsRateCheckNeedsRetryKey = "IRSRateCheckNeedsRetry"

    static let resettableKeys: [String] = [
        automaticTrackingEnabledKey,
        automaticTripStartModeKey,
        lastVehicleAutomationReceivedAtKey,
        syncEnabledKey,
        vehicleBluetoothHintsEnabledKey,
        currentDriveLiveActivitiesEnabledKey,
        detailedDiagnosticsEnabledKey,
        appLockEnabledKey,
        siriIndexingEnabledKey,
        tripCompletionNotificationsEnabledKey,
        displayDistanceUnitKey,
        handledVehicleConnectionTripIDsKey,
        deferredVehicleConnectionConflictsKey,
        irsRateLastAttemptKey,
        irsRateLastSuccessfulCheckKey,
        irsRateCheckNeedsRetryKey
    ] + SuggestionPreferenceKeys.all

    var defaults: UserDefaults = .standard

    var irsRateCheckNeedsRetry: Bool {
        get { defaults.bool(forKey: Self.irsRateCheckNeedsRetryKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.irsRateCheckNeedsRetryKey) }
    }

    var irsRateLastAttempt: Date? {
        get { defaults.object(forKey: Self.irsRateLastAttemptKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.irsRateLastAttemptKey) }
    }

    var irsRateLastSuccessfulCheck: Date? {
        get { defaults.object(forKey: Self.irsRateLastSuccessfulCheckKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.irsRateLastSuccessfulCheckKey) }
    }

    private var suggestions: SuggestionPreferences { SuggestionPreferences(defaults: defaults) }

    /// `nil` means the user has never expressed a preference — caller decides the default.
    var automaticTrackingEnabled: Bool? {
        get { defaults.object(forKey: Self.automaticTrackingEnabledKey) as? Bool }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.automaticTrackingEnabledKey)
            } else {
                defaults.removeObject(forKey: Self.automaticTrackingEnabledKey)
            }
        }
    }

    var syncEnabled: Bool {
        get { defaults.bool(forKey: Self.syncEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.syncEnabledKey) }
    }

    /// Device-local: Shortcuts automations are configured separately on each
    /// phone. Without a saved selection, allow motion and automation triggers.
    var automaticTripStartMode: AutomaticTripStartMode {
        get {
            defaults.string(forKey: Self.automaticTripStartModeKey)
                .flatMap(AutomaticTripStartMode.init(rawValue:)) ?? .both
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.automaticTripStartModeKey) }
    }

    /// Historical delivery of this device's Bluetooth/CarPlay shortcut action.
    /// A manual test counts; this is not proof of current automation setup.
    var lastVehicleAutomationReceivedAt: Date? {
        defaults.object(forKey: Self.lastVehicleAutomationReceivedAtKey) as? Date
    }

    func recordVehicleAutomationReceipt(trigger: DriveStartExternalTrigger, at date: Date) {
        guard trigger == .vehicleBluetooth || trigger == .carPlay else { return }
        guard lastVehicleAutomationReceivedAt.map({ date > $0 }) ?? true else { return }
        defaults.set(date, forKey: Self.lastVehicleAutomationReceivedAtKey)
    }

    var vehicleBluetoothHintsEnabled: Bool {
        get { defaults.bool(forKey: Self.vehicleBluetoothHintsEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.vehicleBluetoothHintsEnabledKey) }
    }

    var currentDriveLiveActivitiesEnabled: Bool {
        get {
            defaults.object(forKey: Self.currentDriveLiveActivitiesEnabledKey) as? Bool ?? true
        }
        nonmutating set { defaults.set(newValue, forKey: Self.currentDriveLiveActivitiesEnabledKey) }
    }

    /// Detailed capture-event journaling is opt-in. Standard mode still keeps
    /// a short operational sample window for transit detection and recovery.
    var detailedDiagnosticsEnabled: Bool {
        get { defaults.bool(forKey: Self.detailedDiagnosticsEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.detailedDiagnosticsEnabledKey) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Self.hasCompletedOnboardingKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hasCompletedOnboardingKey) }
    }

    var appLockEnabled: Bool {
        get { defaults.bool(forKey: Self.appLockEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.appLockEnabledKey) }
    }

    /// Off by default: trips are location history, and Spotlight surfaces
    /// them outside the app (and outside App Lock), so indexing is opt-in.
    var siriIndexingEnabled: Bool {
        get { defaults.bool(forKey: Self.siriIndexingEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.siriIndexingEnabledKey) }
    }

    /// Off by default: the notification names the drive's time and distance
    /// on the Lock Screen, so asking to classify there is opt-in.
    var tripCompletionNotificationsEnabled: Bool {
        get { defaults.bool(forKey: Self.tripCompletionNotificationsEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.tripCompletionNotificationsEnabledKey) }
    }

    /// Mirror of the *resolved* distance unit ("miles"/"kilometers"). The
    /// source of truth is Core Data (`UnitsCurrencyStore`); this copy exists so
    /// non-MainActor contexts — Siri entity subtitles, Spotlight snippets —
    /// can read the display unit synchronously. Written by `MileageAppModel`
    /// at store load and whenever the preference changes.
    var displayDistanceUnitRaw: String? {
        get { defaults.string(forKey: Self.displayDistanceUnitKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.displayDistanceUnitKey)
            } else {
                defaults.removeObject(forKey: Self.displayDistanceUnitKey)
            }
        }
    }

    /// On by default: suggestions are advisory, on-device by default, and the whole
    /// feature is invisible on devices without Apple Intelligence.
    var aiSuggestionsEnabled: Bool {
        get { suggestions.aiSuggestionsEnabled }
        nonmutating set { suggestions.aiSuggestionsEnabled = newValue }
    }

    /// Off by default and scoped to this device; never enabled through iCloud.
    var privateCloudComputeSuggestionsEnabled: Bool {
        get { suggestions.privateCloudComputeEnabled }
        nonmutating set { suggestions.privateCloudComputeEnabled = newValue }
    }

    /// Opt-in: reading calendar events needs a system permission prompt, so
    /// the user asks for it explicitly in Settings.
    var calendarSuggestionEvidenceEnabled: Bool {
        get { suggestions.calendarEvidenceEnabled }
        nonmutating set { suggestions.calendarEvidenceEnabled = newValue }
    }

    /// On by default: the contacts permission is requested when Trip
    /// Suggestions is enabled, so granting it activates the evidence; this
    /// toggle is the opt-out.
    var contactSuggestionEvidenceEnabled: Bool {
        get { suggestions.contactEvidenceEnabled }
        nonmutating set { suggestions.contactEvidenceEnabled = newValue }
    }

    /// The user's own contact card, chosen in Settings ("My Card"): iOS has
    /// no me-card API, so home/work addresses for suggestion evidence come
    /// from an explicit one-time pick.
    var userCardName: String? {
        get { suggestions.userCardName }
        nonmutating set { suggestions.userCardName = newValue }
    }
    var userHomeStreetLine: String? {
        get { suggestions.userHomeStreetLine }
        nonmutating set { suggestions.userHomeStreetLine = newValue }
    }
    var userHomeCity: String? {
        get { suggestions.userHomeCity }
        nonmutating set { suggestions.userHomeCity = newValue }
    }
    var userWorkStreetLine: String? {
        get { suggestions.userWorkStreetLine }
        nonmutating set { suggestions.userWorkStreetLine = newValue }
    }
    var userWorkCity: String? {
        get { suggestions.userWorkCity }
        nonmutating set { suggestions.userWorkCity = newValue }
    }

    /// Device-local record of trips for which the connection question was
    /// already answered or deferred. This prevents the same completed trip
    /// from asking again after a foreground route refresh.
    var handledVehicleConnectionTripIDs: [UUID] {
        get {
            (defaults.stringArray(forKey: Self.handledVehicleConnectionTripIDsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        nonmutating set {
            defaults.set(
                newValue.map(\.uuidString),
                forKey: Self.handledVehicleConnectionTripIDsKey
            )
        }
    }

    /// Unresolved multi-car conflicts must outlive process termination. The
    /// payload contains only app-generated UUIDs and a timestamp; connection
    /// names and device identifiers stay in their existing protected stores.
    var deferredVehicleConnectionConflicts: [DeferredVehicleConnectionConflict] {
        get {
            guard let data = defaults.data(forKey: Self.deferredVehicleConnectionConflictsKey) else {
                return []
            }
            return (try? JSONDecoder().decode([DeferredVehicleConnectionConflict].self, from: data)) ?? []
        }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.deferredVehicleConnectionConflictsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.deferredVehicleConnectionConflictsKey)
            }
        }
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func clearAll() {
        for key in Self.resettableKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
