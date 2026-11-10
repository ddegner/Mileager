#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import AppCoreModels
import Foundation

public struct MileageDriveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var distanceMeters: Double
        public var startedAt: Date
        /// Retained for activities started before the richer phase payload was
        /// introduced. New code should read `phase`.
        public var isPaused: Bool
        /// Optional so an activity created by an older app version still
        /// decodes after an update.
        public var phaseRaw: String?
        public var lastMovingAt: Date?
        public var vehicle: CurrentDriveVehicleSnapshot?
        public var classification: String?
        public var businessPurpose: String?
        public var feeCount: Int
        /// `DistanceUnit.rawValue` for the widget's distance label. Optional so
        /// activities started by pre-unit-preference app versions still decode;
        /// the widget falls back to miles when absent.
        public var distanceUnitRaw: String?

        public init(
            distanceMeters: Double,
            startedAt: Date,
            isPaused: Bool,
            phaseRaw: String? = nil,
            lastMovingAt: Date? = nil,
            vehicle: CurrentDriveVehicleSnapshot? = nil,
            classification: String? = nil,
            businessPurpose: String? = nil,
            feeCount: Int = 0,
            distanceUnitRaw: String? = nil
        ) {
            self.distanceMeters = distanceMeters
            self.startedAt = startedAt
            self.isPaused = isPaused
            self.phaseRaw = phaseRaw
            self.lastMovingAt = lastMovingAt
            self.vehicle = vehicle
            self.classification = classification
            self.businessPurpose = businessPurpose
            self.feeCount = feeCount
            self.distanceUnitRaw = distanceUnitRaw
        }

        public init(summary: CurrentDriveSummary, distanceUnit: DistanceUnit = .miles) {
            self.init(
                distanceMeters: summary.distanceMeters,
                startedAt: summary.startedAt,
                isPaused: summary.phase == .paused,
                phaseRaw: summary.phase.rawValue,
                lastMovingAt: summary.lastMovingAt,
                vehicle: summary.vehicle,
                classification: summary.classification?.rawValue,
                businessPurpose: summary.businessPurpose,
                feeCount: summary.feeCount,
                distanceUnitRaw: distanceUnit.rawValue
            )
        }

        public var phase: CurrentDriveSummary.Phase {
            phaseRaw.flatMap(CurrentDriveSummary.Phase.init(rawValue:))
                ?? (isPaused ? .paused : .recording)
        }

        /// The vehicle's name, or the "Choose vehicle" prompt.
        ///
        /// These are computed, so they do not participate in `Codable` and
        /// cannot break an in-flight activity's decode across an app update.
        /// The logic itself lives in `AppCoreModels` because this file is
        /// wrapped in `#if os(iOS) && canImport(ActivityKit)` and so compiles
        /// out of the macOS `swift test` run.
        public var vehicleDisplayName: String {
            CurrentDriveDisplay.vehicleName(vehicle?.name)
        }

        public var vehicleSymbolName: String {
            VehiclePalette.symbolName(vehicle?.symbolName)
        }

        public var classificationValue: TripClassification? {
            classification.flatMap(TripClassification.init(rawValue:))
        }

        public var distanceLabel: String {
            CurrentDriveDisplay.distanceLabel(meters: distanceMeters, unitRaw: distanceUnitRaw)
        }
    }

    public var pendingTripID: UUID

    public init(pendingTripID: UUID) {
        self.pendingTripID = pendingTripID
    }
}
#endif
