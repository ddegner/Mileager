import Foundation

/// Complete before-state for fields a review/editing command may change.
/// Identity, creation metadata, capture provenance, Bluetooth hints, and raw
/// samples are intentionally excluded and survive restoration untouched.
public struct TripEditableSnapshot: Equatable, Sendable {
    public var tripID: UUID
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
    public var classification: TripClassification?
    public var classificationSource: TripClassificationSource?
    public var reviewStatus: ReviewStatus
    public var businessPurpose: String?
    public var notes: String?
    public var tollsAmount: Double
    public var parkingAmount: Double
    public var needsAttention: Bool
    public var attentionReasons: [String]
    public var manualDistanceOverrideMeters: Double?
    public var vehicleID: UUID?
    public var vehicleAssignmentSource: VehicleAssignmentSource?
    public var legs: [TripLeg]
    public var connectors: [TripLegConnector]
    public var fees: [TripFee]

    public init(trip: TripSummary, fees: [TripFee]) {
        tripID = trip.id
        startDate = trip.startDate
        endDate = trip.endDate
        startCoordinate = trip.startCoordinate
        endCoordinate = trip.endCoordinate
        startAddress = trip.startAddress
        endAddress = trip.endAddress
        startAddressComponents = trip.startAddressComponents
        endAddressComponents = trip.endAddressComponents
        distanceMeters = trip.distanceMeters
        routePolyline = trip.routePolyline
        classification = trip.classification
        classificationSource = trip.classificationSource
        reviewStatus = trip.reviewStatus
        businessPurpose = trip.businessPurpose
        notes = trip.notes
        tollsAmount = trip.tollsAmount
        parkingAmount = trip.parkingAmount
        needsAttention = trip.needsAttention
        attentionReasons = trip.attentionReasons
        manualDistanceOverrideMeters = trip.manualDistanceOverrideMeters
        vehicleID = trip.vehicleID
        vehicleAssignmentSource = trip.vehicleAssignmentSource
        legs = trip.legs
        connectors = trip.connectors
        self.fees = fees.sorted(by: Self.feeOrder)
    }

    private static func feeOrder(_ lhs: TripFee, _ rhs: TripFee) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct TripCreationSnapshotResult: Equatable, Sendable {
    public var trip: TripSummary
    public var snapshot: TripEditableSnapshot

    public init(trip: TripSummary, snapshot: TripEditableSnapshot) {
        self.trip = trip
        self.snapshot = snapshot
    }
}

public struct TripEditSnapshotResult: Equatable, Sendable {
    public var trip: TripSummary
    public var before: TripEditableSnapshot
    public var after: TripEditableSnapshot

    public init(
        trip: TripSummary,
        before: TripEditableSnapshot,
        after: TripEditableSnapshot
    ) {
        self.trip = trip
        self.before = before
        self.after = after
    }
}
