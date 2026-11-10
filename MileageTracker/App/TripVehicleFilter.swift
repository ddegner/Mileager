import AppCore
import SwiftUI

/// A whole-list filter for the trip browser and exports: show every vehicle,
/// narrow to one, or show only trips with no vehicle. Composes (AND) with
/// `TripClassificationFilter`. Only surfaced once two or more vehicles exist.
enum TripVehicleFilter: Hashable, Identifiable {
    case all
    case vehicle(UUID)
    case unassigned

    var id: Self { self }

    var isActive: Bool {
        self != .all
    }

    func title(vehicles: [Vehicle]) -> String {
        switch self {
        case .all:
            return String(localized: "All Vehicles")
        case .unassigned:
            return String(localized: "No Vehicle")
        case let .vehicle(id):
            return vehicles.first { $0.id == id }?.name ?? String(localized: "Unknown Vehicle")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "car.2"
        case .vehicle: "car.fill"
        case .unassigned: "car"
        }
    }

    /// Whether a trip passes. The primary vehicle absorbs `nil`-vehicle trips
    /// (the implicit default), so those pass when the primary is selected.
    func matches(_ trip: TripSummary, primaryVehicleID: UUID?) -> Bool {
        switch self {
        case .all:
            return true
        case .unassigned:
            return trip.vehicleID == nil && primaryVehicleID == nil
        case let .vehicle(id):
            if trip.vehicleID == id { return true }
            return trip.vehicleID == nil && id == primaryVehicleID
        }
    }

    func emptyStateMessage(vehicles: [Vehicle]) -> String {
        switch self {
        case .all:
            return String(localized: "No trips yet")
        case .unassigned:
            return String(localized: "No trips without a vehicle")
        case .vehicle:
            return String(localized: "No trips for \(title(vehicles: vehicles))")
        }
    }

    var emptyStateHint: String {
        String(localized: "Assign trips to a vehicle from Trip Detail.")
    }
}
