import Foundation
@testable import AppCore

/// Shared store-backed trip factory. Suites with their own house defaults
/// (addresses, mileage) wrap this in a file-private helper instead of
/// re-building `ManualTripInput` by hand.
@discardableResult
func makeTrip(
    _ store: TripStore,
    start: Date,
    duration: TimeInterval = 1_800,
    distanceMiles: Double = 1,
    classification: TripClassification? = nil,
    businessPurpose: String? = nil,
    startAddress: String? = nil,
    endAddress: String? = nil,
    startCoordinate: Coordinate? = nil,
    endCoordinate: Coordinate? = nil,
    route: [Coordinate]? = nil,
    tolls: Double = 0,
    parking: Double = 0
) throws -> TripSummary {
    let trip = try store.createManualTrip(ManualTripInput(
        startDate: start,
        endDate: start.addingTimeInterval(duration),
        startCoordinate: startCoordinate ?? route?.first,
        endCoordinate: endCoordinate ?? route?.last,
        startAddress: startAddress ?? "Start \(Int(start.timeIntervalSince1970))",
        endAddress: endAddress ?? "End \(Int(start.timeIntervalSince1970))",
        distanceMeters: DistanceConversion.meters(fromMiles: distanceMiles),
        routePolyline: route.map(EncodedPolyline.encode),
        classification: classification,
        businessPurpose: businessPurpose
    ))
    guard tolls != 0 || parking != 0 else { return trip }
    return try store.updateReview(
        tripID: trip.id,
        update: ReviewUpdate(tollsAmount: tolls, parkingAmount: parking)
    )
}
