import Foundation

/// Complete draft committed by a trip editor in one transaction. The draft
/// covers user-editable Cloud fields only; capture provenance, Bluetooth data,
/// attention state, the retired archive storage field, legs, and connectors
/// remain store-owned.
public struct TripEditorUpdate: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var startAddress: String?
    public var endAddress: String?
    public var startAddressComponents: TripEndpointAddressComponents?
    public var endAddressComponents: TripEndpointAddressComponents?
    public var distanceMeters: Double
    public var routePolyline: String?
    public var manualDistanceOverrideMeters: Double?
    public var classification: TripClassification?
    public var businessPurpose: String?
    public var notes: String?
    public var vehicleID: UUID?
    public var fees: [TripFee]

    public init(
        startDate: Date,
        endDate: Date,
        startCoordinate: Coordinate?,
        endCoordinate: Coordinate?,
        startAddress: String?,
        endAddress: String?,
        startAddressComponents: TripEndpointAddressComponents? = nil,
        endAddressComponents: TripEndpointAddressComponents? = nil,
        distanceMeters: Double,
        routePolyline: String?,
        manualDistanceOverrideMeters: Double? = nil,
        classification: TripClassification?,
        businessPurpose: String?,
        notes: String?,
        vehicleID: UUID?,
        fees: [TripFee]
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startCoordinate = startCoordinate
        self.endCoordinate = endCoordinate
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.startAddressComponents = startAddressComponents
        self.endAddressComponents = endAddressComponents
        self.distanceMeters = distanceMeters
        self.routePolyline = routePolyline
        self.manualDistanceOverrideMeters = manualDistanceOverrideMeters
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.notes = notes
        self.vehicleID = vehicleID
        self.fees = fees.sorted(by: Self.feeOrder)
    }

    public init(trip: TripSummary, fees: [TripFee]) {
        self.init(
            startDate: trip.startDate,
            endDate: trip.endDate,
            startCoordinate: trip.startCoordinate,
            endCoordinate: trip.endCoordinate,
            startAddress: trip.startAddress,
            endAddress: trip.endAddress,
            startAddressComponents: trip.startAddressComponents,
            endAddressComponents: trip.endAddressComponents,
            distanceMeters: trip.distanceMeters,
            routePolyline: trip.routePolyline,
            manualDistanceOverrideMeters: trip.manualDistanceOverrideMeters,
            classification: trip.classification,
            businessPurpose: trip.businessPurpose,
            notes: trip.notes,
            vehicleID: trip.vehicleID,
            fees: fees
        )
    }

    package static func feeOrder(_ lhs: TripFee, _ rhs: TripFee) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
