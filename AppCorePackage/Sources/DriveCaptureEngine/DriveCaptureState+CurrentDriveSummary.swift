import AppCoreModels
import Foundation

public extension DriveCaptureState {
    /// Returns nil unless the state represents an active in-progress drive.
    func currentDriveSummary(distanceMeters overrideDistanceMeters: Double? = nil) -> CurrentDriveSummary? {
        let phase: CurrentDriveSummary.Phase
        switch self.phase {
        case .recording:
            phase = parkingEvidence.map({ $0.signal != .trafficStopHold }) == true
                ? .confirmingTripEnd
                : .recording
        case .paused where !samples.isEmpty:
            phase = .paused
        case .idle, .candidate, .paused:
            return nil
        }

        guard let startedAt,
              let pendingTripID else {
            return nil
        }

        let distanceMeters = overrideDistanceMeters ?? DistanceCalculator.routeDistanceMeters(
            samples: samples,
            maxAccuracy: configuration.maxHorizontalAccuracyMeters,
            maxSegmentSpeedMetersPerSecond: configuration.maxSegmentSpeedMetersPerSecond
        )

        return CurrentDriveSummary(
            phase: phase,
            startedAt: startedAt,
            lastMovingAt: lastMovingAt,
            distanceMeters: distanceMeters,
            originLabel: nil,
            pendingTripID: pendingTripID,
            classification: pendingClassification,
            businessPurpose: pendingBusinessPurpose,
            note: pendingNote,
            feeCount: pendingFees.count,
            vehicleID: startVehicleHint,
            vehicleAssignmentSource: startVehicleAssignmentSource,
            conflictingVehicleIDs: conflictingVehicleIDs
        )
    }
}
