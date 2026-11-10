import AppCoreModels
import AppCorePersistence
import Foundation

public enum ReportOdometerPolicy {
    /// Returns nil when an all-vehicles report must suppress odometer output.
    /// With one active vehicle, legacy nil assignments belong to that vehicle.
    public static func allVehiclesFilter(activeVehicleIDs: [UUID]) -> VehicleFilter? {
        switch activeVehicleIDs.count {
        case 0:
            .unassigned
        case 1:
            .vehicle(activeVehicleIDs[0], includesUnassigned: true)
        default:
            nil
        }
    }
}
