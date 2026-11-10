import AppIntents
import Foundation

enum TripIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable
    case startupUnavailable
    case appLocked
    case currentDriveSaveFailed
    case tripNotFound
    case noCompletedTrips
    case tripReadFailed
    case currentDriveNotFound
    case invalidAmount
    case invalidText
    case feeSaveFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable:
            "Mileager can't reach your trips right now. Unlock your iPhone or iPad and try again."
        case .startupUnavailable:
            "Mileager is still getting your trips ready. Please try again."
        case .appLocked:
            "Open Mileager and unlock the app to access your trips."
        case .currentDriveSaveFailed:
            "Mileager couldn't save your current drive change. Please try again."
        case .tripNotFound:
            "That trip is no longer in Mileager."
        case .noCompletedTrips:
            "Mileager doesn't have any completed drives yet."
        case .tripReadFailed:
            "Mileager couldn't read your trips right now. Open the app and try again."
        case .currentDriveNotFound:
            "Mileager doesn't have a current drive to update right now."
        case .invalidAmount:
            "Enter an amount greater than 0."
        case .invalidText:
            "Tell Mileager what to save."
        case .feeSaveFailed:
            "Mileager couldn't save that fee. Open the app and try again."
        }
    }
}
