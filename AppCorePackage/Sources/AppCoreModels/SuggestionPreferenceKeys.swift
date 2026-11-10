public enum SuggestionPreferenceKeys {
    public static let aiSuggestionsEnabled = "AISuggestionsEnabled"
    public static let privateCloudComputeEnabled = "PrivateCloudComputeSuggestionsEnabled"
    public static let calendarEvidenceEnabled = "CalendarSuggestionEvidenceEnabled"
    public static let contactEvidenceEnabled = "ContactSuggestionEvidenceEnabled"
    public static let userCardName = "UserCardName"
    public static let userHomeStreetLine = "UserHomeStreetLine"
    public static let userHomeCity = "UserHomeCity"
    public static let userWorkStreetLine = "UserWorkStreetLine"
    public static let userWorkCity = "UserWorkCity"

    public static let all = [
        aiSuggestionsEnabled,
        privateCloudComputeEnabled,
        calendarEvidenceEnabled,
        contactEvidenceEnabled,
        userCardName,
        userHomeStreetLine,
        userHomeCity,
        userWorkStreetLine,
        userWorkCity
    ]
}
