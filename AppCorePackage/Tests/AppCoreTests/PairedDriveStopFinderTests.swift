import AppCoreModels
import XCTest
@testable import AppCoreEnrichment

final class PairedDriveStopFinderTests: XCTestCase {
    private let home = Coordinate(latitude: 42.3800, longitude: -71.1000)
    private let venue = Coordinate(latitude: 42.3700, longitude: -71.1200)
    private let start = Date(timeIntervalSince1970: 1_801_228_400)
    private let vehicle = UUID()

    func testSeparateOutboundAndReturnTripsProduceTheSameStop() throws {
        let outbound = trip(start: start, end: start.addingTimeInterval(19 * 60),
                            from: home, to: venue)
        let inbound = trip(start: outbound.endDate.addingTimeInterval(73 * 60),
                           end: outbound.endDate.addingTimeInterval(97 * 60),
                           from: venue, to: Coordinate(latitude: home.latitude + 0.0001,
                                                       longitude: home.longitude))
        let outboundStop = try XCTUnwrap(PairedDriveStopFinder.stop(for: outbound, among: [outbound, inbound]))
        let inboundStop = try XCTUnwrap(PairedDriveStopFinder.stop(for: inbound, among: [outbound, inbound]))
        XCTAssertEqual(outboundStop.interval.duration, 73 * 60)
        XCTAssertEqual(outboundStop.interval, inboundStop.interval)
        XCTAssertEqual(outboundStop.partnerID, inbound.id)
        XCTAssertEqual(inboundStop.partnerID, outbound.id)
    }

    func testDifferentVehicleOrInterveningDriveCannotImplyStationaryVisit() {
        let outbound = trip(start: start, end: start.addingTimeInterval(19 * 60),
                            from: home, to: venue)
        var inbound = trip(start: outbound.endDate.addingTimeInterval(73 * 60),
                           end: outbound.endDate.addingTimeInterval(97 * 60),
                           from: venue, to: home)
        inbound.vehicleID = UUID()
        XCTAssertNil(PairedDriveStopFinder.stop(for: outbound, among: [outbound, inbound]))

        inbound.vehicleID = vehicle
        let errand = trip(start: outbound.endDate.addingTimeInterval(20 * 60),
                          end: outbound.endDate.addingTimeInterval(30 * 60),
                          from: venue, to: venue)
        XCTAssertNil(PairedDriveStopFinder.stop(for: outbound, among: [outbound, errand, inbound]))
    }

    func testNearbyNonreciprocalTripAndCityOnlyLocationDoNotPair() {
        let outbound = trip(start: start, end: start.addingTimeInterval(19 * 60),
                            from: home, to: venue)
        let onward = trip(start: outbound.endDate.addingTimeInterval(73 * 60),
                          end: outbound.endDate.addingTimeInterval(97 * 60),
                          from: venue, to: Coordinate(latitude: 42.3900, longitude: -71.1400))
        XCTAssertNil(PairedDriveStopFinder.stop(for: outbound, among: [outbound, onward]))
        var cityOnlyOutbound = outbound
        var cityOnlyInbound = onward
        cityOnlyOutbound.startCoordinate = nil
        cityOnlyOutbound.endCoordinate = nil
        cityOnlyInbound.startCoordinate = nil
        cityOnlyInbound.endCoordinate = nil
        cityOnlyInbound.endAddressComponents = cityOnlyOutbound.startAddressComponents
        cityOnlyOutbound.startAddressComponents = TripEndpointAddressComponents(city: "Somerville")
        cityOnlyInbound.endAddressComponents = TripEndpointAddressComponents(city: "Somerville")
        cityOnlyOutbound.endAddressComponents = TripEndpointAddressComponents(city: "Cambridge")
        cityOnlyInbound.startAddressComponents = TripEndpointAddressComponents(city: "Cambridge")
        XCTAssertNil(PairedDriveStopFinder.stop(for: cityOnlyOutbound,
                                               among: [cityOnlyOutbound, cityOnlyInbound]))
    }

    private func trip(start: Date, end: Date, from: Coordinate, to: Coordinate) -> TripSummary {
        TripSummary(
            id: UUID(), createdAt: start, updatedAt: end, captureSource: "test",
            startDate: start, endDate: end,
            startCoordinate: from, endCoordinate: to,
            startAddress: nil, endAddress: nil,
            distanceMeters: 4_800, routePolyline: nil,
            classification: nil, reviewStatus: .needsReview,
            businessPurpose: nil, notes: nil, tollsAmount: 0, parkingAmount: 0,
            needsAttention: false, attentionReasons: [], manualDistanceOverrideMeters: nil,
            vehicleID: vehicle
        )
    }
}
