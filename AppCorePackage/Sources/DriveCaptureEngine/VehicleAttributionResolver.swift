import AppCoreModels
import Foundation

/// Decides which vehicle a finished drive belongs to, from the vehicle carried
/// by an arming Shortcut and the learned Bluetooth devices observed at its
/// start. Pure and synchronous so it is fully unit-testable.
public struct VehicleAttributionResolver: Sendable {
    public struct Resolution: Equatable, Sendable {
        /// Resolved vehicle, or nil to leave the trip on the default vehicle.
        public var vehicleID: UUID?
        /// How it was resolved; nil when `vehicleID` is nil.
        public var source: VehicleAssignmentSource?
        /// Distinct mapped vehicles when Bluetooth evidence was ambiguous. When
        /// non-empty and `vehicleID` is nil, the caller should flag the trip.
        public var conflictingVehicleIDs: [UUID]

        public init(
            vehicleID: UUID? = nil,
            source: VehicleAssignmentSource? = nil,
            conflictingVehicleIDs: [UUID] = []
        ) {
            self.vehicleID = vehicleID
            self.source = source
            self.conflictingVehicleIDs = conflictingVehicleIDs
        }
    }

    public init() {}

    /// Priority:
    /// 1. `draftVehicleID` keeps its carried source (legacy callers default to
    ///    `.shortcut`) and always wins.
    /// 2. A single distinct mapped vehicle among `observedHints` →
    ///    `.vehicleConnection`.
    /// 3. Otherwise no assignment (nil), reporting any conflicting vehicles.
    public func resolve(
        draftVehicleID: UUID?,
        draftVehicleAssignmentSource: VehicleAssignmentSource? = nil,
        observedHints: [BluetoothDriveHint]
    ) -> Resolution {
        if let draftVehicleID {
            return Resolution(
                vehicleID: draftVehicleID,
                source: draftVehicleAssignmentSource ?? .shortcut
            )
        }

        let mappedVehicleIDs = distinctVehicleIDs(in: observedHints)
        if mappedVehicleIDs.count == 1 {
            return Resolution(vehicleID: mappedVehicleIDs[0], source: .vehicleConnection)
        }
        if mappedVehicleIDs.count > 1 {
            // Trust is evidence that a route often accompanies driving; it is
            // not evidence that one of two mapped vehicle identities is the car
            // currently being driven. Never use it to break an identity tie.
            return Resolution(conflictingVehicleIDs: mappedVehicleIDs)
        }
        return Resolution()
    }

    private func distinctVehicleIDs(in hints: [BluetoothDriveHint]) -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        for case let vehicleID? in hints.map(\.vehicleID) where seen.insert(vehicleID).inserted {
            ordered.append(vehicleID)
        }
        return ordered
    }
}
