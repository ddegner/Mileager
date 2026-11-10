import AppCore
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class TripAppEntityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(
        classification: TripClassification? = nil,
        notes: String? = nil
    ) -> TripSummary {
        TripSummary(
            id: UUID(),
            createdAt: start,
            updatedAt: start,
            captureSource: "automatic",
            startDate: start,
            endDate: start.addingTimeInterval(3_000),
            startCoordinate: Coordinate(latitude: 40.6890, longitude: -73.9946),
            endCoordinate: Coordinate(latitude: 41.0762, longitude: -73.4735),
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: 42.5),
            routePolyline: nil,
            classification: classification,
            reviewStatus: classification == nil ? .needsReview : .readyToExport,
            businessPurpose: classification == .business ? "Client visit" : nil,
            notes: notes,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
    }

    func testDisplayTitleMatchesRouteLabelFormatter() {
        let trip = summary(classification: .business)
        let entity = TripAppEntity(trip)

        XCTAssertEqual(entity.routeLabel, DriveRouteLabelFormatter.label(for: trip))
        XCTAssertEqual(String(localized: entity.displayRepresentation.title), entity.routeLabel)
    }

    func testSubtitleShowsNeedsReviewForUnclassifiedTrip() throws {
        let entity = TripAppEntity(summary())

        let subtitle = try XCTUnwrap(entity.displayRepresentation.subtitle)
        XCTAssertTrue(String(localized: subtitle).contains("Needs review"))
    }

    func testSubtitleShowsClassificationAndMiles() throws {
        let entity = TripAppEntity(summary(classification: .business))

        let subtitle = String(localized: try XCTUnwrap(entity.displayRepresentation.subtitle))
        XCTAssertTrue(subtitle.contains("Business"))
        XCTAssertTrue(subtitle.contains("42.5"))
    }

    func testTripTypeIncludesDriveSynonym() {
        let synonyms = TripAppEntity.typeDisplayRepresentation.synonyms.map {
            String(localized: $0)
        }

        XCTAssertTrue(synonyms.contains("Drive"))
    }

    func testDistanceTextRoundsToOneFractionDigit() {
        XCTAssertEqual(
            TripAppEntity.distanceText(meters: DistanceConversion.meters(fromMiles: 106.218039), unit: .miles),
            "106.2 mi"
        )
        XCTAssertEqual(
            TripAppEntity.distanceText(meters: DistanceConversion.meters(fromMiles: 42.0), unit: .miles),
            "42 mi"
        )
        XCTAssertEqual(
            TripAppEntity.distanceText(meters: 8_000, unit: .kilometers),
            "8 km"
        )
    }

    func testDurationTextUsesHumanReadableUnits() {
        XCTAssertEqual(TripAppEntity.durationText(seconds: 59), "59 seconds")
        XCTAssertEqual(TripAppEntity.durationText(seconds: 60), "1 minute")
        XCTAssertEqual(TripAppEntity.durationText(seconds: 3_900), "1 hour, 5 minutes")
    }

    func testEndpointTextDeduplicatesLegacyGeocodedAddress() {
        let cleaned = TripAppEntity.endpointText(
            components: nil,
            rawAddress: "123 Berlin Rd, 123 Berlin Rd, Cromwell, 123 Berlin Rd, Cromwell, CT 06416",
            fallback: "Cromwell, CT"
        )
        XCTAssertEqual(cleaned, "123 Berlin Rd, Cromwell, CT 06416")
    }

    func testEndpointTextPrefersStructuredComponents() {
        let components = TripEndpointAddressComponents(
            streetNumber: "24",
            streetName: "Example St",
            city: "Cambridge",
            state: "MA"
        )
        let text = TripAppEntity.endpointText(
            components: components,
            rawAddress: "24 Example St, 24 Example St, Cambridge",
            fallback: "Cambridge, MA"
        )
        XCTAssertEqual(text, "24 Example St, Cambridge")
    }

    func testAttributeSetCarriesSearchableFields() throws {
        let trip = summary(classification: .business, notes: "Toll receipt in glovebox")
        let entity = TripAppEntity(trip)

        let attributes = entity.attributeSet
        XCTAssertEqual(attributes.title, entity.routeLabel)
        XCTAssertEqual(attributes.startDate, trip.startDate)
        XCTAssertEqual(attributes.endDate, trip.endDate)
        XCTAssertEqual(entity.duration.converted(to: .seconds).value, 3_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(attributes.duration).doubleValue, 3_000, accuracy: 0.001)
        XCTAssertEqual(attributes.textContent, "Toll receipt in glovebox")
        let description = try XCTUnwrap(attributes.contentDescription)
        XCTAssertTrue(description.contains("145 Court St, Brooklyn, NY"))
        XCTAssertTrue(description.contains("9 Pine St, Darien, CT"))
        XCTAssertTrue(description.contains(TripAppEntity.durationText(seconds: 3_000)))
        XCTAssertTrue(description.contains("Client visit"))
        let keywords = try XCTUnwrap(attributes.keywords)
        XCTAssertTrue(keywords.contains("Business"))
        XCTAssertEqual(attributes.latitude?.doubleValue, 40.6890)
    }
}
