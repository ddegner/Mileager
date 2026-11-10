import Foundation

/// A user-facing error presented as an alert. The title is context-specific so a
/// failure reads as "Export Failed" or "Couldn't Save Changes" rather than the
/// bare app name; the message carries the underlying detail.
struct AppErrorAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// The operation that failed, mapped to the alert title the user sees.
enum AppErrorContext {
    case saveChanges
    case loadData
    case export
    case importData
    case saveSettings
    case sampleData
    case generic

    var title: String {
        switch self {
        case .saveChanges: String(localized: "Couldn't Save Changes")
        case .loadData: String(localized: "Couldn't Load Trips")
        case .export: String(localized: "Export Failed")
        case .importData: String(localized: "Import Failed")
        case .saveSettings: String(localized: "Couldn't Save Settings")
        case .sampleData: String(localized: "Sample Data Unavailable")
        case .generic: String(localized: "Something Went Wrong")
        }
    }
}
