import Foundation

/// Centralized parser/builder for the app's `mileager://` deep links, shared by
/// the app's URL handler, the Live Activity / widget, and any intents that need
/// to construct a link. Keeping both halves here guarantees the routes the
/// widget builds are exactly the routes the app parses.
public enum DeepLinkRoute: Equatable, Sendable {
    /// Open the current-drive sheet for the active drive.
    case currentDrive(tripID: UUID)
    /// Open the active drive's vehicle picker.
    case currentDriveVehicle(tripID: UUID)
    /// Open the fee-entry sheet for the active drive, pre-selecting a category.
    case currentDriveFee(tripID: UUID, category: TripFeeCategory)
    /// Split the active drive into a new leg. An ACTION route, not a
    /// presentation: the app performs it and opens no sheet. Deliberately a
    /// deep link rather than a `Button(intent:)` — an App Intent bypasses App
    /// Lock entirely (`TripIntentDataProvider.availableModel()` checks only
    /// `isAwaitingProtectedData`), while a link foregrounds the app and
    /// inherits every gate the app already applies.
    case currentDriveNewLeg(tripID: UUID)

    public static let scheme = "mileager"
    private static let driveHost = "drive"
    private static let feeSegment = "fee"
    private static let vehicleSegment = "vehicle"
    private static let newLegSegment = "new-leg"

    /// Parses a `mileager://drive/<id>[/vehicle|/new-leg|/fee/<toll|parking>]`
    /// URL, returning nil for anything that doesn't match a known route.
    public static func parse(_ url: URL) -> DeepLinkRoute? {
        guard url.scheme == scheme, url.host == driveHost else { return nil }

        // pathComponents includes a leading "/" element; drop it so we are left
        // with the trip id followed by any sub-route segments.
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let idSegment = segments.first,
              let tripID = UUID(uuidString: idSegment) else {
            return nil
        }

        let rest = segments.dropFirst()
        switch rest.count {
        case 0:
            return .currentDrive(tripID: tripID)
        case 1:
            // A nested switch rather than stacked `where` clauses so a fourth
            // one-segment route stays a one-line addition.
            switch rest.first {
            case vehicleSegment: return .currentDriveVehicle(tripID: tripID)
            case newLegSegment: return .currentDriveNewLeg(tripID: tripID)
            default: return nil
            }
        case 2 where rest.first == feeSegment:
            guard let category = TripFeeCategory(rawValue: rest.last ?? "") else { return nil }
            return .currentDriveFee(tripID: tripID, category: category)
        default:
            return nil
        }
    }

    /// Builds the canonical URL for this route. Round-trips with `parse`.
    public var url: URL {
        switch self {
        case .currentDrive(let tripID):
            return URL(string: "\(Self.scheme)://\(Self.driveHost)/\(tripID.uuidString)")!
        case .currentDriveVehicle(let tripID):
            return URL(string: "\(Self.scheme)://\(Self.driveHost)/\(tripID.uuidString)/\(Self.vehicleSegment)")!
        case .currentDriveFee(let tripID, let category):
            return URL(string: "\(Self.scheme)://\(Self.driveHost)/\(tripID.uuidString)/\(Self.feeSegment)/\(category.rawValue)")!
        case .currentDriveNewLeg(let tripID):
            return URL(string: "\(Self.scheme)://\(Self.driveHost)/\(tripID.uuidString)/\(Self.newLegSegment)")!
        }
    }
}
