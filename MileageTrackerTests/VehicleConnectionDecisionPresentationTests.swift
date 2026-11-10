import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class VehicleConnectionDecisionPresentationTests: XCTestCase {
    func testStableBluetoothConnectionUsesTheDeviceNameOnceInTheQuestion() {
        let vehicle = Vehicle(name: "Forester")
        let decision = PendingVehicleConnectionDecision(
            tripID: UUID(),
            kind: .unknownConnection(
                hint: makeHint(name: "SUBARU BT", identityQuality: .stablePortIdentifier),
                suggestion: nil
            )
        )

        let presentation = VehicleConnectionDecisionPresentation(
            decision: decision,
            vehicles: [vehicle]
        )

        XCTAssertEqual(presentation.title, "Which car is “SUBARU BT”?")
        XCTAssertEqual(
            presentation.explanation,
            "Mileager will recognize this car automatically on future drives."
        )
        XCTAssertTrue(presentation.canIgnoreConnection)
    }

    func testFallbackConnectionUsesTheGenericQuestion() {
        let decision = PendingVehicleConnectionDecision(
            tripID: UUID(),
            kind: .unknownConnection(
                hint: makeHint(name: "Car Audio", identityQuality: .fallbackPortName),
                suggestion: nil
            )
        )

        let presentation = VehicleConnectionDecisionPresentation(
            decision: decision,
            vehicles: [Vehicle(name: "Forester")]
        )

        XCTAssertEqual(presentation.title, "Which car was this trip in?")
        XCTAssertEqual(
            presentation.explanation,
            "Mileager will suggest this car on future drives, but still ask you to confirm."
        )
    }

    func testSyncedSuggestionBecomesTheClearRecommendedChoice() {
        let vehicle = Vehicle(name: "Forester")
        let alias = VehicleConnectionAlias(
            vehicleID: vehicle.id,
            displayName: "SUBARU BT",
            connectionKind: .bluetooth
        )
        let decision = PendingVehicleConnectionDecision(
            tripID: UUID(),
            kind: .unknownConnection(
                hint: makeHint(name: "SUBARU BT", identityQuality: .stablePortIdentifier),
                suggestion: VehicleConnectionSuggestion(alias: alias)
            )
        )

        let presentation = VehicleConnectionDecisionPresentation(
            decision: decision,
            vehicles: [vehicle]
        )

        XCTAssertEqual(presentation.title, "Is “SUBARU BT” your Forester?")
        XCTAssertEqual(presentation.suggestedVehicleID, vehicle.id)
    }

    func testConflictUsesOnlyTheSimpleDrivingQuestion() {
        let forester = Vehicle(name: "Forester")
        let outback = Vehicle(name: "Outback")
        let decision = PendingVehicleConnectionDecision(
            tripID: UUID(),
            kind: .conflictingVehicles(
                vehicleIDs: [forester.id, outback.id],
                latchedVehicleID: forester.id
            )
        )

        let presentation = VehicleConnectionDecisionPresentation(
            decision: decision,
            vehicles: [forester, outback]
        )

        XCTAssertEqual(presentation.title, "Which car did you drive?")
        XCTAssertEqual(
            presentation.explanation,
            "Mileager found more than one saved car connection during this trip."
        )
        XCTAssertFalse(presentation.canIgnoreConnection)
    }

    func testIgnoreConfirmationExplainsTheDetectionImpactAndRecoveryPath() {
        let decision = PendingVehicleConnectionDecision(
            tripID: UUID(),
            kind: .unknownConnection(
                hint: makeHint(name: "Passenger Car", identityQuality: .stablePortIdentifier),
                suggestion: nil
            )
        )

        let presentation = VehicleConnectionDecisionPresentation(
            decision: decision,
            vehicles: [Vehicle(name: "Forester")]
        )

        XCTAssertEqual(presentation.ignoreTitle, "Ignore “Passenger Car”?")
        XCTAssertTrue(presentation.ignoreMessage.contains("stop using this connection to help detect drives"))
        XCTAssertTrue(presentation.ignoreMessage.contains("Settings › Vehicles"))
    }

    private func makeHint(
        name: String?,
        identityQuality: VehicleConnectionIdentityQuality
    ) -> BluetoothDriveHint {
        BluetoothDriveHint(
            identifierHash: UUID().uuidString,
            displayName: name,
            source: .audioRoute,
            firstSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            connectionKind: .bluetooth,
            identityQuality: identityQuality
        )
    }
}
