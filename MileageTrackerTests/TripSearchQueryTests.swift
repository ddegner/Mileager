import AppCore
import XCTest
@testable import MileageTracker

final class TripSearchQueryTests: XCTestCase {
    func testSearchMatchesWordsAcrossPlacesPurposeAndNotesIgnoringCaseAndAccents() {
        var trip = makeTrip(startDate: Date(), miles: 4, classification: .business, purpose: "Portrait session")
        trip.startAddress = "Café de Flore"
        trip.endAddress = "Client studio"
        trip.notes = "Bring lighting equipment"

        XCTAssertTrue(TripSearchQuery("  CAFE\nportrait lighting  ").matches(trip))
        XCTAssertTrue(TripSearchQuery("STUDIO").matches(trip))
        XCTAssertFalse(TripSearchQuery("cafe airport").matches(trip))
        XCTAssertTrue(TripSearchQuery(" \n ").matches(trip))
    }

    func testSearchFindsAnIntermediatePlaceInAMergedTrip() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.legs = [TripLeg(
            captureSource: "manual",
            startDate: trip.startDate,
            endDate: trip.endDate,
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "Camera rental counter",
            endAddress: "Client",
            distanceMeters: 100,
            routePolyline: nil
        )]
        XCTAssertTrue(TripSearchQuery("camera").matches(trip))
        XCTAssertFalse(TripSearchQuery("airport").matches(trip))
    }

    func testSearchHandlesPunctuationInNamesAndPastedAddresses() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.startAddress = "O’Neill’s Café, 123 Main St., Montréal"
        trip.endAddress = "Jean-Luc’s studio"

        for text in ["oneills cafe", "O'Neill's", "jean luc", "JEAN–LUC’S", "123, Main St Montreal", "ＣＡＦＥ"] {
            XCTAssertTrue(TripSearchQuery(text).matches(trip), text)
        }
        XCTAssertFalse(TripSearchQuery("oneills airport").matches(trip))
        XCTAssertFalse(TripSearchQuery("124 Main").matches(trip))
        XCTAssertTrue(TripSearchQuery("stud").matches(trip), "Unquoted partial words still match.")
    }

    func testQuotedPhrasesRequireConsecutiveWholeWordsInOneField() {
        var trip = makeTrip(startDate: Date(), miles: 4, purpose: "Portrait session")
        trip.startAddress = "North Market, Columbus"
        trip.endAddress = "Client studio"
        trip.notes = "Bring the lighting kit"

        for text in ["\"north market\" portrait", "“NORTH   MARKET” lighting", "\"portrait session\" \"lighting kit\"", "\"north market"] {
            XCTAssertTrue(TripSearchQuery(text).matches(trip), text)
        }
        for text in ["\"market north\"", "\"north studio\"", "\"market colum\"", "\"lighting kit\" airport"] {
            XCTAssertFalse(TripSearchQuery(text).matches(trip), text)
        }
        trip.startAddress = "Northside Marketplace"
        XCTAssertFalse(TripSearchQuery("\"north market\"").matches(trip))
        XCTAssertTrue(TripSearchQuery("north market").matches(trip))
    }

    func testPhrasesNormalizeApostrophesDashesAndLineBreaks() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.notes = "Meeting at Jean–Luc’s\n  Café"
        XCTAssertTrue(TripSearchQuery("\"jean lucs cafe\"").matches(trip))
        XCTAssertTrue(TripSearchQuery("\"Jean-Luc's Café\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"jean cafe\"").matches(trip))
    }

    func testSearchIncludesStructuredAddressesAndMergedLegAddresses() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.startAddress = "Client"
        trip.startAddressComponents = TripEndpointAddressComponents(
            streetNumber: "123", streetName: "Main Street", neighborhood: "Mile End",
            city: "Montréal", state: "Québec", country: "Canada", countryCode: "CA"
        )
        trip.endAddressComponents = TripEndpointAddressComponents(city: "Boston")
        var leg = TripLeg(
            captureSource: "manual", startDate: trip.startDate, endDate: trip.endDate,
            startCoordinate: nil, endCoordinate: nil, startAddress: "Rental counter", endAddress: "Client",
            distanceMeters: 100, routePolyline: nil
        )
        leg.startAddressComponents = TripEndpointAddressComponents(city: "Somerville")
        leg.endAddressComponents = TripEndpointAddressComponents(neighborhood: "Davis Square")
        trip.legs = [leg]

        XCTAssertTrue(TripSearchQuery("\"123 main street\" \"mile end\" montreal quebec canada").matches(trip))
        XCTAssertTrue(TripSearchQuery("boston somerville \"davis square\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"boston somerville\"").matches(trip), "A phrase cannot cross endpoints.")
        XCTAssertFalse(TripSearchQuery("airport").matches(trip))
    }

    func testSearchPreservesNonLatinTextAndCombiningMarks() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.startAddress = "東京都 新宿区"
        trip.endAddress = "किरण स्टूडियो"
        XCTAssertTrue(TripSearchQuery("東京 新宿").matches(trip))
        XCTAssertTrue(TripSearchQuery("\"東京都 新宿区\"").matches(trip))
        XCTAssertTrue(TripSearchQuery("किरण").matches(trip))
        XCTAssertFalse(TripSearchQuery("大阪").matches(trip))
    }

    func testStreetAbbreviationsMatchInBothDirectionsAndQuotedPhrases() {
        var trip = makeTrip(startDate: Date(), miles: 4, purpose: "Portrait session")
        trip.startAddress = "123 Main St., Boston, MA"
        trip.endAddress = "5 Elm Road, Cambridge, MA"
        for query in ["main street", "\"123 main street\" portrait", "elm rd", "\"5 elm rd.\"", "street road"] {
            XCTAssertTrue(TripSearchQuery(query).matches(trip), query)
        }
        XCTAssertFalse(TripSearchQuery("\"124 main street\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"street main\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"boston 5 elm rd\"").matches(trip))
    }

    func testStreetSuffixesWorkBeforeDirectionsUnitsAndUnseparatedCities() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        let examples = [
            ("1600 Pennsylvania Ave NW, Washington, DC", "\"pennsylvania avenue nw\""),
            ("450 W 33rd St New York NY", "\"33rd street new york\""),
            ("1 Memorial Dr, Cambridge, MA", "\"memorial drive\""),
            ("8 Sunset Boulevard, Los Angeles, CA", "\"sunset blvd\""),
            ("12 Main Ln Apt 4, Boston, MA", "\"main lane apt 4\""),
            ("12 Old Court Rd, Boston, MA", "\"old court road\"")
        ]
        for (address, query) in examples {
            trip.startAddress = address
            XCTAssertTrue(TripSearchQuery(query).matches(trip), "\(query) in \(address)")
        }
    }

    func testAddressAliasesDoNotRewriteNamesOrWordsInsideNotesAndPurposes() {
        var trip = makeTrip(startDate: Date(), miles: 4, purpose: "Meet Dr Smith")
        trip.startAddress = "St. Paul Cathedral"
        trip.endAddress = "Dr. Martin Luther King Memorial"
        trip.notes = "Main St portrait session; Oxford studio"
        for query in ["street", "drive", "road", "\"main street\"", "\"drive smith\""] {
            XCTAssertFalse(TripSearchQuery(query).matches(trip), query)
        }
        XCTAssertTrue(TripSearchQuery("\"st paul\" \"dr smith\" \"main st\"").matches(trip))

        trip.startAddress = "5 St. James St., London"
        XCTAssertTrue(TripSearchQuery("\"st james street\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"street james street\"").matches(trip))
        trip.startAddress = "123 Dr. Martin Luther King Blvd, Boston, CT"
        XCTAssertTrue(TripSearchQuery("\"dr martin luther king boulevard\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"drive martin\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("court").matches(trip), "The state after a street is not a suffix.")
        trip.startAddress = "123 Main St Hartford CT"
        XCTAssertTrue(TripSearchQuery("\"main street hartford\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("court").matches(trip))
    }

    func testAliasesMatchWholeAddressWordsWithoutExpandingWordFragments() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.startAddress = "Oxford, Studio"
        XCTAssertFalse(TripSearchQuery("road").matches(trip))
        XCTAssertFalse(TripSearchQuery("street").matches(trip))
        XCTAssertTrue(TripSearchQuery("oxf stud").matches(trip), "Ordinary partial-word search remains available.")
        trip.startAddress = "123 Main Starlight"
        XCTAssertFalse(TripSearchQuery("\"main street\"").matches(trip))
    }

    func testAbbreviationsSearchStructuredAndIntermediateAddresses() {
        var trip = makeTrip(startDate: Date(), miles: 4)
        trip.startAddressComponents = TripEndpointAddressComponents(
            streetNumber: "123", streetName: "Main St", city: "St Paul"
        )
        var leg = trip.legs[0]
        leg.startAddress = "18 Elm Rd"
        leg.endAddressComponents = TripEndpointAddressComponents(streetName: "Memorial Dr")
        trip.legs = [leg]
        trip.connectors = [TripLegConnector(
            fromLegID: leg.id, toLegID: UUID(),
            startCoordinate: Coordinate(latitude: 42.36, longitude: -71.06),
            endCoordinate: Coordinate(latitude: 42.37, longitude: -71.07),
            startAddress: "9 Garden Ct", endAddress: "4 Maple Pl", distanceMeters: 100
        )]
        XCTAssertTrue(TripSearchQuery("\"main street\" \"elm road\" \"memorial drive\" \"garden court\" \"maple place\"").matches(trip))
        XCTAssertTrue(TripSearchQuery("\"main street st paul\"").matches(trip))
        XCTAssertFalse(TripSearchQuery("\"street paul\"").matches(trip))
    }

    func testEmptyQuotesAndSeparatorsDoNotBecomeRequiredSearchTerms() {
        let trip = makeTrip(startDate: Date(), miles: 4, purpose: "Portrait session")
        XCTAssertTrue(TripSearchQuery("\"\" portrait — ").matches(trip))
        for text in ["\"", "“”", " , — \n "] {
            XCTAssertTrue(TripSearchQuery(text).isEmpty, text)
            XCTAssertTrue(TripSearchQuery(text).matches(trip), text)
        }
    }

    func testSearchKeepsScopeVehicleClassificationAndSort() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let vehicle = UUID()
        var short = makeTrip(startDate: date, miles: 2, classification: .business, purpose: "Portrait", vehicleID: vehicle)
        short.endAddress = "Studio"
        var long = short
        long.id = UUID()
        long.distanceMeters *= 3
        var personal = short
        personal.id = UUID()
        personal.classification = .personal
        var otherVehicle = short
        otherVehicle.id = UUID()
        otherVehicle.vehicleID = UUID()
        var otherMonth = short
        otherMonth.id = UUID()
        otherMonth.startDate = date.addingTimeInterval(90 * 86_400)

        let result = DriveListDerivation(
            trips: [short, otherMonth, otherVehicle, personal, long],
            scope: .month(date),
            sortOption: .longestDistance,
            tripFilter: .business,
            vehicleFilter: .vehicle(vehicle),
            primaryVehicleID: vehicle,
            searchText: "studio portrait"
        )
        XCTAssertEqual(result.visibleOrder, [long.id, short.id])
    }

    func testSearchAndFiltersDoNotHideTheScopedUnresolvedCount() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let business = makeTrip(startDate: date, miles: 5, classification: .business, purpose: "Portrait")
        let unresolved = makeTrip(startDate: date, miles: 2)

        func derive(searchText: String = "", filter: TripClassificationFilter = .all) -> DriveListDerivation {
            DriveListDerivation(
                trips: [business, unresolved],
                scope: .month(date),
                sortOption: .newestFirst,
                tripFilter: filter,
                vehicleFilter: .all,
                primaryVehicleID: nil,
                searchText: searchText
            )
        }

        let search = derive(searchText: "Portrait")
        XCTAssertEqual(search.visibleOrder, [business.id])
        XCTAssertEqual(derive(filter: .business).unresolvedCount, 1)
    }

    func testSearchAllTripsDoesNotChangeTheMailboxAfterQueryIsCleared() {
        let mailbox = DriveListScope.month(Date())
        XCTAssertEqual(DriveSearchScope.currentMailbox.listScope(mailbox: mailbox, query: TripSearchQuery("studio")), mailbox)
        XCTAssertEqual(DriveSearchScope.allTrips.listScope(mailbox: mailbox, query: TripSearchQuery("studio")), .allTrips)
        XCTAssertEqual(DriveSearchScope.allTrips.listScope(mailbox: mailbox, query: TripSearchQuery("  ")), mailbox)
    }
}
