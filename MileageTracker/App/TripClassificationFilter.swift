import AppCore
import SwiftUI

/// A whole-list filter for the trip browser: show everything, or narrow to a
/// single classification. Mirrors `DriveSortOption` so the toolbar menu reads the
/// same way for both controls.
enum TripClassificationFilter: String, CaseIterable, Identifiable {
    case all
    case business
    case personal
    case notADrive

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All Trips")
        case .business: String(localized: "Business")
        case .personal: String(localized: "Personal")
        case .notADrive: String(localized: "Not a Drive")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "car"
        case .business: "briefcase"
        case .personal: "person"
        case .notADrive: "nosign"
        }
    }

    /// The classification a trip must carry to pass, or `nil` for "All Trips".
    var classification: TripClassification? {
        switch self {
        case .all: nil
        case .business: .business
        case .personal: .personal
        case .notADrive: .notADrive
        }
    }

    var isActive: Bool {
        self != .all
    }

    /// The empty-list message shown when a filter matches nothing.
    var emptyStateMessage: String {
        switch self {
        case .all: String(localized: "No trips yet")
        case .business: String(localized: "No business trips")
        case .personal: String(localized: "No personal trips")
        case .notADrive: String(localized: "Nothing marked Not a Drive")
        }
    }

    /// An actionable hint shown beneath the empty-state title, telling the user
    /// how a trip earns this label.
    var emptyStateHint: String {
        switch self {
        case .all: String(localized: "Trips you record will appear here.")
        case .business: String(localized: "Swipe a trip right to mark it Business.")
        case .personal: String(localized: "Swipe a trip left to mark it Personal.")
        case .notADrive: String(localized: "Trips you mark Not a Drive appear here.")
        }
    }

    func matches(_ trip: TripSummary) -> Bool {
        guard let classification else { return true }
        return trip.classification == classification
    }
}
