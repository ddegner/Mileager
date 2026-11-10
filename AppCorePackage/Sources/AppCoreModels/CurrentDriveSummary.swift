import Foundation

/// Portable display data for the vehicle attributed to the in-progress drive.
/// Capture state stores only the vehicle ID; the app hydrates this snapshot from
/// the synced vehicle profile before handing the summary to UI and ActivityKit.
public struct CurrentDriveVehicleSnapshot: Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var symbolName: String?
    public var colorHex: String?
    public var isConfirmed: Bool

    public init(
        id: UUID,
        name: String,
        symbolName: String? = nil,
        colorHex: String? = nil,
        isConfirmed: Bool
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.isConfirmed = isConfirmed
    }
}

public struct CurrentDriveSummary: Equatable, Sendable, Codable {
    public enum Phase: String, Sendable, Codable {
        case recording
        case paused
        case confirmingTripEnd
    }

    /// Strings shared by the in-app live drive bar and the Live Activity, so
    /// one vocabulary serves both surfaces.
    ///
    /// These live here rather than in either surface's own catalog because
    /// `MileageTrackerWidgets` has a String Catalog that
    /// `scripts/verify_ios_localizations.py` never opens — the widget target
    /// appears only in `swift_source_blob`, not in the checked catalog list —
    /// so a label spelled only there can lose its de/es/fr coverage with no
    /// build error and no validation failure. It is also the only way the
    /// widget can reach these strings at all: `Bundle.appCoreStrings` is
    /// `package`-scoped, so an extension outside the package cannot perform
    /// its own AppCore lookups and must go through public properties.
    public enum Strings {
        public static var chooseVehicle: String {
            String(localized: "Choose vehicle", bundle: .appCoreStrings)
        }

        public static var lastMovement: String {
            String(localized: "Last movement", bundle: .appCoreStrings)
        }

        public static var distance: String {
            String(localized: "Distance", bundle: .appCoreStrings)
        }

        public static var elapsed: String {
            String(localized: "Elapsed", bundle: .appCoreStrings)
        }

        public static var newLeg: String {
            String(localized: "New Leg", bundle: .appCoreStrings)
        }

        public static var startNewLeg: String {
            String(localized: "Start new leg", bundle: .appCoreStrings)
        }

        public static var vehicle: String {
            String(localized: "Vehicle", bundle: .appCoreStrings)
        }
    }

    public var phase: Phase
    public var startedAt: Date
    public var lastMovingAt: Date?
    public var distanceMeters: Double
    public var originLabel: String?
    public var pendingTripID: UUID
    public var classification: TripClassification?
    public var businessPurpose: String?
    public var note: String?
    public var feeCount: Int
    /// Vehicle the finished trip will carry: a live-bar pick or the arming
    /// Shortcut's vehicle. nil = automatic resolution at completion.
    public var vehicleID: UUID?
    /// Why `vehicleID` is present. The UI uses this to keep a manual mid-drive
    /// correction separate from the optional "Remember this connection" step.
    public var vehicleAssignmentSource: VehicleAssignmentSource?
    /// Different mapped vehicles observed after the drive's first confident
    /// vehicle was latched. Presentation can warn without silently switching.
    public var conflictingVehicleIDs: [UUID]
    public var vehicle: CurrentDriveVehicleSnapshot?

    public init(
        phase: Phase,
        startedAt: Date,
        lastMovingAt: Date? = nil,
        distanceMeters: Double,
        originLabel: String? = nil,
        pendingTripID: UUID,
        classification: TripClassification? = nil,
        businessPurpose: String? = nil,
        note: String? = nil,
        feeCount: Int = 0,
        vehicleID: UUID? = nil,
        vehicleAssignmentSource: VehicleAssignmentSource? = nil,
        conflictingVehicleIDs: [UUID] = [],
        vehicle: CurrentDriveVehicleSnapshot? = nil
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.lastMovingAt = lastMovingAt
        self.distanceMeters = distanceMeters
        self.originLabel = originLabel
        self.pendingTripID = pendingTripID
        self.classification = classification
        self.businessPurpose = businessPurpose
        self.note = note
        self.feeCount = feeCount
        self.vehicleID = vehicleID
        self.vehicleAssignmentSource = vehicleAssignmentSource
        self.conflictingVehicleIDs = conflictingVehicleIDs
        self.vehicle = vehicle
    }
}

public extension CurrentDriveSummary.Phase {
    /// The one phase vocabulary, shared by the live drive bar and the Live
    /// Activity / Dynamic Island. See `CurrentDriveSummary.Strings` for why
    /// these resolve from the package catalog rather than either surface's own.
    ///
    /// Deliberately NOT adopted by `CurrentDriveAppEntity.intentDisplayName`,
    /// which uses a more formal Siri register ("Confirming Drive End").
    var displayName: String {
        switch self {
        case .recording:
            String(localized: "Recording", bundle: .appCoreStrings)
        case .paused:
            String(localized: "Paused", bundle: .appCoreStrings)
        case .confirmingTripEnd:
            String(localized: "Checking stop…", bundle: .appCoreStrings)
        }
    }
}

/// Display helpers for the in-progress drive that both surfaces need.
///
/// These sit in `AppCoreModels` rather than on
/// `MileageDriveActivityAttributes.ContentState`, whose file is wrapped in
/// `#if os(iOS) && canImport(ActivityKit)` and therefore compiles out of the
/// macOS `swift test` run — anything defined there is untestable by
/// `swift test --package-path AppCorePackage`.
public enum CurrentDriveDisplay {
    /// The vehicle name, or the prompt shown when a drive has no vehicle yet.
    public static func vehicleName(_ name: String?) -> String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CurrentDriveSummary.Strings.chooseVehicle
        }
        return name
    }

    /// Formats a distance for display, tolerating a missing unit.
    ///
    /// Live Activities started before the unit preference existed carry no
    /// `distanceUnitRaw`; those fall back to miles rather than failing to render.
    public static func distanceLabel(meters: Double, unitRaw: String?) -> String {
        let unit = unitRaw.flatMap(DistanceUnit.init(rawValue:)) ?? .miles
        return DistanceFormatting.label(meters: meters, unit: unit)
    }
}
