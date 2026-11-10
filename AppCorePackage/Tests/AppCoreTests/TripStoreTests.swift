import CoreData
import PDFKit
import XCTest
@testable import AppCore
@testable import AppCorePersistence

final class TripStoreTests: XCTestCase {
    func testEncodedPolylineDecodeRoundTrip() throws {
        let coordinates = [
            Coordinate(latitude: 40.71278, longitude: -74.00597),
            Coordinate(latitude: 40.72012, longitude: -73.99854),
            Coordinate(latitude: 40.73401, longitude: -73.99122)
        ]

        let encoded = EncodedPolyline.encode(coordinates)
        let decoded = try XCTUnwrap(EncodedPolyline.decode(encoded))

        XCTAssertEqual(decoded.count, coordinates.count)
        for (actual, expected) in zip(decoded, coordinates) {
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.00001)
        }
    }

    func testEncodeDecodeSegmentsRoundTrip() throws {
        let first = [
            Coordinate(latitude: 40.71278, longitude: -74.00597),
            Coordinate(latitude: 40.72012, longitude: -73.99854)
        ]
        let second = [
            Coordinate(latitude: 41.88183, longitude: -87.62318),
            Coordinate(latitude: 41.89020, longitude: -87.62400),
            Coordinate(latitude: 41.90000, longitude: -87.63000)
        ]

        let encoded = EncodedPolyline.encodeSegments([first, second])
        let decoded = try XCTUnwrap(EncodedPolyline.decodeSegments(encoded))

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].count, first.count)
        XCTAssertEqual(decoded[1].count, second.count)
        XCTAssertEqual(decoded[0][0].latitude, first[0].latitude, accuracy: 0.00001)
        XCTAssertEqual(decoded[1][2].longitude, second[2].longitude, accuracy: 0.00001)
    }

    func testDecodeSegmentsAcceptsLegacySingle() throws {
        let coordinates = [
            Coordinate(latitude: 40.71278, longitude: -74.00597),
            Coordinate(latitude: 40.72012, longitude: -73.99854)
        ]
        let encoded = EncodedPolyline.encode(coordinates)

        let decoded = try XCTUnwrap(EncodedPolyline.decodeSegments(encoded))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].count, coordinates.count)
        XCTAssertEqual(decoded[0][1].latitude, coordinates[1].latitude, accuracy: 0.00001)
    }

    func testRouteDistanceCountsPlausibleLongGap() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(180), latitude: 40.05, longitude: -73.0, horizontalAccuracy: 10)
        ]

        let distance = DistanceCalculator.routeDistanceMeters(samples: samples)

        XCTAssertGreaterThan(distance, 5_000)
    }

    func testRouteDistanceDropsImpossibleHighSpeedSegment() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -73.0, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(20), latitude: 40.05, longitude: -73.0, horizontalAccuracy: 10)
        ]

        let distance = DistanceCalculator.routeDistanceMeters(samples: samples)

        XCTAssertEqual(distance, 0, accuracy: 0.01)
    }

    func testRouteSimplifierUsesLocalMetersAtHighLatitude() {
        let points = [
            Coordinate(latitude: 60.0, longitude: 0.0),
            Coordinate(latitude: 60.05, longitude: 0.00040),
            Coordinate(latitude: 60.1, longitude: 0.0)
        ]

        let simplified = RouteSimplifier.rdp(points, toleranceMeters: 30)

        XCTAssertEqual(simplified, [points[0], points[2]])
    }

    @MainActor
    func testManualTripReviewAndReport() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Home",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10)
        ))

        let reviewed = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .business, businessPurpose: "Client meeting")
        )

        XCTAssertEqual(reviewed.classification, .business)
        XCTAssertEqual(reviewed.reviewStatus, .readyToExport)

        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: start, odometerMiles: 10_000))
        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: start.addingTimeInterval(86_400), odometerMiles: 10_025))

        let generator = ReportGenerator()
        let report = try generator.makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: try store.fetchOdometerCheckpoints(),
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(86_400),
            rate: .default,
            formatting: .enUS
        )

        XCTAssertEqual(report.businessMiles, 10, accuracy: 0.01)
        XCTAssertTrue(report.csvText.contains("Client meeting"))
        XCTAssertFalse(report.pdfData.isEmpty)

        let pdfText = try pdfText(for: report.pdfData)
        XCTAssertTrue(pdfText.contains("Mileage Report"))
        XCTAssertTrue(pdfText.contains("Business trips"))
        XCTAssertTrue(pdfText.contains("Home → Client"))
        XCTAssertTrue(pdfText.contains("meeting"))
        XCTAssertTrue(pdfText.contains("Total reimbursement"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertFalse(pdfText.contains("Needs Attention"))
    }

    func testFeeLedgerCreateUpdateDeleteRecomputesTripTotals() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10)
        ))

        let toll = try store.addFee(
            tripID: trip.id,
            category: .toll,
            amount: 4.25,
            occurredAt: start.addingTimeInterval(300),
            label: "Bridge",
            source: .manual
        )
        _ = try store.addFee(
            tripID: trip.id,
            category: .parking,
            amount: 12,
            occurredAt: start.addingTimeInterval(1_000),
            label: "Garage",
            source: .preset,
            presetID: UUID()
        )
        _ = try store.addFee(
            tripID: trip.id,
            category: .toll,
            amount: 2,
            occurredAt: start.addingTimeInterval(1_100),
            label: "Tunnel",
            source: .liveActivity
        )

        var updatedTrip = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(updatedTrip.tollsAmount, 6.25, accuracy: 0.001)
        XCTAssertEqual(updatedTrip.parkingAmount, 12, accuracy: 0.001)
        XCTAssertEqual(try store.fetchFees(tripID: trip.id).map(\.source), [.manual, .preset, .liveActivity])

        var editedToll = toll
        editedToll.amount = 5
        _ = try store.updateFee(editedToll)
        updatedTrip = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(updatedTrip.tollsAmount, 7, accuracy: 0.001)

        try store.deleteFee(id: editedToll.id)
        updatedTrip = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(updatedTrip.tollsAmount, 2, accuracy: 0.001)
        XCTAssertEqual(updatedTrip.parkingAmount, 12, accuracy: 0.001)

        XCTAssertThrowsError(try store.addFee(
            tripID: trip.id,
            category: .parking,
            amount: -.leastNonzeroMagnitude
        ))
        XCTAssertThrowsError(try store.addFee(
            tripID: trip.id,
            category: .parking,
            amount: .infinity
        ))
    }

    func testSaveCompletedTripAppliesDraftReviewFieldsAndFees() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.01, longitude: -73, horizontalAccuracy: 10)
        ]
        let toll = TripFee(
            tripID: nil,
            category: .toll,
            amount: 4.5,
            occurredAt: start.addingTimeInterval(30),
            label: "Bridge"
        )
        let parking = TripFee(
            tripID: nil,
            category: .parking,
            amount: 16,
            occurredAt: start.addingTimeInterval(90),
            label: "Garage",
            source: .liveActivity
        )

        let saved = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples),
            classification: .business,
            businessPurpose: "Client visit",
            fees: [toll, parking],
            notes: "Parked on Atlantic Ave"
        ))

        XCTAssertEqual(saved.classification, .business)
        XCTAssertEqual(saved.businessPurpose, "Client visit")
        XCTAssertEqual(saved.notes, "Parked on Atlantic Ave")
        XCTAssertEqual(saved.reviewStatus, .readyToExport)
        XCTAssertEqual(saved.tollsAmount, 4.5, accuracy: 0.001)
        XCTAssertEqual(saved.parkingAmount, 16, accuracy: 0.001)

        let fees = try store.fetchFees(tripID: saved.id)
        XCTAssertEqual(fees.map(\.tripID), [saved.id, saved.id])
        XCTAssertEqual(fees.map(\.category), [.toll, .parking])
    }

    func testDuplicateTripReversedSwapsEndpointsAndReversesRoute() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(1_800)
        let routeCoordinates = [
            Coordinate(latitude: 40.73186, longitude: -74.00459),
            Coordinate(latitude: 40.73800, longitude: -73.99700),
            Coordinate(latitude: 40.74844, longitude: -73.98565)
        ]
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: end,
            startCoordinate: routeCoordinates.first,
            endCoordinate: routeCoordinates.last,
            startAddress: "89 Bedford St, New York, NY",
            endAddress: "350 5th Ave, New York, NY",
            distanceMeters: DistanceConversion.meters(fromMiles: 2),
            routePolyline: EncodedPolyline.encode(routeCoordinates),
            classification: .business,
            businessPurpose: "Client meeting",
            notes: "Stopped for gas on 6th Ave"
        ))
        _ = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "89 Bedford St, New York, NY",
            endAddress: "350 5th Ave, New York, NY",
            startAddressComponents: TripEndpointAddressComponents(
                streetNumber: "89", streetName: "Bedford St", city: "New York", state: "NY"
            ),
            endAddressComponents: TripEndpointAddressComponents(
                streetNumber: "350", streetName: "5th Ave", city: "New York", state: "NY"
            )
        )

        let returnTrip = try store.duplicateTrip(id: trip.id, reversed: true)

        XCTAssertEqual(returnTrip.startDate.timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(returnTrip.durationSeconds, 1_800, accuracy: 0.001)
        XCTAssertEqual(returnTrip.startAddress, "350 5th Ave, New York, NY")
        XCTAssertEqual(returnTrip.endAddress, "89 Bedford St, New York, NY")
        XCTAssertEqual(returnTrip.startAddressComponents?.streetNumber, "350")
        XCTAssertEqual(returnTrip.startAddressComponents?.streetName, "5th Ave")
        XCTAssertEqual(returnTrip.endAddressComponents?.streetNumber, "89")
        XCTAssertEqual(returnTrip.endAddressComponents?.streetName, "Bedford St")

        let startCoordinate = try XCTUnwrap(returnTrip.startCoordinate)
        let endCoordinate = try XCTUnwrap(returnTrip.endCoordinate)
        XCTAssertEqual(startCoordinate.latitude, 40.74844, accuracy: 0.00001)
        XCTAssertEqual(startCoordinate.longitude, -73.98565, accuracy: 0.00001)
        XCTAssertEqual(endCoordinate.latitude, 40.73186, accuracy: 0.00001)
        XCTAssertEqual(endCoordinate.longitude, -74.00459, accuracy: 0.00001)

        XCTAssertEqual(returnTrip.distanceMeters, DistanceConversion.meters(fromMiles: 2), accuracy: 0.01)
        XCTAssertEqual(returnTrip.classification, .business)
        XCTAssertEqual(returnTrip.businessPurpose, "Client meeting")
        XCTAssertEqual(returnTrip.notes, "Stopped for gas on 6th Ave")

        let reversedRoute = try XCTUnwrap(EncodedPolyline.decode(try XCTUnwrap(returnTrip.routePolyline)))
        XCTAssertEqual(reversedRoute.count, routeCoordinates.count)
        for (actual, expected) in zip(reversedRoute, routeCoordinates.reversed()) {
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.00001)
        }
    }

    func testDuplicateTripReversedReversesMultiSegmentPolyline() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSegment = [
            Coordinate(latitude: 42.35866, longitude: -71.05674),
            Coordinate(latitude: 42.36600, longitude: -71.06200)
        ]
        let secondSegment = [
            Coordinate(latitude: 42.37300, longitude: -71.11000),
            Coordinate(latitude: 42.37700, longitude: -71.11600),
            Coordinate(latitude: 42.38100, longitude: -71.12500)
        ]
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(2_400),
            startCoordinate: firstSegment.first,
            endCoordinate: secondSegment.last,
            startAddress: "1 City Hall Square, Boston, MA",
            endAddress: "350 Massachusetts Ave, Cambridge, MA",
            distanceMeters: DistanceConversion.meters(fromMiles: 5),
            routePolyline: EncodedPolyline.encodeSegments([firstSegment, secondSegment])
        ))

        let returnTrip = try store.duplicateTrip(id: trip.id, reversed: true)

        let segments = try XCTUnwrap(EncodedPolyline.decodeSegments(try XCTUnwrap(returnTrip.routePolyline)))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, secondSegment.count)
        XCTAssertEqual(segments[1].count, firstSegment.count)
        for (actual, expected) in zip(segments[0], secondSegment.reversed()) {
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.00001)
        }
        for (actual, expected) in zip(segments[1], firstSegment.reversed()) {
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.00001)
        }
    }

    func testDuplicateTripWithoutReversedCopiesVerbatim() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let routeCoordinates = [
            Coordinate(latitude: 40.73186, longitude: -74.00459),
            Coordinate(latitude: 40.74844, longitude: -73.98565)
        ]
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: routeCoordinates.first,
            endCoordinate: routeCoordinates.last,
            startAddress: "89 Bedford St, New York, NY",
            endAddress: "350 5th Ave, New York, NY",
            distanceMeters: DistanceConversion.meters(fromMiles: 2),
            routePolyline: EncodedPolyline.encode(routeCoordinates)
        ))

        let copy = try store.duplicateTrip(id: trip.id)

        XCTAssertEqual(copy.startAddress, "89 Bedford St, New York, NY")
        XCTAssertEqual(copy.endAddress, "350 5th Ave, New York, NY")
        XCTAssertEqual(copy.routePolyline, trip.routePolyline)
        XCTAssertEqual(copy.durationSeconds, 1_800, accuracy: 0.001)
        let startCoordinate = try XCTUnwrap(copy.startCoordinate)
        XCTAssertEqual(startCoordinate.latitude, 40.73186, accuracy: 0.00001)
        XCTAssertEqual(startCoordinate.longitude, -74.00459, accuracy: 0.00001)
    }

    @MainActor
    func testReportIncludesOnlyTripsInsideSelectedMonth() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let calendar = Calendar(identifier: .gregorian)
        let januaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let februaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let januaryDrive = januaryStart.addingTimeInterval(12 * 60 * 60)
        let februaryDrive = februaryStart.addingTimeInterval(12 * 60 * 60)
        let monthBoundaryDrive = februaryStart.addingTimeInterval(-10 * 60)

        let included = try store.createManualTrip(ManualTripInput(
            startDate: januaryDrive,
            endDate: januaryDrive.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 8),
            classification: .business,
            businessPurpose: "January client visit"
        ))

        let boundaryIncluded = try store.createManualTrip(ManualTripInput(
            startDate: monthBoundaryDrive,
            endDate: monthBoundaryDrive.addingTimeInterval(30 * 60),
            startAddress: "Airport",
            endAddress: "Hotel",
            distanceMeters: DistanceConversion.meters(fromMiles: 4),
            classification: .business,
            businessPurpose: "Month boundary client visit"
        ))

        _ = try store.createManualTrip(ManualTripInput(
            startDate: februaryDrive,
            endDate: februaryDrive.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Vendor",
            distanceMeters: DistanceConversion.meters(fromMiles: 12),
            classification: .business,
            businessPurpose: "February vendor visit"
        ))

        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: januaryStart,
            endDate: februaryStart.addingTimeInterval(-0.001),
            rate: .default,
            formatting: .enUS
        )

        XCTAssertEqual(report.includedTripIDs, [included.id, boundaryIncluded.id])
        XCTAssertEqual(report.businessMiles, 12, accuracy: 0.01)
        XCTAssertTrue(report.csvText.contains("January client visit"))
        XCTAssertTrue(report.csvText.contains("Month boundary client visit"))
        XCTAssertFalse(report.csvText.contains("February vendor visit"))

        let pdfText = try pdfText(for: report.pdfData)
        XCTAssertTrue(pdfText.contains("January client visit"))
        XCTAssertTrue(pdfText.contains("Month boundary"))
        XCTAssertTrue(pdfText.contains("client visit"))
        XCTAssertFalse(pdfText.contains("February vendor visit"))
    }

    @MainActor
    func testReportBracketsOdometerCheckpointsAroundPeriod() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let calendar = Calendar(identifier: .gregorian)
        let januaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let februaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let marchStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        let tripStart = januaryStart.addingTimeInterval(12 * 60 * 60)

        _ = try store.createManualTrip(ManualTripInput(
            startDate: tripStart,
            endDate: tripStart.addingTimeInterval(1_800),
            startAddress: "139 Tremont St, Boston",
            endAddress: "22 Example St, Cambridge",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "January client visit"
        ))
        // Twice-a-year cadence: one reading at the period start, the next far
        // beyond the period end. The January report must interpolate.
        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: januaryStart, odometerMiles: 10_000))
        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: marchStart, odometerMiles: 10_600))

        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: try store.fetchOdometerCheckpoints(),
            startDate: januaryStart,
            endDate: februaryStart.addingTimeInterval(-0.001),
            rate: .default,
            formatting: .enUS
        )

        XCTAssertFalse(report.csvText.contains("Odometer"), report.csvText)

        let pdfText = try pdfText(for: report.pdfData)
        XCTAssertTrue(pdfText.contains("business use"))
        XCTAssertTrue(pdfText.contains("Estimated from readings"))
    }

    @MainActor
    func testReportShowsSingleOdometerReadingAndOmitsRowsWithoutCheckpoints() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let calendar = Calendar(identifier: .gregorian)
        let januaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let februaryStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let tripStart = januaryStart.addingTimeInterval(12 * 60 * 60)

        _ = try store.createManualTrip(ManualTripInput(
            startDate: tripStart,
            endDate: tripStart.addingTimeInterval(1_800),
            startAddress: "139 Tremont St, Boston",
            endAddress: "22 Example St, Cambridge",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "January client visit"
        ))
        let generator = ReportGenerator()

        let emptyReport = try generator.makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: januaryStart,
            endDate: februaryStart.addingTimeInterval(-0.001),
            rate: .default,
            formatting: .enUS
        )
        XCTAssertFalse(emptyReport.csvText.contains("Odometer"))

        _ = try store.addOdometerCheckpoint(OdometerCheckpoint(date: januaryStart.addingTimeInterval(14 * 86_400), odometerMiles: 10_000))

        let report = try generator.makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: try store.fetchOdometerCheckpoints(),
            startDate: januaryStart,
            endDate: februaryStart.addingTimeInterval(-0.001),
            rate: .default,
            formatting: .enUS
        )

        XCTAssertFalse(report.csvText.contains("Odometer"), report.csvText)
        XCTAssertTrue(try pdfText(for: report.pdfData).contains("Odometer"))
    }

    @MainActor
    func testDeleteOdometerCheckpointRemovesReading() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let mistaken = try store.addOdometerCheckpoint(OdometerCheckpoint(date: start, odometerMiles: 100_000))
        let keeper = try store.addOdometerCheckpoint(OdometerCheckpoint(date: start.addingTimeInterval(86_400), odometerMiles: 10_050))

        try store.deleteOdometerCheckpoint(id: mistaken.id)

        XCTAssertEqual(try store.fetchOdometerCheckpoints(), [keeper])
    }

    @MainActor
    func testDeleteOdometerCheckpointThrowsForUnknownID() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)

        XCTAssertThrowsError(try store.deleteOdometerCheckpoint(id: UUID())) { error in
            XCTAssertEqual(error as? TripStoreError, .odometerCheckpointNotFound)
        }
    }

    @MainActor
    func testMonthlyReportExportsOnlyBusinessTripsAndReimbursementTotals() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let business = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "Client install"
        ))
        let reimbursable = try store.updateReview(
            tripID: business.id,
            update: ReviewUpdate(tollsAmount: 2.50, parkingAmount: 4.00)
        )

        _ = try store.createManualTrip(ManualTripInput(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(5_400),
            startAddress: "Home",
            endAddress: "Gym",
            distanceMeters: DistanceConversion.meters(fromMiles: 5),
            classification: .personal,
            notes: "Personal errand"
        ))

        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(7_200),
            rate: MileageRate(amountPerUnit: 0.725, unit: .miles),
            formatting: .enUS
        )

        XCTAssertEqual(report.includedTripIDs, [reimbursable.id])
        XCTAssertEqual(report.businessMiles, 10, accuracy: 0.01)
        XCTAssertEqual(report.businessValue, 7.25, accuracy: 0.01)
        XCTAssertTrue(report.csvText.contains("Client install"))
        XCTAssertTrue(report.csvText.contains(",0.725,USD,7.25,2.50,4.00,13.75,"), report.csvText)
        XCTAssertFalse(report.csvText.contains("Gym"))
        XCTAssertFalse(report.csvText.contains("Personal errand"))

        let pdfText = try pdfText(for: report.pdfData)
        XCTAssertTrue(pdfText.contains("Client install"))
        XCTAssertTrue(pdfText.contains("Mileage $7.25"))
        XCTAssertTrue(pdfText.contains("+$2.50 tolls"))
        XCTAssertTrue(pdfText.contains("+$4.00 parking"))
        XCTAssertTrue(pdfText.contains("$13.75"))
        XCTAssertFalse(pdfText.contains("Gym"))
        XCTAssertFalse(pdfText.contains("Personal errand"))
    }

    @MainActor
    func testMonthlyReportPDFKeepsLongRouteAndPurposeTextSelectable() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Very Long Shared Workspace Name, Kendall Square, Cambridge, Massachusetts",
            endAddress: "Long Client Destination Name, Financial District, Boston, Massachusetts",
            distanceMeters: DistanceConversion.meters(fromMiles: 6.6),
            classification: .business,
            businessPurpose: "Long note to verify row clipping and stable table layout without overlapping neighboring rows"
        ))

        let report = try ReportGenerator().makeReport(
            trips: [trip],
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(1_000),
            rate: .default,
            formatting: .enUS
        )
        let pdfText = try pdfText(for: report.pdfData)

        // Compact route form keeps the place name and city; the intermediate
        // neighborhood components stay in the CSV and trip receipt instead.
        // PDFKit extracts text by visual line, so multi-line cells interleave
        // with neighbors — assert fragments that fit within one wrapped line.
        XCTAssertTrue(pdfText.contains("Very Long Shared Workspace"))
        XCTAssertTrue(pdfText.contains("Cambridge"))
        XCTAssertTrue(pdfText.contains("Long Client Destination"))
        XCTAssertTrue(pdfText.contains("Boston"))
        XCTAssertTrue(pdfText.contains("Long note to verify"))
        XCTAssertTrue(pdfText.contains("row clipping"))
        XCTAssertTrue(pdfText.contains("neighboring rows"))
        XCTAssertFalse(pdfText.contains("..."))
        XCTAssertFalse(pdfText.contains("…"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertFalse(pdfText.contains("Needs Attention"))
    }

    @MainActor
    func testReportUsesExplicitMileageRateForValues() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "Client visit"
        ))

        let report = try ReportGenerator().makeReport(
            trips: [trip],
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(3_600),
            rate: MileageRate(amountPerUnit: 0.80, unit: .miles),
            formatting: .enUS
        )

        XCTAssertEqual(report.businessMiles, 10, accuracy: 0.01)
        XCTAssertEqual(report.businessValue, 8, accuracy: 0.01)
        XCTAssertEqual(report.rateCentsPerMile, 80, accuracy: 0.001)
        XCTAssertTrue(report.csvText.contains(",0.800,USD,8.00,"), report.csvText)

        let pdfText = try pdfText(for: report.pdfData)
        XCTAssertTrue(pdfText.contains("$8.00"))
        XCTAssertTrue(pdfText.contains("$0.800/mi"))
    }

    @MainActor
    func testBusinessTripPDFIncludesSingleTripDetails() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(2_400),
            startAddress: "Home",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 14.25),
            classification: .business,
            businessPurpose: "Client meeting",
            notes: "Follow-up with receipts"
        ))
        let reviewed = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(tollsAmount: 3.50, parkingAmount: 4.25)
        )

        let pdfText = try await tripPDFText(for: reviewed, rate: MileageRate(amountPerUnit: 0.725, unit: .miles))

        XCTAssertTrue(pdfText.contains("Trip Receipt"))
        XCTAssertTrue(pdfText.contains("Home"))
        XCTAssertTrue(pdfText.contains("Client"))
        // Business receipts omit the internal classification; the payment
        // summary carries the reimbursable total instead.
        XCTAssertFalse(pdfText.contains("Classification"))
        XCTAssertTrue(pdfText.contains("Total reimbursement"))
        XCTAssertTrue(pdfText.contains("$18.08"))
        XCTAssertFalse(pdfText.contains("Ready to Export"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertTrue(pdfText.contains("meeting"))
        XCTAssertTrue(pdfText.contains("Follow-up with receipts"))
        XCTAssertTrue(pdfText.contains("$3.50"))
        XCTAssertTrue(pdfText.contains("$4.25"))
        XCTAssertTrue(pdfText.contains("Notes"))
    }

    @MainActor
    func testReportsUseReadableDeduplicatedAddresses() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = "123 Main St, 123 Main St, Brooklyn, 123 Main St, Brooklyn, NY  11201, United States"
        let destination = "555 Example Ave, 555 Example Ave, Brooklyn, 555 Example Ave, Brooklyn, NY  11215, United States"

        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(2_400),
            startAddress: origin,
            endAddress: destination,
            distanceMeters: DistanceConversion.meters(fromMiles: 14.25),
            classification: .business,
            businessPurpose: "Client meeting"
        ))
        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(3_600),
            rate: .default,
            formatting: .enUS
        )
        let monthlyPDFText = flattenedPDFText(try pdfText(for: report.pdfData))
        let singleTripPDFData = try await ReportGenerator().makeTripPDF(
            for: trip,
            rate: .default,
            generatedAt: Date(timeIntervalSince1970: 1_800_010_000),
            formatting: .enUS
        )
        let singleTripPDFText = flattenedPDFText(try pdfText(for: singleTripPDFData))

        XCTAssertTrue(report.csvText.contains("123 Main St, Brooklyn, NY 11201"))
        XCTAssertTrue(report.csvText.contains("555 Example Ave, Brooklyn, NY 11215"))
        XCTAssertFalse(report.csvText.contains("123 Main St, 123 Main St"))
        XCTAssertFalse(report.csvText.contains("555 Example Ave, 555 Example Ave"))
        // The monthly table uses the compact itinerary form: same-city trips
        // share one city label and drop the home state and ZIP entirely.
        XCTAssertTrue(monthlyPDFText.contains("123 Main St → 555 Example Ave, Brooklyn"))
        XCTAssertFalse(monthlyPDFText.contains("11201"))
        XCTAssertFalse(monthlyPDFText.contains("11215"))
        XCTAssertFalse(monthlyPDFText.contains("123 Main St, 123 Main St"))
        XCTAssertFalse(monthlyPDFText.contains("555 Example Ave, 555 Example Ave"))
        XCTAssertTrue(singleTripPDFText.contains("123 Main St, Brooklyn, NY 11201"))
        XCTAssertTrue(singleTripPDFText.contains("555 Example Ave, Brooklyn, NY 11215"))
        XCTAssertFalse(singleTripPDFText.contains("123 Main St, 123 Main St"))
        XCTAssertFalse(singleTripPDFText.contains("555 Example Ave, 555 Example Ave"))
    }

    @MainActor
    func testTripPDFUsesExplicitMileageRateForValue() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 10),
            classification: .business,
            businessPurpose: "Client visit"
        ))

        let pdfData = try await ReportGenerator().makeTripPDF(
            for: trip,
            rate: MileageRate(amountPerUnit: 0.80, unit: .miles),
            generatedAt: Date(timeIntervalSince1970: 1_800_010_000),
            formatting: .enUS
        )
        let pdfText = try pdfText(for: pdfData)

        XCTAssertTrue(pdfText.contains("$8.00"))
        XCTAssertTrue(pdfText.contains("$0.800/mi"))
    }

    @MainActor
    func testPersonalTripPDFIncludesSingleTripDetails() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_200),
            startAddress: "Gym",
            endAddress: "Home",
            distanceMeters: DistanceConversion.meters(fromMiles: 4.2),
            classification: .personal,
            notes: "Weekend errand"
        ))

        let pdfText = try await tripPDFText(for: trip)

        XCTAssertTrue(pdfText.contains("Trip Receipt"))
        XCTAssertTrue(pdfText.contains("Gym"))
        XCTAssertTrue(pdfText.contains("Home"))
        XCTAssertTrue(pdfText.contains("Personal"))
        XCTAssertFalse(pdfText.contains("Ready to Export"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertTrue(pdfText.contains("Weekend errand"))
        XCTAssertTrue(pdfText.contains("$0.00"))
    }

    @MainActor
    func testUnclassifiedTripPDFIncludesSingleTripDetails() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(900),
            startAddress: "Office",
            endAddress: "Unknown Stop",
            distanceMeters: DistanceConversion.meters(fromMiles: 3),
            notes: "Needs review"
        ))

        let pdfText = try await tripPDFText(for: trip)

        XCTAssertTrue(pdfText.contains("Trip Receipt"))
        XCTAssertTrue(pdfText.contains("Office"))
        XCTAssertTrue(pdfText.contains("Unknown Stop"))
        XCTAssertTrue(pdfText.contains("Unreviewed"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertTrue(pdfText.contains("Needs review"))
    }

    @MainActor
    func testTripPDFKeepsLongRoutePurposeAndNotesTextSelectable() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = "Very Long Shared Workspace Name, Kendall Square, Cambridge, Massachusetts"
        let destination = "Long Client Destination Name, Financial District, Boston, Massachusetts"
        let purpose = "Quarterly planning meeting with implementation follow-up and receipt reconciliation"
        let notes = (1...18)
            .map { "Detailed note line \($0) for route, purpose, receipt, toll, and parking documentation." }
            .joined(separator: " ")
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(2_400),
            startAddress: origin,
            endAddress: destination,
            distanceMeters: DistanceConversion.meters(fromMiles: 14.25),
            classification: .business,
            businessPurpose: purpose,
            notes: notes
        ))

        let pdfData = try await ReportGenerator().makeTripPDF(
            for: trip,
            rate: .default,
            generatedAt: Date(timeIntervalSince1970: 1_800_010_000),
            formatting: .enUS
        )
        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        let pdfText = document.string ?? ""

        XCTAssertGreaterThan(document.pageCount, 1)
        // The endpoint columns sit side by side, so PDFKit interleaves their
        // wrapped lines — assert words rather than phrases that may span a wrap.
        XCTAssertTrue(pdfText.contains("Shared Workspace"))
        XCTAssertTrue(pdfText.contains("Kendall Square"))
        XCTAssertTrue(pdfText.contains("Destination Name"))
        XCTAssertTrue(pdfText.contains("Financial"))
        XCTAssertTrue(pdfText.contains("District"))
        XCTAssertTrue(pdfText.contains("Quarterly"))
        XCTAssertTrue(pdfText.contains("reconciliation"))
        XCTAssertTrue(pdfText.contains("Detailed note line 1"))
        XCTAssertTrue(pdfText.contains("Detailed note line 18"))
        XCTAssertFalse(pdfText.contains("Status"))
        XCTAssertFalse(pdfText.contains("Needs Attention"))
    }

    func testSaveAfterImmediateClassificationKeepsCurrentReviewState() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 7)
        ))

        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .business, reviewStatus: .readyToExport)
        )
        let saved = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                classification: .business,
                reviewStatus: .readyToExport,
                businessPurpose: "Client follow-up",
                notes: "Saved from detail"
            )
        )

        XCTAssertEqual(saved.classification, .business)
        XCTAssertEqual(saved.reviewStatus, .readyToExport)
        XCTAssertEqual(saved.businessPurpose, "Client follow-up")
        XCTAssertEqual(saved.notes, "Saved from detail")
    }

    func testPurposePersistsForUncategorizedAndPersonalTrips() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let uncategorized = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Home",
            endAddress: "Errand",
            distanceMeters: DistanceConversion.meters(fromMiles: 4)
        ))
        let savedUncategorized = try store.updateReview(
            tripID: uncategorized.id,
            update: ReviewUpdate(businessPurpose: "School pickup")
        )

        let personal = try store.createManualTrip(ManualTripInput(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(5_400),
            startAddress: "Gym",
            endAddress: "Home",
            distanceMeters: DistanceConversion.meters(fromMiles: 5)
        ))
        let savedPersonal = try store.updateReview(
            tripID: personal.id,
            update: ReviewUpdate(classification: .personal, businessPurpose: "Commute")
        )

        XCTAssertNil(savedUncategorized.classification)
        XCTAssertEqual(savedUncategorized.businessPurpose, "School pickup")
        XCTAssertEqual(savedPersonal.classification, .personal)
        XCTAssertEqual(savedPersonal.businessPurpose, "Commute")
    }

    func testMergeDistanceIsPureSum() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(
            store,
            start: start,
            distanceMiles: 3,
            classification: .business,
            startCoordinate: Coordinate(latitude: 40, longitude: -74),
            endCoordinate: Coordinate(latitude: 40.01, longitude: -74)
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(86_400),
            distanceMiles: 4,
            classification: .business,
            startCoordinate: Coordinate(latitude: 34, longitude: -118),
            endCoordinate: Coordinate(latitude: 34.01, longitude: -118)
        )

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertTrue(merged.connectors.isEmpty)
        XCTAssertEqual(merged.distanceMeters, first.reportableDistanceMeters + second.reportableDistanceMeters, accuracy: 0.001)
        XCTAssertEqual(merged.miles, 7, accuracy: 0.001)
    }

    func testMergeKeepsSeparateRouteSegments() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRoute = [
            Coordinate(latitude: 40, longitude: -74),
            Coordinate(latitude: 40.01, longitude: -73.99)
        ]
        let secondRoute = [
            Coordinate(latitude: 41, longitude: -75),
            Coordinate(latitude: 41.01, longitude: -74.99)
        ]
        let first = try makeTrip(store, start: start, classification: .business, route: firstRoute)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, route: secondRoute)

        let merged = try store.mergeTrips(ids: [second.id, first.id])
        let segments = try XCTUnwrap(EncodedPolyline.decodeSegments(try XCTUnwrap(merged.routePolyline)))

        XCTAssertTrue(merged.connectors.isEmpty)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, firstRoute.count)
        XCTAssertEqual(segments[1].count, secondRoute.count)
    }

    func testUpdateRouteOnMergedTripPreservesEditedPolyline() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRoute = [
            Coordinate(latitude: 40, longitude: -74),
            Coordinate(latitude: 40.01, longitude: -73.99)
        ]
        let secondRoute = [
            Coordinate(latitude: 41, longitude: -75),
            Coordinate(latitude: 41.01, longitude: -74.99)
        ]
        let first = try makeTrip(store, start: start, classification: .business, route: firstRoute)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, route: secondRoute)
        let merged = try store.mergeTrips(ids: [second.id, first.id])
        XCTAssertEqual(merged.legs.count, 2)
        // Before the edit, the merged route is the two legs' segments concatenated.
        XCTAssertEqual(EncodedPolyline.decodeSegments(try XCTUnwrap(merged.routePolyline))?.count, 2)

        // The route editor supplies a single flat polyline (no "\n") for the whole trip.
        let editedCoordinates = [
            Coordinate(latitude: 40, longitude: -74),
            Coordinate(latitude: 40.5, longitude: -74.5),
            Coordinate(latitude: 41.01, longitude: -74.99)
        ]
        let editedPolyline = EncodedPolyline.encode(editedCoordinates)
        XCTAssertFalse(editedPolyline.contains("\n"))

        let routed = try store.updateRoute(
            tripID: merged.id,
            startCoordinate: try XCTUnwrap(editedCoordinates.first),
            endCoordinate: try XCTUnwrap(editedCoordinates.last),
            routePolyline: editedPolyline,
            distanceMeters: nil
        )

        // The merged map reads trip.routePolyline, so it must now be the edited line
        // (one segment) rather than the stale per-leg concatenation — this is the bug fix.
        let editedSegments = try XCTUnwrap(EncodedPolyline.decodeSegments(try XCTUnwrap(routed.routePolyline)))
        XCTAssertEqual(editedSegments.count, 1)
        XCTAssertEqual(editedSegments[0].count, editedCoordinates.count)
        // Per-leg structure is preserved (legs are not collapsed).
        XCTAssertEqual(routed.legs.count, 2)

        // A non-leg edit (notes) must not re-clobber the edited route.
        let reviewed = try store.updateReview(
            tripID: merged.id,
            update: ReviewUpdate(notes: "edited route")
        )
        XCTAssertEqual(EncodedPolyline.decodeSegments(try XCTUnwrap(reviewed.routePolyline))?.count, 1)
    }

    func testClearRouteMapOnMergedTripClearsOuterCoordinatesAndEncodedGeometry() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(
            store,
            start: start,
            duration: 600,
            distanceMiles: 2,
            classification: .personal,
            route: [
                Coordinate(latitude: 40.000, longitude: -73.000),
                Coordinate(latitude: 40.010, longitude: -73.000)
            ]
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(3_600),
            duration: 600,
            distanceMiles: 3,
            classification: .personal,
            route: [
                Coordinate(latitude: 40.011, longitude: -73.000),
                Coordinate(latitude: 40.030, longitude: -73.000)
            ]
        )
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        XCTAssertFalse(merged.connectors.isEmpty)
        XCTAssertTrue(merged.legs.allSatisfy { $0.routePolyline != nil })
        XCTAssertTrue(merged.connectors.allSatisfy { $0.routePolyline != nil })
        let recordedDistance = merged.distanceMeters

        let cleared = try store.clearRouteMap(tripID: merged.id)

        XCTAssertNil(cleared.startCoordinate)
        XCTAssertNil(cleared.endCoordinate)
        XCTAssertNil(cleared.routePolyline)
        XCTAssertTrue(cleared.legs.allSatisfy { $0.routePolyline == nil })
        XCTAssertTrue(cleared.connectors.allSatisfy { $0.routePolyline == nil })
        XCTAssertEqual(cleared.distanceMeters, recordedDistance, accuracy: 0.001)
        XCTAssertEqual(cleared.legs.count, 2)
        XCTAssertEqual(cleared.connectors.count, merged.connectors.count)
    }

    func testMergeConnectsNearbyLegsAfterLongStopAndAddsConnectorMileageToSecondLeg() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRoute = [
            Coordinate(latitude: 40.00000, longitude: -73.00000),
            Coordinate(latitude: 40.01000, longitude: -73.00000)
        ]
        let secondRoute = [
            Coordinate(latitude: 40.01100, longitude: -73.00000),
            Coordinate(latitude: 40.03000, longitude: -73.00000)
        ]
        let first = try makeTrip(
            store,
            start: start,
            duration: 600,
            distanceMiles: 2,
            classification: .personal,
            route: firstRoute
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(8 * 60 * 60),
            duration: 600,
            distanceMiles: 3,
            classification: .personal,
            route: secondRoute
        )
        let connectorDistance = DistanceCalculator.distanceMeters(from: firstRoute[1], to: secondRoute[0])

        let merged = try store.mergeTrips(ids: [second.id, first.id])
        let segments = try XCTUnwrap(EncodedPolyline.decodeSegments(try XCTUnwrap(merged.routePolyline)))
        let connector = try XCTUnwrap(merged.connectors.first)
        let originalSecondStart = try XCTUnwrap(merged.legs[1].startCoordinate)
        let displayedSecondStart = try XCTUnwrap(merged.effectiveLegs[1].startCoordinate)
        let stop = try XCTUnwrap(merged.stops.first)
        let stopCoordinate = try XCTUnwrap(stop.coordinate)

        XCTAssertEqual(merged.connectors.count, 1)
        XCTAssertEqual(connector.fromLegID, merged.legs[0].id)
        XCTAssertEqual(connector.toLegID, merged.legs[1].id)
        XCTAssertEqual(connector.distanceMeters, connectorDistance, accuracy: 0.01)
        XCTAssertEqual(merged.distanceMeters, first.reportableDistanceMeters + second.reportableDistanceMeters + connectorDistance, accuracy: 0.01)
        XCTAssertEqual(merged.legs[1].distanceMeters, second.reportableDistanceMeters, accuracy: 0.01)
        XCTAssertEqual(merged.effectiveLegs[1].distanceMeters, second.reportableDistanceMeters + connectorDistance, accuracy: 0.01)
        XCTAssertEqual(originalSecondStart.latitude, secondRoute[0].latitude, accuracy: 0.00001)
        XCTAssertEqual(displayedSecondStart.latitude, firstRoute[1].latitude, accuracy: 0.00001)
        XCTAssertEqual(displayedSecondStart.longitude, firstRoute[1].longitude, accuracy: 0.00001)
        XCTAssertEqual(merged.legs[1].startAddress, second.startAddress)
        XCTAssertEqual(merged.effectiveLegs[1].startAddress, first.endAddress)
        XCTAssertEqual(stopCoordinate.latitude, firstRoute[1].latitude, accuracy: 0.00001)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1][0].latitude, firstRoute[1].latitude, accuracy: 0.00001)
        XCTAssertEqual(segments[1][1].latitude, secondRoute[0].latitude, accuracy: 0.00001)
        XCTAssertEqual(segments[2][0].latitude, secondRoute[0].latitude, accuracy: 0.00001)

        let restored = try store.unmergeTrip(id: merged.id)
        let restoredSecond = try XCTUnwrap(restored.first { $0.id == second.id })
        let restoredStart = try XCTUnwrap(restoredSecond.startCoordinate)
        XCTAssertTrue(restoredSecond.connectors.isEmpty)
        XCTAssertEqual(restoredSecond.distanceMeters, second.reportableDistanceMeters, accuracy: 0.01)
        XCTAssertEqual(restoredSecond.routePolyline, second.routePolyline)
        XCTAssertEqual(restoredStart.latitude, secondRoute[0].latitude, accuracy: 0.00001)
    }

    func testMergeDoesNotConnectLongDistanceLegBoundary() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRoute = [
            Coordinate(latitude: 40.00000, longitude: -73.00000),
            Coordinate(latitude: 40.01000, longitude: -73.00000)
        ]
        let secondRoute = [
            Coordinate(latitude: 40.02000, longitude: -73.00000),
            Coordinate(latitude: 40.03000, longitude: -73.00000)
        ]
        let first = try makeTrip(
            store,
            start: start,
            duration: 600,
            distanceMiles: 2,
            classification: .business,
            route: firstRoute
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(660),
            duration: 600,
            distanceMiles: 3,
            classification: .business,
            route: secondRoute
        )

        let merged = try store.mergeTrips(ids: [first.id, second.id])
        let segments = try XCTUnwrap(EncodedPolyline.decodeSegments(try XCTUnwrap(merged.routePolyline)))
        let secondStart = try XCTUnwrap(merged.legs[1].startCoordinate)

        XCTAssertTrue(merged.connectors.isEmpty)
        XCTAssertEqual(merged.distanceMeters, first.reportableDistanceMeters + second.reportableDistanceMeters, accuracy: 0.001)
        XCTAssertEqual(secondStart.latitude, secondRoute[0].latitude, accuracy: 0.00001)
        XCTAssertEqual(segments.count, 2)
    }

    func testMergingAlreadyMergedTripsPreservesConnectorsAndAddsOnlyMissingBoundaryConnector() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(
            store,
            start: start,
            distanceMiles: 2,
            classification: .business,
            businessPurpose: "Client visit",
            route: [
                Coordinate(latitude: 40.00000, longitude: -73.00000),
                Coordinate(latitude: 40.01000, longitude: -73.00000)
            ]
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(3_600),
            distanceMiles: 3,
            classification: .business,
            route: [
                Coordinate(latitude: 40.01100, longitude: -73.00000),
                Coordinate(latitude: 40.02000, longitude: -73.00000)
            ]
        )
        let third = try makeTrip(
            store,
            start: start.addingTimeInterval(7_200),
            distanceMiles: 4,
            classification: .business,
            route: [
                Coordinate(latitude: 40.02100, longitude: -73.00000),
                Coordinate(latitude: 40.03000, longitude: -73.00000)
            ]
        )

        let firstMerge = try store.mergeTrips(ids: [first.id, second.id])
        let mergedAgain = try store.mergeTrips(ids: [firstMerge.id, third.id])

        XCTAssertEqual(firstMerge.connectors.count, 1)
        XCTAssertEqual(mergedAgain.connectors.count, 2)
        XCTAssertEqual(Set(mergedAgain.connectors.map { "\($0.fromLegID)|\($0.toLegID)" }).count, 2)
        XCTAssertEqual(mergedAgain.connectors[0].fromLegID, mergedAgain.legs[0].id)
        XCTAssertEqual(mergedAgain.connectors[0].toLegID, mergedAgain.legs[1].id)
        XCTAssertEqual(mergedAgain.connectors[1].fromLegID, mergedAgain.legs[1].id)
        XCTAssertEqual(mergedAgain.connectors[1].toLegID, mergedAgain.legs[2].id)
        XCTAssertEqual(
            mergedAgain.distanceMeters,
            first.reportableDistanceMeters + second.reportableDistanceMeters + third.reportableDistanceMeters + mergedAgain.connectors.reduce(0) { $0 + $1.distanceMeters },
            accuracy: 0.01
        )
    }

    func testPartialSplitFiltersConnectorsForRemainingMergedTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(
            store,
            start: start,
            distanceMiles: 2,
            classification: .business,
            route: [
                Coordinate(latitude: 40.00000, longitude: -73.00000),
                Coordinate(latitude: 40.01000, longitude: -73.00000)
            ]
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(3_600),
            distanceMiles: 3,
            classification: .business,
            route: [
                Coordinate(latitude: 40.01100, longitude: -73.00000),
                Coordinate(latitude: 40.02000, longitude: -73.00000)
            ]
        )
        let third = try makeTrip(
            store,
            start: start.addingTimeInterval(7_200),
            distanceMiles: 4,
            classification: .business,
            route: [
                Coordinate(latitude: 40.02100, longitude: -73.00000),
                Coordinate(latitude: 40.03000, longitude: -73.00000)
            ]
        )
        let merged = try store.mergeTrips(ids: [first.id, second.id, third.id])

        let restored = try store.splitMergedTrip(id: merged.id, legIDs: [merged.legs[1].id])
        let remaining = try XCTUnwrap(try store.fetchTrips().first { $0.id == merged.id })

        XCTAssertEqual(merged.connectors.count, 2)
        XCTAssertEqual(restored.map(\.id), [second.id])
        XCTAssertEqual(remaining.legs.compactMap(\.sourceTripID), [first.id, third.id])
        XCTAssertTrue(remaining.connectors.isEmpty)
        XCTAssertEqual(remaining.distanceMeters, first.reportableDistanceMeters + third.reportableDistanceMeters, accuracy: 0.01)
    }

    @MainActor
    func testMergedReportsFoldConnectorMileageIntoFollowingLegWithoutConnectorRows() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(
            store,
            start: start,
            distanceMiles: 2,
            classification: .business,
            route: [
                Coordinate(latitude: 40.00000, longitude: -73.00000),
                Coordinate(latitude: 40.01000, longitude: -73.00000)
            ]
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(8 * 60 * 60),
            distanceMiles: 3,
            classification: .business,
            businessPurpose: "Client visit",
            route: [
                Coordinate(latitude: 40.01100, longitude: -73.00000),
                Coordinate(latitude: 40.03000, longitude: -73.00000)
            ]
        )
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        let connector = try XCTUnwrap(merged.connectors.first)
        let foldedSecondMiles = String(
            format: "%.2f",
            DistanceConversion.miles(fromMeters: second.reportableDistanceMeters + connector.distanceMeters)
        )
        let mergedMiles = String(format: "%.2f", merged.miles)

        let report = try ReportGenerator().makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(24 * 60 * 60),
            rate: .default,
            formatting: .enUS
        )
        let monthlyPDFText = try pdfText(for: report.pdfData)
        let singleTripPDFData = try await ReportGenerator().makeTripPDF(
            for: merged,
            rate: .default,
            generatedAt: Date(timeIntervalSince1970: 1_800_010_000),
            formatting: .enUS
        )
        let singleTripPDFText = try pdfText(for: singleTripPDFData)

        XCTAssertEqual(report.includedTripIDs, [merged.id])
        XCTAssertEqual(report.businessMiles, merged.miles, accuracy: 0.01)
        XCTAssertTrue(report.csvText.contains("Leg 2:"))
        XCTAssertTrue(report.csvText.contains("\(foldedSecondMiles) mi"))
        XCTAssertTrue(monthlyPDFText.contains(mergedMiles))
        XCTAssertTrue(singleTripPDFText.contains(foldedSecondMiles))
        XCTAssertFalse(report.csvText.lowercased().contains("connector"))
        XCTAssertFalse(monthlyPDFText.lowercased().contains("connector"))
        XCTAssertFalse(singleTripPDFText.lowercased().contains("connector"))
    }

    func testMergeDurationIsElapsedSpan() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, duration: 600, classification: .personal)
        let second = try makeTrip(store, start: start.addingTimeInterval(7_200), duration: 900, classification: .personal)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(merged.durationSeconds, 8_100, accuracy: 0.001)
    }

    func testMergeSpansFullTimeRange() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let later = try makeTrip(store, start: start.addingTimeInterval(5_000), duration: 600, classification: nil)
        let earlier = try makeTrip(store, start: start, duration: 900, classification: nil)

        let merged = try store.mergeTrips(ids: [later.id, earlier.id])

        XCTAssertEqual(merged.startDate, earlier.startDate)
        XCTAssertEqual(merged.endDate, later.endDate)
    }

    func testMergeStoresLegsAndDeletesSourceRows() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(try store.fetchTrips().map(\.id), [merged.id])
        XCTAssertEqual(try store.fetchTrips().map(\.id), [merged.id])
        XCTAssertEqual(merged.legs.compactMap(\.sourceTripID), [first.id, second.id])
    }

    func testMergeSumsTollsAndParking() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business, tolls: 2.50, parking: 4)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, tolls: 3.75, parking: 1.25)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(merged.tollsAmount, 6.25, accuracy: 0.001)
        XCTAssertEqual(merged.parkingAmount, 5.25, accuracy: 0.001)
    }

    func testMergeRelinksTolls() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)
        _ = try store.addFee(importedToll(
            tripID: first.id,
            sourceTransactionID: "merge-toll-1",
            amount: 7.25,
            occurredAt: first.startDate.addingTimeInterval(300)
        ))
        XCTAssertEqual(try importedTollIDs(store, tripID: first.id).count, 1)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(try importedTollIDs(store, tripID: merged.id), ["merge-toll-1"])
        XCTAssertEqual(try importedTollIDs(store, tripID: first.id).count, 0)
    }

    func testMergeInheritsSharedClassification() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business, businessPurpose: "Client meeting")
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, businessPurpose: "Client meeting")

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(merged.classification, .business)
        XCTAssertEqual(merged.businessPurpose, "Client meeting")
        XCTAssertEqual(merged.reviewStatus, .readyToExport)
        XCTAssertFalse(merged.needsAttention)
    }

    func testMergeResolvesMixedClassification() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Contradictory real categories drop to unclassified for review.
        let business = try makeTrip(store, start: start, classification: .business)
        let personal = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .personal)
        let mixed = try store.mergeTrips(ids: [business.id, personal.id])
        XCTAssertNil(mixed.classification)
        XCTAssertEqual(mixed.reviewStatus, .needsReview)

        // A lone real category wins over unclassified legs.
        let business2 = try makeTrip(store, start: start.addingTimeInterval(7_200), classification: .business)
        let uncategorized = try makeTrip(store, start: start.addingTimeInterval(10_800), classification: nil)
        let claimed = try store.mergeTrips(ids: [business2.id, uncategorized.id])
        XCTAssertEqual(claimed.classification, .business)

        // A lone real category also wins over Not a Drive legs.
        let personal2 = try makeTrip(store, start: start.addingTimeInterval(14_400), classification: .personal)
        let notADrive = try makeTrip(store, start: start.addingTimeInterval(18_000), classification: .notADrive)
        let reclaimed = try store.mergeTrips(ids: [personal2.id, notADrive.id])
        XCTAssertEqual(reclaimed.classification, .personal)

        // Only an all-Not-a-Drive merge stays Not a Drive.
        let stub1 = try makeTrip(store, start: start.addingTimeInterval(21_600), classification: .notADrive)
        let stub2 = try makeTrip(store, start: start.addingTimeInterval(25_200), classification: .notADrive)
        let stubs = try store.mergeTrips(ids: [stub1.id, stub2.id])
        XCTAssertEqual(stubs.classification, .notADrive)
    }

    func testResolvedMergeClassificationTable() {
        XCTAssertEqual(TripStore.resolvedMergeClassification([.business, .business]), .business)
        XCTAssertEqual(TripStore.resolvedMergeClassification([.personal, nil]), .personal)
        XCTAssertEqual(TripStore.resolvedMergeClassification([.business, nil, .notADrive]), .business)
        XCTAssertNil(TripStore.resolvedMergeClassification([.business, .personal]))
        XCTAssertNil(TripStore.resolvedMergeClassification([.business, .personal, nil]))
        XCTAssertNil(TripStore.resolvedMergeClassification([nil, nil]))
        XCTAssertNil(TripStore.resolvedMergeClassification([nil, .notADrive]))
        XCTAssertEqual(TripStore.resolvedMergeClassification([.notADrive, .notADrive]), .notADrive)
        XCTAssertNil(TripStore.resolvedMergeClassification([]))
    }

    func testMergeTakesPurposeFromLongestLegWithPurpose() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let short = try makeTrip(
            store,
            start: start,
            distanceMiles: 2,
            classification: .business,
            businessPurpose: "Errand"
        )
        let long = try makeTrip(
            store,
            start: start.addingTimeInterval(3_600),
            distanceMiles: 15,
            classification: .business,
            businessPurpose: "Client site"
        )
        // Longest leg overall, but it has no purpose so it can't donate one.
        let longest = try makeTrip(
            store,
            start: start.addingTimeInterval(7_200),
            distanceMiles: 30,
            classification: .business
        )

        let merged = try store.mergeTrips(ids: [short.id, long.id, longest.id])

        XCTAssertEqual(merged.businessPurpose, "Client site")
    }

    func testMergeRepointsRawSamples() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSamples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(60), latitude: 40.01, longitude: -73, horizontalAccuracy: 10)
        ]
        let secondSamples = [
            LocationSample(timestamp: start.addingTimeInterval(3_600), latitude: 41, longitude: -74, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(3_660), latitude: 41.01, longitude: -74, horizontalAccuracy: 10)
        ]
        let first = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(60),
            samples: firstSamples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: firstSamples)
        ))
        let second = try store.saveCompletedTrip(TripDraft(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(3_660),
            samples: secondSamples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: secondSamples)
        ))

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(try store.rawSampleCount(tripID: first.id), 0)
        XCTAssertEqual(try store.rawSampleCount(tripID: second.id), 0)
        XCTAssertEqual(try store.rawSampleCount(tripID: merged.id), 4)
    }

    func testMergeRecordsLegSourcesAndCanUnmerge() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)

        let merged = try store.mergeTrips(ids: [second.id, first.id])

        XCTAssertEqual(merged.legs.compactMap(\.sourceTripID), [first.id, second.id])
        XCTAssertTrue(merged.canUnmerge)
    }

    func testUnmergeRecreatesLegTripsAndRemovesMergedTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)
        let merged = try store.mergeTrips(ids: [first.id, second.id])

        let restored = try store.unmergeTrip(id: merged.id)

        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        XCTAssertEqual(Set(try store.fetchTrips().map(\.id)), [first.id, second.id])
        XCTAssertNil(try store.fetchTrips().first { $0.id == merged.id })
    }

    func testUnmergeCopiesMergedReviewFieldsToSources() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business, businessPurpose: "Merged Purpose", tolls: 1, parking: 2)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, tolls: 3, parking: 4)
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        _ = try store.updateReview(
            tripID: merged.id,
            update: ReviewUpdate(
                reviewStatus: .needsAttention,
                notes: "Merged Notes",
                tollsAmount: 12.25,
                parkingAmount: 8.50
            )
        )

        let restored = try store.unmergeTrip(id: merged.id)

        for trip in restored {
            XCTAssertEqual(trip.classification, .business)
            XCTAssertEqual(trip.businessPurpose, "Merged Purpose")
            XCTAssertEqual(trip.notes, "Merged Notes")
            XCTAssertEqual(trip.reviewStatus, .needsAttention)
        }

        // Merged totals are conserved. The leg model assigns post-merge charge edits to
        // the final leg instead of relying on archived source rows.
        let restoredFirst = try XCTUnwrap(restored.first { $0.id == first.id })
        let restoredSecond = try XCTUnwrap(restored.first { $0.id == second.id })
        XCTAssertEqual(restoredFirst.tollsAmount, 1, accuracy: 0.001)
        XCTAssertEqual(restoredSecond.tollsAmount, 11.25, accuracy: 0.001)
        XCTAssertEqual(restoredFirst.parkingAmount, 2, accuracy: 0.001)
        XCTAssertEqual(restoredSecond.parkingAmount, 6.50, accuracy: 0.001)
        XCTAssertEqual(restoredFirst.tollsAmount + restoredSecond.tollsAmount, 12.25, accuracy: 0.001)
        XCTAssertEqual(restoredFirst.parkingAmount + restoredSecond.parkingAmount, 8.50, accuracy: 0.001)
    }

    func testUnmergeRestoresOriginalPerSourceTollsAndParking() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business, tolls: 5, parking: 2)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business, tolls: 5, parking: 8)
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        XCTAssertEqual(merged.tollsAmount, 10, accuracy: 0.001)
        XCTAssertEqual(merged.parkingAmount, 10, accuracy: 0.001)

        let restored = try store.unmergeTrip(id: merged.id)

        // With no post-merge edits, each source should get back exactly its own original
        // amount — not the combined total (the previous behavior doubled the figures).
        let restoredFirst = try XCTUnwrap(restored.first { $0.id == first.id })
        let restoredSecond = try XCTUnwrap(restored.first { $0.id == second.id })
        XCTAssertEqual(restoredFirst.tollsAmount, 5, accuracy: 0.001)
        XCTAssertEqual(restoredFirst.parkingAmount, 2, accuracy: 0.001)
        XCTAssertEqual(restoredSecond.tollsAmount, 5, accuracy: 0.001)
        XCTAssertEqual(restoredSecond.parkingAmount, 8, accuracy: 0.001)
    }

    func testUnmergePreservesSourceTripShape() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRoute = [
            Coordinate(latitude: 40, longitude: -74),
            Coordinate(latitude: 40.01, longitude: -73.99)
        ]
        let secondRoute = [
            Coordinate(latitude: 41, longitude: -75),
            Coordinate(latitude: 41.01, longitude: -74.99)
        ]
        let first = try store.updateReview(
            tripID: makeTrip(store, start: start, distanceMiles: 4, classification: .personal, route: firstRoute).id,
            update: ReviewUpdate(manualDistanceOverrideMeters: DistanceConversion.meters(fromMiles: 5))
        )
        let second = try makeTrip(
            store,
            start: start.addingTimeInterval(7_200),
            duration: 1_200,
            distanceMiles: 7,
            classification: .personal,
            route: secondRoute
        )
        let merged = try store.mergeTrips(ids: [second.id, first.id])

        let restored = try store.unmergeTrip(id: merged.id)
        let restoredFirst = try XCTUnwrap(restored.first { $0.id == first.id })
        let restoredSecond = try XCTUnwrap(restored.first { $0.id == second.id })

        XCTAssertEqual(restoredFirst.startDate, first.startDate)
        XCTAssertEqual(restoredFirst.endDate, first.endDate)
        XCTAssertEqual(restoredFirst.startAddress, first.startAddress)
        XCTAssertEqual(restoredFirst.endAddress, first.endAddress)
        XCTAssertEqual(restoredFirst.distanceMeters, first.reportableDistanceMeters, accuracy: 0.001)
        XCTAssertNil(restoredFirst.manualDistanceOverrideMeters)
        XCTAssertEqual(restoredFirst.routePolyline, first.routePolyline)
        XCTAssertEqual(restoredFirst.captureSource, "manual")
        XCTAssertEqual(restoredSecond.startDate, second.startDate)
        XCTAssertEqual(restoredSecond.endDate, second.endDate)
        XCTAssertEqual(restoredSecond.routePolyline, second.routePolyline)
        XCTAssertEqual(restoredSecond.captureSource, "manual")
    }

    func testUnmergeReassignsRawSamplesBackToSources() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSamples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(60), latitude: 40.01, longitude: -73, horizontalAccuracy: 10)
        ]
        let secondSamples = [
            LocationSample(timestamp: start.addingTimeInterval(3_600), latitude: 41, longitude: -74, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(3_660), latitude: 41.01, longitude: -74, horizontalAccuracy: 10)
        ]
        let first = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(60),
            samples: firstSamples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: firstSamples)
        ))
        let second = try store.saveCompletedTrip(TripDraft(
            startDate: start.addingTimeInterval(3_600),
            endDate: start.addingTimeInterval(3_660),
            samples: secondSamples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: secondSamples)
        ))
        let merged = try store.mergeTrips(ids: [first.id, second.id])

        _ = try store.unmergeTrip(id: merged.id)

        XCTAssertEqual(try store.rawSampleCount(tripID: first.id), 2)
        XCTAssertEqual(try store.rawSampleCount(tripID: second.id), 2)
        XCTAssertEqual(try store.rawSampleCount(tripID: merged.id), 0)
    }

    func testUnmergeRestoresOriginalImportedTollLinks() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)
        _ = try store.addFee(importedToll(
            tripID: first.id,
            sourceTransactionID: "unmerge-toll-1",
            amount: 4.25,
            occurredAt: first.startDate.addingTimeInterval(300)
        ))
        _ = try store.addFee(importedToll(
            tripID: second.id,
            sourceTransactionID: "unmerge-toll-2",
            amount: 6.75,
            occurredAt: second.startDate.addingTimeInterval(300)
        ))
        let merged = try store.mergeTrips(ids: [first.id, second.id])

        _ = try store.unmergeTrip(id: merged.id)

        XCTAssertEqual(try importedTollIDs(store, tripID: first.id), ["unmerge-toll-1"])
        XCTAssertEqual(try importedTollIDs(store, tripID: second.id), ["unmerge-toll-2"])
        XCTAssertTrue(try importedTollIDs(store, tripID: merged.id).isEmpty)
    }

    func testUnmergeRejectsNormalTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)

        XCTAssertThrowsError(try store.unmergeTrip(id: first.id)) { error in
            guard case TripStoreError.notMergedTrip = error else {
                return XCTFail("Expected notMergedTrip, got \(error)")
            }
        }
    }

    @MainActor
    func testBusinessTripWithoutPurposeStaysUnresolvedAndIsExcludedFromReport() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Shop",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 12),
            classification: .business
        ))

        XCTAssertEqual(trip.reviewStatus, .needsReview)
        XCTAssertFalse(trip.needsAttention)
        XCTAssertTrue(trip.isUnresolved)
        XCTAssertFalse(trip.isExportableBusiness)

        let generator = ReportGenerator()
        let report = try generator.makeReport(
            trips: try store.fetchTrips(),
            odometerCheckpoints: [],
            startDate: start.addingTimeInterval(-1),
            endDate: start.addingTimeInterval(3_600),
            rate: .default,
            formatting: .enUS
        )
        XCTAssertEqual(report.businessMiles, 0, accuracy: 0.01)
        XCTAssertFalse(report.csvText.contains(trip.id.uuidString.lowercased()), report.csvText)
    }

    func testFetchTripIsReadOnlyAndReturnsStoredState() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 8),
            classification: .business
        ))

        let request = NSFetchRequest<NSManagedObject>(entityName: "TripEntity")
        request.predicate = NSPredicate(format: "id == %@", trip.id as CVarArg)
        let object = try XCTUnwrap(persistence.container.viewContext.fetch(request).first)
        object.setValue(ReviewStatus.needsAttention.rawValue, forKey: "reviewStatusRaw")
        object.setValue(true, forKey: "needsAttention")
        try persistence.container.viewContext.save()

        let fetched = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(fetched.reviewStatus, .needsAttention)
        XCTAssertTrue(fetched.needsAttention)
        XCTAssertFalse(persistence.container.viewContext.hasChanges)
    }

    func testFetchPathsDoNotDirtyContext() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let store = TripStore(context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(600), latitude: 40.05, longitude: -73, horizontalAccuracy: 10)
        ]
        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))
        _ = try store.addFee(
            tripID: trip.id,
            category: .toll,
            amount: 4.25,
            occurredAt: start.addingTimeInterval(300),
            label: "Bridge",
            source: .manual
        )
        XCTAssertFalse(context.hasChanges)

        _ = try store.fetchTrips()
        XCTAssertFalse(context.hasChanges)
        _ = try store.fetchTrip(id: trip.id)
        XCTAssertFalse(context.hasChanges)
        _ = try store.fetchTripIfExists(id: trip.id)
        XCTAssertFalse(context.hasChanges)
        _ = try store.fetchFees(tripID: trip.id)
        XCTAssertFalse(context.hasChanges)
        _ = try store.fetchFees(includeUnlinked: true)
        XCTAssertFalse(context.hasChanges)
    }

    func testSaveCompletedTripRecomputesFeeTotalsAndReviewState() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(600), latitude: 40.05, longitude: -73, horizontalAccuracy: 10)
        ]
        let draft = TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        )
        let trip = try store.saveCompletedTrip(draft)
        _ = try store.addFee(
            tripID: trip.id,
            category: .toll,
            amount: 5,
            occurredAt: start.addingTimeInterval(300),
            label: "Bridge",
            source: .manual
        )
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .business, businessPurpose: "Client visit")
        )

        // Re-saving the same capture (runtime re-completion) must keep the
        // linked fees and the classified review status without relying on
        // fetch-time repair.
        let resaved = try store.saveCompletedTrip(draft)

        XCTAssertEqual(resaved.tollsAmount, 5, accuracy: 0.001)
        XCTAssertEqual(resaved.classification, .business)
        XCTAssertEqual(resaved.reviewStatus, .readyToExport)
    }

    func testParkedStartInferenceAloneDoesNotNeedAttention() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.7046, longitude: -74.0119, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.7580, longitude: -73.9855, horizontalAccuracy: 10)
        ]

        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples),
            attentionReasons: [DriveCaptureReducer.inferredStartAttentionReason]
        ))

        XCTAssertEqual(trip.reviewStatus, .needsReview)
        XCTAssertFalse(trip.needsAttention)
        XCTAssertTrue(trip.attentionReasons.isEmpty)
    }

    func testParkedStartInferenceIsFilteredWhileActionableReasonRemains() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let actionableReason = "Impossible GPS jump"
        let samples = [
            LocationSample(timestamp: start, latitude: 40.7046, longitude: -74.0119, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.7580, longitude: -73.9855, horizontalAccuracy: 10)
        ]

        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples),
            attentionReasons: [DriveCaptureReducer.inferredStartAttentionReason, actionableReason]
        ))

        XCTAssertEqual(trip.reviewStatus, .needsAttention)
        XCTAssertTrue(trip.needsAttention)
        XCTAssertEqual(trip.attentionReasons, [actionableReason])
    }

    func testTripCorrectionsUpdateDistanceAndDates() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 4),
            classification: .personal
        ))

        let correctedStart = start.addingTimeInterval(300)
        let correctedEnd = start.addingTimeInterval(2_100)
        let corrected = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(
                manualDistanceOverrideMeters: DistanceConversion.meters(fromMiles: 5.5),
                startDate: correctedStart,
                endDate: correctedEnd
            )
        )

        XCTAssertEqual(corrected.startDate, correctedStart)
        XCTAssertEqual(corrected.endDate, correctedEnd)
        XCTAssertEqual(corrected.durationSeconds, 1_800, accuracy: 0.01)
        XCTAssertEqual(corrected.miles, 5.5, accuracy: 0.01)
    }

    func testReviewUpdateCanLeaveAndClearManualDistanceOverride() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 4)
        ))
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: DistanceConversion.meters(fromMiles: 8))
        )

        let unchanged = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(notes: "Keep current override")
        )
        XCTAssertEqual(try XCTUnwrap(unchanged.manualDistanceOverrideMeters), DistanceConversion.meters(fromMiles: 8), accuracy: 0.01)
        XCTAssertEqual(unchanged.miles, 8, accuracy: 0.01)

        let cleared = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(clearManualDistanceOverride: true)
        )
        XCTAssertNil(cleared.manualDistanceOverrideMeters)
        XCTAssertEqual(cleared.miles, 4, accuracy: 0.01)
    }

    func testManualTripPersistsRoutePolyline() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let destination = Coordinate(latitude: 40.7580, longitude: -73.9855)
        let routePolyline = EncodedPolyline.encode([
            origin,
            Coordinate(latitude: 40.7300, longitude: -73.9950),
            destination
        ])

        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: origin,
            endCoordinate: destination,
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 6.2),
            routePolyline: routePolyline
        ))

        XCTAssertEqual(trip.startCoordinate, origin)
        XCTAssertEqual(trip.endCoordinate, destination)
        XCTAssertEqual(trip.routePolyline, routePolyline)
        XCTAssertEqual(trip.miles, 6.2, accuracy: 0.01)
    }

    func testRouteUpdateReplacesCoordinatesDistanceAndClearsManualOverride() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMeters: DistanceConversion.meters(fromMiles: 4)
        ))
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: DistanceConversion.meters(fromMiles: 8))
        )
        let origin = Coordinate(latitude: 40.71, longitude: -74.00)
        let destination = Coordinate(latitude: 40.76, longitude: -73.98)
        let routePolyline = EncodedPolyline.encode([origin, destination])

        let routed = try store.updateRoute(
            tripID: trip.id,
            startCoordinate: origin,
            endCoordinate: destination,
            routePolyline: routePolyline,
            distanceMeters: DistanceConversion.meters(fromMiles: 5.4)
        )

        XCTAssertEqual(routed.startCoordinate, origin)
        XCTAssertEqual(routed.endCoordinate, destination)
        XCTAssertEqual(routed.routePolyline, routePolyline)
        XCTAssertEqual(routed.distanceMeters, DistanceConversion.meters(fromMiles: 5.4), accuracy: 0.01)
        XCTAssertNil(routed.manualDistanceOverrideMeters)
        XCTAssertEqual(routed.miles, 5.4, accuracy: 0.01)
    }

    func testAutomaticRouteUpdateDoesNotMarkTripAsManuallyEdited() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -74.0, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.01, longitude: -73.99, horizontalAccuracy: 10)
        ]
        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))
        let originalDistance = trip.distanceMeters
        let routePolyline = EncodedPolyline.encode([
            Coordinate(latitude: 40.0, longitude: -74.0),
            Coordinate(latitude: 40.005, longitude: -73.995),
            Coordinate(latitude: 40.01, longitude: -73.99)
        ])

        let updated = try store.updateAutomaticRoute(
            tripID: trip.id,
            routePolyline: routePolyline,
            distanceMeters: nil
        )

        XCTAssertEqual(updated.routePolyline, routePolyline)
        XCTAssertEqual(updated.distanceMeters, originalDistance, accuracy: 0.01)
        XCTAssertEqual(updated.reviewStatus, .needsReview)
        XCTAssertFalse(updated.needsAttention)

        let request = NSFetchRequest<NSManagedObject>(entityName: "TripEntity")
        request.predicate = NSPredicate(format: "id == %@", trip.id as CVarArg)
        let object = try XCTUnwrap(persistence.container.viewContext.fetch(request).first)
        XCTAssertNil(object.value(forKey: "lastEditedAt"))
        XCTAssertNil(object.value(forKey: "lastEditedDeviceName"))
    }

    func testAutomaticRouteAttentionPreservesRawRouteAndDoesNotMarkTripAsManuallyEdited() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40.0, longitude: -74.0, horizontalAccuracy: 10),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.01, longitude: -73.99, horizontalAccuracy: 10)
        ]
        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))
        let originalRoutePolyline = trip.routePolyline
        let originalDistance = trip.distanceMeters

        let updated = try store.appendAutomaticRouteAttentionReason(
            tripID: trip.id,
            attentionReason: AutomaticRouteFiller.lowConfidenceAttentionReason
        )

        XCTAssertEqual(updated.routePolyline, originalRoutePolyline)
        XCTAssertEqual(updated.distanceMeters, originalDistance, accuracy: 0.01)
        XCTAssertEqual(updated.reviewStatus, .needsAttention)
        XCTAssertTrue(updated.needsAttention)
        XCTAssertTrue(updated.attentionReasons.contains(AutomaticRouteFiller.lowConfidenceAttentionReason))

        let request = NSFetchRequest<NSManagedObject>(entityName: "TripEntity")
        request.predicate = NSPredicate(format: "id == %@", trip.id as CVarArg)
        let object = try XCTUnwrap(persistence.container.viewContext.fetch(request).first)
        XCTAssertNil(object.value(forKey: "lastEditedAt"))
        XCTAssertNil(object.value(forKey: "lastEditedDeviceName"))
    }

    func testClearRouteMapPreservesAddressesAndDistance() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = Coordinate(latitude: 40.71, longitude: -74.00)
        let destination = Coordinate(latitude: 40.76, longitude: -73.98)
        let trip = try store.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startCoordinate: origin,
            endCoordinate: destination,
            startAddress: "Office",
            endAddress: "Client",
            distanceMeters: DistanceConversion.meters(fromMiles: 6),
            routePolyline: EncodedPolyline.encode([origin, destination])
        ))
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(manualDistanceOverrideMeters: DistanceConversion.meters(fromMiles: 6.5))
        )

        let cleared = try store.clearRouteMap(tripID: trip.id)

        XCTAssertNil(cleared.startCoordinate)
        XCTAssertNil(cleared.endCoordinate)
        XCTAssertNil(cleared.routePolyline)
        XCTAssertEqual(cleared.startAddress, "Office")
        XCTAssertEqual(cleared.endAddress, "Client")
        XCTAssertEqual(cleared.distanceMeters, DistanceConversion.meters(fromMiles: 6), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(cleared.manualDistanceOverrideMeters), DistanceConversion.meters(fromMiles: 6.5), accuracy: 0.01)
        XCTAssertEqual(cleared.miles, 6.5, accuracy: 0.01)
    }

    func testRawSamplesCanBePurged() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10, speedMetersPerSecond: 12, motionHint: .automotive),
            LocationSample(timestamp: start.addingTimeInterval(80), latitude: 40.01, longitude: -73.01, horizontalAccuracy: 10, speedMetersPerSecond: 12, motionHint: .automotive),
            LocationSample(timestamp: start.addingTimeInterval(400), latitude: 40.02, longitude: -73.02, horizontalAccuracy: 10, speedMetersPerSecond: 0, motionHint: .stationary)
        ]

        _ = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(400),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))

        XCTAssertEqual(try store.rawSampleCount(), 3)
        _ = try store.purgeExpiredRawSamples(now: Date().addingTimeInterval(31 * 24 * 60 * 60))
        XCTAssertEqual(try store.rawSampleCount(), 0)
    }

    func testRawSamplesPreserveMotionConfidenceAndSpeedAccuracy() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let motion = MotionActivitySnapshot(
            startDate: start.addingTimeInterval(-5),
            confidence: .medium,
            hints: [.automotive, .stationary]
        )
        let samples = [
            LocationSample(
                timestamp: start,
                latitude: 40,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 10,
                speedAccuracyMetersPerSecond: 0.8,
                motionHint: .automotive,
                motionActivity: motion
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(80),
                latitude: 40.01,
                longitude: -73,
                horizontalAccuracy: 10,
                speedMetersPerSecond: 0,
                speedAccuracyMetersPerSecond: 0.5,
                motionHint: .stationary,
                motionActivity: motion
            )
        ]

        _ = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(80),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))

        let request = NSFetchRequest<NSManagedObject>(entityName: "RawSampleEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let raw = try XCTUnwrap(persistence.container.viewContext.fetch(request).first)
        XCTAssertEqual(raw.value(forKey: "speedAccuracyMetersPerSecond") as? Double, 0.8)
        let data = try XCTUnwrap(raw.value(forKey: "motionActivityData") as? Data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MotionActivitySnapshot.self, from: data)
        XCTAssertEqual(decoded.confidence, .medium)
        XCTAssertEqual(decoded.hints, [.automotive, .stationary])
    }

    func testDeleteTripRemovesTripAndRawSamples() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            LocationSample(timestamp: start, latitude: 40, longitude: -73, horizontalAccuracy: 10, speedMetersPerSecond: 12),
            LocationSample(timestamp: start.addingTimeInterval(120), latitude: 40.01, longitude: -73.01, horizontalAccuracy: 10, speedMetersPerSecond: 10)
        ]

        let trip = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))

        XCTAssertEqual(try store.fetchTrips().map(\.id), [trip.id])
        XCTAssertEqual(try store.rawSampleCount(tripID: trip.id), 2)

        try store.deleteTrip(id: trip.id)

        XCTAssertTrue(try store.fetchTrips().isEmpty)
        XCTAssertEqual(try store.rawSampleCount(tripID: trip.id), 0)
        XCTAssertThrowsError(try store.fetchTrip(id: trip.id))
    }

    func testClassifyNotADriveSetsReadyToExportAndClearsPurpose() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: .business)
        _ = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(businessPurpose: "Client meeting")
        )

        let marked = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .notADrive, reviewStatus: .readyToExport)
        )

        XCTAssertEqual(marked.classification, .notADrive)
        XCTAssertEqual(marked.reviewStatus, .readyToExport)
        XCTAssertNil(marked.businessPurpose)
        XCTAssertFalse(marked.needsAttention)
        XCTAssertTrue(marked.attentionReasons.isEmpty)
    }

    func testMergePreservesUnionOfStartBluetoothHashes() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeTrip(store, start: start, classification: .business)
        let second = try makeTrip(store, start: start.addingTimeInterval(3_600), classification: .business)
        _ = try store.setStartBluetoothHints(tripID: first.id, identifierHashes: ["hash-a", "hash-b"])
        _ = try store.setStartBluetoothHints(tripID: second.id, identifierHashes: ["hash-b", "hash-c"])

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        XCTAssertEqual(Set(merged.startBluetoothHintHashes), ["hash-a", "hash-b", "hash-c"])
    }

    @MainActor
    private func tripPDFText(for trip: TripSummary, rate: MileageRate = .default) async throws -> String {
        let pdfData = try await ReportGenerator().makeTripPDF(
            for: trip,
            rate: rate,
            generatedAt: Date(timeIntervalSince1970: 1_800_010_000),
            formatting: .enUS
        )
        XCTAssertFalse(pdfData.isEmpty)
        return try pdfText(for: pdfData)
    }

    private func pdfText(for pdfData: Data) throws -> String {
        let document = try XCTUnwrap(PDFDocument(data: pdfData))
        return document.string ?? ""
    }

    private func flattenedPDFText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testApplyAutomaticClassificationSetsSourceAndNormalizes() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: nil)

        let marked = try store.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoTransit
        )

        XCTAssertEqual(marked.classification, .notADrive)
        XCTAssertEqual(marked.classificationSource, .autoTransit)
        XCTAssertEqual(marked.reviewStatus, .readyToExport)
        XCTAssertNil(marked.businessPurpose)
        XCTAssertTrue(marked.attentionReasons.isEmpty)
    }

    func testApplyAutomaticClassificationRefusesUserClassifiedTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: .business)

        let result = try store.applyAutomaticClassification(
            tripID: trip.id,
            classification: .notADrive,
            source: .autoTransit
        )

        XCTAssertEqual(result.classification, .business)
        XCTAssertNil(result.classificationSource)
    }

    func testUpdateReviewChangingClassificationClearsSource() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: nil)
        _ = try store.applyAutomaticClassification(tripID: trip.id, classification: .notADrive, source: .autoTransit)

        let updated = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .personal, reviewStatus: .readyToExport)
        )

        XCTAssertEqual(updated.classification, .personal)
        XCTAssertNil(updated.classificationSource)
    }

    func testUpdateReviewClearingClassificationClearsSource() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: nil)
        _ = try store.applyAutomaticClassification(tripID: trip.id, classification: .notADrive, source: .autoTransit)

        let updated = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(clearClassification: true, reviewStatus: .needsReview)
        )

        XCTAssertNil(updated.classification)
        XCTAssertNil(updated.classificationSource)
    }

    func testUpdateReviewSameClassificationPreservesSource() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try makeTrip(store, start: start, classification: nil)
        _ = try store.applyAutomaticClassification(tripID: trip.id, classification: .notADrive, source: .autoTransit)

        // Detail-view autosave re-submits the same classification on disappear.
        let updated = try store.updateReview(
            tripID: trip.id,
            update: ReviewUpdate(classification: .notADrive, reviewStatus: .readyToExport, notes: "still a train")
        )

        XCTAssertEqual(updated.classification, .notADrive)
        XCTAssertEqual(updated.classificationSource, .autoTransit)
    }

    func testAttentionReasonCannotReopenNotADrive() throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let trip = try makeTrip(
            store,
            start: Date(timeIntervalSince1970: 1_800_000_000),
            classification: .notADrive
        )

        let updated = try store.appendAttentionReason(tripID: trip.id, reason: "Verify route")

        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertFalse(updated.needsAttention)
        XCTAssertTrue(updated.attentionReasons.isEmpty)
    }

    // MARK: - Imported-toll helpers

    /// Builds a fee shaped like one the retired E-ZPass CSV importer produced.
    /// The importer is gone, but fees carrying `.ezPassImport` still live in
    /// synced stores, and merge/un-merge must keep reassigning them correctly.
    private func importedToll(
        tripID: UUID,
        sourceTransactionID: String,
        amount: Double,
        occurredAt: Date
    ) -> TripFee {
        TripFee(
            tripID: tripID,
            category: .toll,
            amount: amount,
            occurredAt: occurredAt,
            source: .ezPassImport,
            sourceTransactionID: sourceTransactionID,
            tagOrPlate: "00816345634",
            agency: "PANYNJ",
            importedAt: occurredAt
        )
    }

    private func importedTollIDs(_ store: TripStore, tripID: UUID) throws -> [String] {
        try store.fetchFees(tripID: tripID)
            .filter { $0.source == .ezPassImport }
            .compactMap(\.sourceTransactionID)
    }
}

/// Pinned formatting so report assertions hold regardless of the machine's
/// locale, unit, or currency defaults.
private extension ReportFormattingContext {
    static let enUS = ReportFormattingContext(
        locale: Locale(identifier: "en_US"),
        distanceUnit: .miles,
        currencyCode: "USD"
    )
}
