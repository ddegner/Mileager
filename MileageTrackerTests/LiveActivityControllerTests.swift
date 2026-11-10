import AppCore
import Foundation
import XCTest
@testable import MileageTracker

#if canImport(ActivityKit)
@MainActor
final class LiveActivityControllerTests: XCTestCase {
    func testDisableEndsActivityEvenWhenItMatchesCurrentDrive() {
        let tripID = UUID()

        XCTAssertTrue(LiveActivityController.shouldEndActivity(
            pendingTripID: tripID,
            keeping: tripID,
            enabled: false
        ))
        XCTAssertFalse(LiveActivityController.shouldEndActivity(
            pendingTripID: tripID,
            keeping: tripID,
            enabled: true
        ))
        XCTAssertTrue(LiveActivityController.shouldEndActivity(
            pendingTripID: UUID(),
            keeping: tripID,
            enabled: true
        ))
    }

    func testContentStateCarriesConfirmationAndVehiclePresentation() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let lastMovingAt = startedAt.addingTimeInterval(120)
        let vehicle = CurrentDriveVehicleSnapshot(
            id: UUID(),
            name: "Forester",
            symbolName: "car.side.fill",
            colorHex: "#0A84C6",
            isConfirmed: true
        )
        let summary = CurrentDriveSummary(
            phase: .confirmingTripEnd,
            startedAt: startedAt,
            lastMovingAt: lastMovingAt,
            distanceMeters: 4_200,
            pendingTripID: UUID(),
            vehicleID: vehicle.id,
            vehicle: vehicle
        )

        let state = MileageDriveActivityAttributes.ContentState(summary: summary)

        XCTAssertEqual(state.phase, .confirmingTripEnd)
        XCTAssertEqual(state.lastMovingAt, lastMovingAt)
        XCTAssertEqual(state.vehicle, vehicle)
        XCTAssertFalse(state.isPaused)
    }

    func testLegacyContentStateWithoutNewOptionalFieldsStillDecodes() throws {
        let legacy = LegacyContentState(
            distanceMeters: 800,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isPaused: true,
            classification: nil,
            businessPurpose: nil,
            feeCount: 0,
            distanceUnitRaw: nil
        )

        let data = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(
            MileageDriveActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertEqual(restored.phase, .paused)
        XCTAssertNil(restored.lastMovingAt)
        XCTAssertNil(restored.vehicle)
    }

    func testCurrentDriveLinkQueuesPresentationWithoutChangingCapture() {
        let model = MileageAppModel(previewMode: true)
        let tripID = UUID()

        model.handleOpenURL(DeepLinkRoute.currentDrive(tripID: tripID).url)

        XCTAssertEqual(model.currentDrivePresentationRequestID, tripID)
        XCTAssertNil(model.currentDrive, "The root view must wait for the active drive and unlock gates")
        XCTAssertNil(model.currentDriveFeeRequest)
        XCTAssertNil(model.currentDriveVehicleRequestID)
        XCTAssertNil(model.currentDriveNewLegRequestID)
        model.clearCurrentDrivePresentationRequest()
        XCTAssertNil(model.currentDrivePresentationRequestID)
    }

    func testOnlyVehicleLinkQueuesDedicatedVehiclePickerRequest() {
        let model = MileageAppModel(previewMode: true)
        let tripID = UUID()

        model.handleOpenURL(DeepLinkRoute.currentDrive(tripID: tripID).url)
        XCTAssertNil(model.currentDriveVehicleRequestID)

        model.handleOpenURL(DeepLinkRoute.currentDriveVehicle(tripID: tripID).url)
        XCTAssertEqual(model.currentDriveVehicleRequestID, tripID)
        XCTAssertNil(model.currentDriveNewLegRequestID)
    }

    func testOnlyNewLegLinkQueuesDedicatedNewLegRequest() {
        let model = MileageAppModel(previewMode: true)
        let tripID = UUID()

        // A split closes a trip, so a mis-parse that queued one from a plain
        // drive tap would be serious. Assert the other three routes leave it nil.
        model.handleOpenURL(DeepLinkRoute.currentDrive(tripID: tripID).url)
        model.handleOpenURL(DeepLinkRoute.currentDriveVehicle(tripID: tripID).url)
        model.handleOpenURL(DeepLinkRoute.currentDriveFee(tripID: tripID, category: .toll).url)
        XCTAssertNil(model.currentDriveNewLegRequestID)

        model.handleOpenURL(DeepLinkRoute.currentDriveNewLeg(tripID: tripID).url)
        XCTAssertEqual(model.currentDriveNewLegRequestID, tripID)
    }

    func testNewLegRequestIsQueuedNotPerformedOnArrival() {
        let model = MileageAppModel(previewMode: true)

        model.handleOpenURL(DeepLinkRoute.currentDriveNewLeg(tripID: UUID()).url)

        XCTAssertNotNil(model.currentDriveNewLegRequestID)
        XCTAssertNil(model.currentDrive, "handleOpenURL must queue only; ContentView owns the gates")
    }
}

private struct LegacyContentState: Encodable {
    var distanceMeters: Double
    var startedAt: Date
    var isPaused: Bool
    var classification: String?
    var businessPurpose: String?
    var feeCount: Int
    var distanceUnitRaw: String?
}
#endif
