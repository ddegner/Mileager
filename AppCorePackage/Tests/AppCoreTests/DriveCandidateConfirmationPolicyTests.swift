import XCTest
@testable import AppCore
@testable import DriveCaptureEngine

final class DriveCandidateConfirmationPolicyTests: XCTestCase {
    func testNoMovementContinuesCollecting() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            hasMovementEvidence: false
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testTrustedVehicleEvidenceConfirmsVisibleTrip() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            hasAutomotiveHint: true,
            hasTrustedVehicleEvidence: true
        ))

        XCTAssertEqual(disposition, .confirmVisible)
    }

    func testCyclingWithoutTrustedVehicleEvidenceDefersToDiagnostics() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            hasCyclingHint: true
        ))

        XCTAssertEqual(disposition, .deferToDiagnostics(.cyclingMotionConflict))
    }

    func testAutomotiveWithoutTrustedVehicleEvidenceKeepsCollectingWithoutConfirming() {
        // Automotive-only evidence must never confirm a visible trip, but it
        // must not be killed either (2026-07-07 driveway creep) — it keeps
        // collecting until reported speed arrives or the candidate expires.
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testSpeedOnlyWithoutTrustedVehicleEvidenceDefersToDiagnostics() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            hasReportedSpeedEvidence: true,
            hasMeaningfulDisplacement: true
        ))

        XCTAssertEqual(disposition, .deferToDiagnostics(.speedOnlyNoAssist))
    }

    func testStrongUnambiguousEvidenceConfirmsWithoutTrust() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 800,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .confirmVisible)
    }

    func testShortSustainedEvidenceConfirmsWithoutTrust() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 87,
            distanceMeters: 219,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .confirmVisible)
    }

    func testFallbackRequiresReportedSpeed() {
        // Derived speed alone must never CONFIRM (it double-counts
        // displacement), but automotive + a measured speed is promising enough
        // to keep collecting instead of killing — the candidate still only
        // resolves through reported speed or its expiry.
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 800,
            hasDerivedSpeedEvidence: true,
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    /// 2026-07-07 regression (12 mini): automotive + reported speed with
    /// displacement still under the bar and a stationary hint inside the
    /// contradiction hold was killed as stationaryMotionConflict — four times
    /// in six seconds — instead of being given time to accrue displacement.
    func testStationaryConflictWithAutomotiveAndSpeedKeepsCollecting() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 25,
            distanceMeters: 68,
            hasReportedSpeedEvidence: true,
            hasDerivedSpeedEvidence: true,
            hasMeaningfulDisplacement: false,
            hasAutomotiveHint: true,
            hasStationaryHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testPedestrianConflictStillDefersDespiteAutomotiveAndSpeed() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 25,
            distanceMeters: 68,
            hasReportedSpeedEvidence: true,
            hasMeaningfulDisplacement: false,
            hasAutomotiveHint: true,
            hasPedestrianHint: true
        ))

        XCTAssertEqual(disposition, .deferToDiagnostics(.pedestrianMotionConflict))
    }

    /// 2026-07-07 afternoon regression (12 mini driveway creep): automotive
    /// hint with NO measured speed yet at 29–32 m was still being killed as
    /// stationaryMotionConflict every two seconds while the car crept out.
    func testStationaryConflictWithoutSpeedKeepsCollecting() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 25,
            distanceMeters: 29,
            hasMeaningfulDisplacement: false,
            hasAutomotiveHint: true,
            hasStationaryHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testFallbackRejectsCyclingConflict() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 800,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true,
            hasCyclingHint: true
        ))

        XCTAssertEqual(disposition, .deferToDiagnostics(.cyclingMotionConflict))
    }

    func testFallbackRejectsPedestrianConflict() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 800,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true,
            hasPedestrianHint: true
        ))

        XCTAssertEqual(disposition, .deferToDiagnostics(.pedestrianMotionConflict))
    }

    func testFallbackKeepsCollectingBelowElapsedThreshold() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 30,
            distanceMeters: 800,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testFallbackKeepsCollectingBelowDistanceThreshold() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 190,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true
        ))

        XCTAssertEqual(disposition, .continueCollecting)
    }

    func testFallbackToleratesStationaryHint() {
        let disposition = DriveCandidateConfirmationPolicy().disposition(for: evidence(
            elapsed: 60,
            distanceMeters: 800,
            hasReportedSpeedEvidence: true,
            hasAutomotiveHint: true,
            hasStationaryHint: true
        ))

        XCTAssertEqual(disposition, .confirmVisible)
    }

    private func evidence(
        elapsed: TimeInterval = 30,
        sampleCount: Int = 4,
        distanceMeters: Double = 500,
        hasMovementEvidence: Bool = true,
        hasReportedSpeedEvidence: Bool = false,
        hasDerivedSpeedEvidence: Bool = false,
        hasMeaningfulDisplacement: Bool = true,
        hasAutomotiveHint: Bool = false,
        hasCyclingHint: Bool = false,
        hasPedestrianHint: Bool = false,
        hasStationaryHint: Bool = false,
        hasTrustedVehicleEvidence: Bool = false
    ) -> DriveCandidateEvidence {
        DriveCandidateEvidence(
            elapsed: elapsed,
            sampleCount: sampleCount,
            distanceMeters: distanceMeters,
            hasMovementEvidence: hasMovementEvidence,
            hasReportedSpeedEvidence: hasReportedSpeedEvidence,
            hasDerivedSpeedEvidence: hasDerivedSpeedEvidence,
            hasMeaningfulDisplacement: hasMeaningfulDisplacement,
            hasAutomotiveHint: hasAutomotiveHint,
            hasCyclingHint: hasCyclingHint,
            hasPedestrianHint: hasPedestrianHint,
            hasStationaryHint: hasStationaryHint,
            hasTrustedVehicleEvidence: hasTrustedVehicleEvidence
        )
    }
}
