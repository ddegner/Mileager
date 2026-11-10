import AppCore
import XCTest
@testable import MileageTracker

final class VehicleRemovalPromptTests: XCTestCase {
    func testRemovingNonPrimaryUsesCurrentPrimaryVehicle() {
        let primary = Vehicle(name: "Family Car")
        let removed = Vehicle(name: "Work Van")

        let prompt = VehicleRemovalPrompt.make(
            removedVehicleID: removed.id,
            removedVehicleName: removed.name,
            vehicles: [removed, primary],
            primaryVehicleID: primary.id
        )

        XCTAssertEqual(prompt.replacementVehicleID, primary.id)
        XCTAssertEqual(prompt.replacementVehicleName, "Family Car")
        XCTAssertEqual(prompt.title, "Remove Work Van?")
        XCTAssertTrue(prompt.message.contains("appear under Family Car, your default vehicle"))
        XCTAssertTrue(prompt.message.contains("odometer history"))
        XCTAssertTrue(prompt.message.contains("CarPlay and Bluetooth connections"))
    }

    func testRemovingPrimaryUsesFirstRemainingDisplayOrder() {
        let firstRemaining = Vehicle(name: "Roadster")
        let removedPrimary = Vehicle(name: "Primary")
        let lastRemaining = Vehicle(name: "Pickup")

        let prompt = VehicleRemovalPrompt.make(
            removedVehicleID: removedPrimary.id,
            removedVehicleName: removedPrimary.name,
            vehicles: [firstRemaining, removedPrimary, lastRemaining],
            primaryVehicleID: removedPrimary.id
        )

        XCTAssertEqual(prompt.replacementVehicleID, firstRemaining.id)
        XCTAssertEqual(prompt.replacementVehicleName, "Roadster")
        XCTAssertTrue(prompt.message.contains("appear under Roadster, your default vehicle"))
    }

    func testMissingReplacementUsesFallbackWording() {
        let removed = Vehicle(name: "Only Car")

        let prompt = VehicleRemovalPrompt.make(
            removedVehicleID: removed.id,
            removedVehicleName: removed.name,
            vehicles: [removed],
            primaryVehicleID: removed.id
        )

        XCTAssertNil(prompt.replacementVehicleID)
        XCTAssertNil(prompt.replacementVehicleName)
        XCTAssertTrue(prompt.message.contains("appear under your default vehicle"))
    }
}
