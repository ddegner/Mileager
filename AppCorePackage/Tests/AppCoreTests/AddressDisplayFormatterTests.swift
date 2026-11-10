import XCTest
@testable import AppCore

final class AddressDisplayFormatterTests: XCTestCase {
    func testReadableAddressRemovesRepeatedReverseGeocodeComponents() {
        let address = "123 Main St, 123 Main St, Brooklyn, 123 Main St, Brooklyn, NY  11201, United States"

        XCTAssertEqual(
            AddressDisplayFormatter.readableAddress(address),
            "123 Main St, Brooklyn, NY 11201"
        )
    }

    func testReadableAddressPreservesDistinctLocalityComponents() {
        let address = "Kendall Square, Cambridge, Massachusetts, United States"

        XCTAssertEqual(
            AddressDisplayFormatter.readableAddress(address),
            "Kendall Square, Cambridge, Massachusetts"
        )
    }

    func testAbbreviatingStreetTypeCompactsFinalWord() {
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("139 Tremont Street"),
            "139 Tremont St"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("1350 Massachusetts Avenue"),
            "1350 Massachusetts Ave"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("Memorial Drive"),
            "Memorial Dr"
        )
    }

    func testAbbreviatingStreetTypeLeavesNonSuffixUsesAlone() {
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("Avenue of the Americas"),
            "Avenue of the Americas"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("Boston Common"),
            "Boston Common"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.abbreviatingStreetType("Street"),
            "Street"
        )
    }

    func testEndpointTextFallsBackToCoordinates() {
        let coordinate = Coordinate(latitude: 40.69006, longitude: -73.99631)

        XCTAssertEqual(
            AddressDisplayFormatter.endpointText(address: " ", coordinate: coordinate),
            "40.69006, -73.99631"
        )
    }

    func testPartsSplitsStreetCityAndState() {
        let parts = AddressDisplayFormatter.parts(of: "22 Example St, Cambridge, MA 02139")

        XCTAssertEqual(parts.primary, "22 Example St")
        XCTAssertEqual(parts.city, "Cambridge")
        XCTAssertEqual(parts.stateCode, "MA")
    }

    func testPartsRecognizesFullStateNamesAndPlaceNames() {
        let poi = AddressDisplayFormatter.parts(of: "Sample Studio, 444 Sample Ave, Somerville, MA 02143")
        XCTAssertEqual(poi.primary, "Sample Studio")
        XCTAssertEqual(poi.city, "Somerville")
        XCTAssertEqual(poi.stateCode, "MA")

        let fullName = AddressDisplayFormatter.parts(of: "Kendall Square, Cambridge, Massachusetts, United States")
        XCTAssertEqual(fullName.primary, "Kendall Square")
        XCTAssertEqual(fullName.city, "Cambridge")
        XCTAssertEqual(fullName.stateCode, "MA")
    }

    func testPartsLeavesCoordinateStringsAlone() {
        let parts = AddressDisplayFormatter.parts(of: "40.69006, -73.99631")

        XCTAssertEqual(parts.primary, "40.69006")
        XCTAssertEqual(parts.city, "-73.99631")
        XCTAssertNil(parts.stateCode)
    }

    func testCompactAddressDropsZipAndHomeState() {
        XCTAssertEqual(
            AddressDisplayFormatter.compactAddress("22 Example St, Cambridge, MA 02139", omittingState: "MA"),
            "22 Example St, Cambridge"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.compactAddress("67 Sample Rd, Newtown, CT 06482", omittingState: "MA"),
            "67 Sample Rd, Newtown, CT"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.compactAddress("William T Morrissey Blvd, Boston, MA", omittingState: "MA"),
            "William T Morrissey Blvd, Boston"
        )
        XCTAssertEqual(
            AddressDisplayFormatter.compactAddress("Boston Common", omittingState: "MA"),
            "Boston Common"
        )
    }

    func testCompactAddressDeduplicatesRepeatedGeocodeComponents() {
        XCTAssertEqual(
            AddressDisplayFormatter.compactAddress(
                "123 Main St, 123 Main St, Brooklyn, 123 Main St, Brooklyn, NY  11201, United States",
                omittingState: "NY"
            ),
            "123 Main St, Brooklyn"
        )
    }
}
