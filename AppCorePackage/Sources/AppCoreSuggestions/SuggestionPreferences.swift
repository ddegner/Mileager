import AppCoreModels
import Foundation

/// The one typed wrapper over the eight suggestion preference keys, shared by
/// both platforms so defaults and remove-on-empty semantics can never drift.
/// The keys themselves live in `SuggestionPreferenceKeys` (AppCoreModels) and
/// are the original iPhone strings on both platforms.
public struct SuggestionPreferences {
    public var defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// On by default: suggestions are advisory, on-device, and the whole
    /// feature is invisible on devices without Apple Intelligence.
    public var aiSuggestionsEnabled: Bool {
        get { defaults.object(forKey: SuggestionPreferenceKeys.aiSuggestionsEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: SuggestionPreferenceKeys.aiSuggestionsEnabled) }
    }

    /// Per-device opt-in; never enabled by an upgrade or iCloud preferences.
    public var privateCloudComputeEnabled: Bool {
        get { defaults.bool(forKey: SuggestionPreferenceKeys.privateCloudComputeEnabled) }
        nonmutating set { defaults.set(newValue, forKey: SuggestionPreferenceKeys.privateCloudComputeEnabled) }
    }

    /// Opt-in: reading calendar events needs a system permission prompt, so
    /// the user asks for it explicitly in Settings.
    public var calendarEvidenceEnabled: Bool {
        get { defaults.bool(forKey: SuggestionPreferenceKeys.calendarEvidenceEnabled) }
        nonmutating set { defaults.set(newValue, forKey: SuggestionPreferenceKeys.calendarEvidenceEnabled) }
    }

    /// On by default: the contacts permission is requested when Trip
    /// Suggestions is enabled, so granting it activates the evidence; this
    /// toggle is the opt-out.
    public var contactEvidenceEnabled: Bool {
        get { defaults.object(forKey: SuggestionPreferenceKeys.contactEvidenceEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: SuggestionPreferenceKeys.contactEvidenceEnabled) }
    }

    /// The user's own card for home/work address evidence. Empty strings
    /// remove the key so a cleared field never matches an empty address.
    public var userCardName: String? {
        get { defaults.string(forKey: SuggestionPreferenceKeys.userCardName) }
        nonmutating set { setOrRemove(newValue, forKey: SuggestionPreferenceKeys.userCardName) }
    }

    public var userHomeStreetLine: String? {
        get { defaults.string(forKey: SuggestionPreferenceKeys.userHomeStreetLine) }
        nonmutating set { setOrRemove(newValue, forKey: SuggestionPreferenceKeys.userHomeStreetLine) }
    }

    public var userHomeCity: String? {
        get { defaults.string(forKey: SuggestionPreferenceKeys.userHomeCity) }
        nonmutating set { setOrRemove(newValue, forKey: SuggestionPreferenceKeys.userHomeCity) }
    }

    public var userWorkStreetLine: String? {
        get { defaults.string(forKey: SuggestionPreferenceKeys.userWorkStreetLine) }
        nonmutating set { setOrRemove(newValue, forKey: SuggestionPreferenceKeys.userWorkStreetLine) }
    }

    public var userWorkCity: String? {
        get { defaults.string(forKey: SuggestionPreferenceKeys.userWorkCity) }
        nonmutating set { setOrRemove(newValue, forKey: SuggestionPreferenceKeys.userWorkCity) }
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
