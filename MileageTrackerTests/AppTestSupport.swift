import AppCore
import Foundation
import XCTest

func makeTestDefaults(file: StaticString = #filePath, line: UInt = #line) throws -> UserDefaults {
    let suiteName = "MileageTrackerTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

func appModelArguments(_ arguments: [String]) -> [String] {
    arguments + ["--test-store-suffix=\(UUID().uuidString)"]
}

func makeTrip(
    startDate: Date,
    miles: Double,
    classification: TripClassification? = nil,
    reviewStatus: ReviewStatus = .needsReview,
    purpose: String? = nil,
    tolls: Double = 0,
    parking: Double = 0,
    needsAttention: Bool = false,
    startCoordinate: Coordinate? = nil,
    endCoordinate: Coordinate? = nil,
    routePolyline: String? = nil,
    vehicleID: UUID? = nil
) -> TripSummary {
    TripSummary(
        id: UUID(),
        createdAt: startDate,
        updatedAt: startDate,
        captureSource: "manual",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(1_800),
        startCoordinate: startCoordinate,
        endCoordinate: endCoordinate,
        startAddress: "Start",
        endAddress: "End",
        distanceMeters: DistanceConversion.meters(fromMiles: miles),
        routePolyline: routePolyline,
        classification: classification,
        reviewStatus: reviewStatus,
        businessPurpose: purpose,
        notes: nil,
        tollsAmount: tolls,
        parkingAmount: parking,
        needsAttention: needsAttention,
        attentionReasons: [],
        manualDistanceOverrideMeters: nil,
        vehicleID: vehicleID
    )
}
