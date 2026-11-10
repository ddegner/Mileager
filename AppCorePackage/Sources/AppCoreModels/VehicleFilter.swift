import Foundation

/// Selects trips by vehicle. `.vehicle(id, includesUnassigned:)` passes
/// `includesUnassigned: true` for the primary vehicle so `nil`-vehicle trips
/// (the implicit default) are shown alongside it.
public enum VehicleFilter: Equatable, Sendable {
    case any
    case vehicle(UUID, includesUnassigned: Bool)
    case unassigned
}
