import XCTest
@testable import AppCore

final class VehicleTrustPolicyTests: XCTestCase {
    private let policy = VehicleTrustPolicy()

    func testTrustThresholdsByNameMatchClass() {
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: "Toyota Camry"), 2)
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: "CarPlay"), 2)
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: "Pioneer Deck"), 3)
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: nil), 3)
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: "David's AirPods"), 5)
        XCTAssertEqual(VehicleTrustPolicy.trustThreshold(displayName: "JBL Speaker"), 5)
    }

    func testVehicleNamedDeviceTrustedAtTwoConfirmations() {
        XCTAssertFalse(policy.isTrusted(confirmed: 1, notADrive: 0, displayName: "Toyota Camry"))
        XCTAssertTrue(policy.isTrusted(confirmed: 2, notADrive: 0, displayName: "Toyota Camry"))
    }

    func testRejectedNameNeedsFiveConfirmationsButCanEarnTrust() {
        XCTAssertFalse(policy.isTrusted(confirmed: 4, notADrive: 0, displayName: "David's AirPods"))
        XCTAssertTrue(policy.isTrusted(confirmed: 5, notADrive: 0, displayName: "David's AirPods"))
    }

    func testBlockedWhenNegativeEvidenceDominates() {
        XCTAssertFalse(policy.isBlocked(confirmed: 0, notADrive: 1))
        XCTAssertTrue(policy.isBlocked(confirmed: 0, notADrive: 2))
        XCTAssertTrue(policy.isBlocked(confirmed: 2, notADrive: 2))
        XCTAssertFalse(policy.isBlocked(confirmed: 3, notADrive: 2))
    }

    func testBlockPrecedesTrustRegardlessOfConfirmations() {
        XCTAssertFalse(policy.isTrusted(confirmed: 4, notADrive: 4, displayName: "Toyota Camry"))
    }

    func testTrustRequiresConfirmationsToDoubleNegatives() {
        // 3 confirms vs 2 negatives: not blocked, but 3 < 2*2 so not trusted.
        XCTAssertFalse(policy.isTrusted(confirmed: 3, notADrive: 2, displayName: "Toyota Camry"))
        XCTAssertTrue(policy.isTrusted(confirmed: 4, notADrive: 2, displayName: "Toyota Camry"))
    }

    func testDemotionWhenNegativesAccumulate() {
        // A single negative against two confirms keeps trust (2 >= 2x1)...
        XCTAssertTrue(policy.isTrusted(confirmed: 2, notADrive: 1, displayName: "Toyota Camry"))
        // ...but equal negatives block, and 3 negatives against 4 confirms demote.
        XCTAssertFalse(policy.isTrusted(confirmed: 2, notADrive: 2, displayName: "Toyota Camry"))
        XCTAssertFalse(policy.isTrusted(confirmed: 4, notADrive: 3, displayName: "Toyota Camry"))
    }
}
