import Foundation

public struct TripBulkUpdate: Equatable, Sendable {
    public enum ClassificationMutation: Equatable, Sendable {
        case unchanged
        case clear
        case set(TripClassification)
    }

    public enum VehicleMutation: Equatable, Sendable {
        case unchanged
        case clear
        case set(UUID)
    }

    public var classification: ClassificationMutation
    /// `nil` leaves the purpose untouched; an empty string clears it.
    public var businessPurpose: String?
    /// `nil` leaves notes untouched; an empty string clears them.
    public var notes: String?
    public var vehicle: VehicleMutation
    public var resolveAttention: Bool

    public init(
        classification: ClassificationMutation = .unchanged,
        businessPurpose: String? = nil,
        notes: String? = nil,
        vehicle: VehicleMutation = .unchanged,
        resolveAttention: Bool = false
    ) {
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.vehicle = vehicle
        self.resolveAttention = resolveAttention
    }
}
