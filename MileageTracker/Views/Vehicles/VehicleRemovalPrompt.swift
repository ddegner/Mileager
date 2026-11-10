import AppCore
import Foundation

struct VehicleRemovalPrompt: Equatable {
    var title: String
    var message: String
    var replacementVehicleID: UUID?
    var replacementVehicleName: String?

    static func make(
        removedVehicleID: UUID,
        removedVehicleName: String,
        vehicles: [Vehicle],
        primaryVehicleID: UUID?
    ) -> Self {
        let remainingVehicles = vehicles.filter { $0.id != removedVehicleID }
        let replacement: Vehicle?
        if primaryVehicleID != removedVehicleID,
           let primaryVehicleID,
           let primary = remainingVehicles.first(where: { $0.id == primaryVehicleID }) {
            replacement = primary
        } else {
            replacement = remainingVehicles.first
        }

        let message: String
        if let replacement {
            message = String(localized: "Trips assigned to \(removedVehicleName) will remain and will appear under \(replacement.name), your default vehicle. \(removedVehicleName)’s odometer history and saved CarPlay and Bluetooth connections will be deleted.")
        } else {
            message = String(localized: "Trips assigned to \(removedVehicleName) will remain and will appear under your default vehicle. \(removedVehicleName)’s odometer history and saved CarPlay and Bluetooth connections will be deleted.")
        }

        return Self(
            title: String(localized: "Remove \(removedVehicleName)?"),
            message: message,
            replacementVehicleID: replacement?.id,
            replacementVehicleName: replacement?.name
        )
    }
}
