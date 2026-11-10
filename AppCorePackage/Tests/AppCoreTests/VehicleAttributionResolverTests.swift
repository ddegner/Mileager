import XCTest
@testable import AppCore

final class VehicleAttributionResolverTests: XCTestCase {
    private let resolver = VehicleAttributionResolver()

    private func hint(vehicleID: UUID?, trusted: Bool = false, name: String = "Car BT") -> BluetoothDriveHint {
        BluetoothDriveHint(
            identifierHash: UUID().uuidString,
            displayName: name,
            source: .audioRoute,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            trusted: trusted,
            vehicleID: vehicleID
        )
    }

    func testShortcutVehicleAlwaysWins() {
        let shortcutVehicle = UUID()
        let btVehicle = UUID()
        let resolution = resolver.resolve(
            draftVehicleID: shortcutVehicle,
            observedHints: [hint(vehicleID: btVehicle, trusted: true)]
        )
        XCTAssertEqual(resolution.vehicleID, shortcutVehicle)
        XCTAssertEqual(resolution.source, .shortcut)
        XCTAssertTrue(resolution.conflictingVehicleIDs.isEmpty)
    }

    func testDraftVehicleConnectionSourceIsPreserved() {
        let latchedVehicle = UUID()
        let resolution = resolver.resolve(
            draftVehicleID: latchedVehicle,
            draftVehicleAssignmentSource: .vehicleConnection,
            observedHints: [hint(vehicleID: UUID(), trusted: true)]
        )
        XCTAssertEqual(resolution.vehicleID, latchedVehicle)
        XCTAssertEqual(resolution.source, .vehicleConnection)
    }

    func testSingleMappedHintResolvesToVehicleConnection() {
        let vehicle = UUID()
        let resolution = resolver.resolve(
            draftVehicleID: nil,
            observedHints: [hint(vehicleID: vehicle), hint(vehicleID: vehicle)]
        )
        XCTAssertEqual(resolution.vehicleID, vehicle)
        XCTAssertEqual(resolution.source, .vehicleConnection)
    }

    func testConflictingMappedHintsNeverUseTrustToPickVehicle() {
        let trustedVehicle = UUID()
        let otherVehicle = UUID()
        let resolution = resolver.resolve(
            draftVehicleID: nil,
            observedHints: [
                hint(vehicleID: trustedVehicle, trusted: true),
                hint(vehicleID: otherVehicle, trusted: false)
            ]
        )
        XCTAssertNil(resolution.vehicleID)
        XCTAssertNil(resolution.source)
        XCTAssertEqual(Set(resolution.conflictingVehicleIDs), [trustedVehicle, otherVehicle])
    }

    func testConflictingTrustedHintsLeaveUnassignedWithConflict() {
        let a = UUID()
        let b = UUID()
        let resolution = resolver.resolve(
            draftVehicleID: nil,
            observedHints: [
                hint(vehicleID: a, trusted: true),
                hint(vehicleID: b, trusted: true)
            ]
        )
        XCTAssertNil(resolution.vehicleID)
        XCTAssertNil(resolution.source)
        XCTAssertEqual(Set(resolution.conflictingVehicleIDs), [a, b])
    }

    func testNoEvidenceLeavesDefault() {
        let resolution = resolver.resolve(draftVehicleID: nil, observedHints: [])
        XCTAssertNil(resolution.vehicleID)
        XCTAssertNil(resolution.source)
        XCTAssertTrue(resolution.conflictingVehicleIDs.isEmpty)
    }
}
