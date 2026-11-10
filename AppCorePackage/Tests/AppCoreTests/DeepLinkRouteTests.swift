import XCTest
@testable import AppCore

final class DeepLinkRouteTests: XCTestCase {
    func testParsesCurrentDriveRoute() {
        let id = UUID()
        let url = URL(string: "mileager://drive/\(id.uuidString)")!
        XCTAssertEqual(DeepLinkRoute.parse(url), .currentDrive(tripID: id))
    }

    func testParsesFeeRoutes() {
        let id = UUID()
        XCTAssertEqual(
            DeepLinkRoute.parse(URL(string: "mileager://drive/\(id.uuidString)/fee/toll")!),
            .currentDriveFee(tripID: id, category: .toll)
        )
        XCTAssertEqual(
            DeepLinkRoute.parse(URL(string: "mileager://drive/\(id.uuidString)/fee/parking")!),
            .currentDriveFee(tripID: id, category: .parking)
        )
    }

    func testParsesCurrentDriveVehicleRoute() {
        let id = UUID()
        XCTAssertEqual(
            DeepLinkRoute.parse(URL(string: "mileager://drive/\(id.uuidString)/vehicle")!),
            .currentDriveVehicle(tripID: id)
        )
    }

    func testParsesCurrentDriveNewLegRoute() {
        let id = UUID()
        XCTAssertEqual(
            DeepLinkRoute.parse(URL(string: "mileager://drive/\(id.uuidString)/new-leg")!),
            .currentDriveNewLeg(tripID: id)
        )
    }

    func testRoundTripBuildAndParse() {
        let id = UUID()
        let routes: [DeepLinkRoute] = [
            .currentDrive(tripID: id),
            .currentDriveVehicle(tripID: id),
            .currentDriveFee(tripID: id, category: .toll),
            .currentDriveFee(tripID: id, category: .parking),
            .currentDriveNewLeg(tripID: id)
        ]
        for route in routes {
            XCTAssertEqual(DeepLinkRoute.parse(route.url), route, "round trip failed for \(route)")
        }
    }

    func testRejectsMalformedURLs() {
        let id = UUID().uuidString
        let bad = [
            "https://drive/\(id)",                       // wrong scheme
            "mileager://trip/\(id)",                       // wrong host
            "mileager://drive/not-a-uuid",                 // bad id
            "mileager://drive/\(id)/fee",                  // missing category
            "mileager://drive/\(id)/fee/fuel",             // unknown category
            "mileager://drive/\(id)/extra/toll",           // unknown 2-segment sub-route
            "mileager://drive/\(id)/legs"                  // unknown 1-segment sub-route
        ]
        for string in bad {
            let url = URL(string: string)!
            XCTAssertNil(DeepLinkRoute.parse(url), "Expected nil for \(string)")
        }
    }
}
