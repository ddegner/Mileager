import Foundation

public struct TripAutomaticEnrichmentBasis: Equatable, Sendable {
    public var tripID: UUID
    public var updatedAt: Date
    public var startDate: Date
    public var endDate: Date
    public var startCoordinate: Coordinate?
    public var endCoordinate: Coordinate?
    public var startAddress: String?
    public var endAddress: String?
    public var startAddressComponents: TripEndpointAddressComponents?
    public var endAddressComponents: TripEndpointAddressComponents?
    public var routePolyline: String?
    public var distanceMeters: Double
    public var manualDistanceOverrideMeters: Double?
    public var startAddressEnrichmentState: TripEnrichmentState
    public var endAddressEnrichmentState: TripEnrichmentState
    public var routeEnrichmentState: TripEnrichmentState
    public var classification: TripClassification?
    public var reviewStatus: ReviewStatus
    public var attentionReasons: [String]

    public init(trip: TripSummary) {
        tripID = trip.id
        updatedAt = trip.updatedAt
        startDate = trip.startDate
        endDate = trip.endDate
        startCoordinate = trip.startCoordinate
        endCoordinate = trip.endCoordinate
        startAddress = trip.startAddress
        endAddress = trip.endAddress
        startAddressComponents = trip.startAddressComponents
        endAddressComponents = trip.endAddressComponents
        routePolyline = trip.routePolyline
        distanceMeters = trip.distanceMeters
        manualDistanceOverrideMeters = trip.manualDistanceOverrideMeters
        startAddressEnrichmentState = trip.startAddressEnrichmentState
        endAddressEnrichmentState = trip.endAddressEnrichmentState
        routeEnrichmentState = trip.routeEnrichmentState
        classification = trip.classification
        reviewStatus = trip.reviewStatus
        attentionReasons = trip.attentionReasons
    }
}
