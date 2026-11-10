import AppCoreModels
import Foundation

/// Decides whether a learned Bluetooth device should be trusted as a vehicle,
/// based purely on review outcomes: classifying a drive (business/personal) is
/// positive evidence for the devices present at its start, marking a capture
/// "Not a Drive" is negative evidence.
///
/// The vehicle name matcher acts as a prior, not a gate: devices with
/// car-like names need less evidence, rejected-term names (headphones etc.)
/// need much more, but any device can earn or lose trust.
public struct VehicleTrustPolicy: Sendable {
    public init() {}

    /// Negative evidence dominates: a device repeatedly present at the start
    /// of captures the user rejected is blocked from contributing detection
    /// signals, even if it accumulated confirmations earlier.
    public func isBlocked(confirmed: Int, notADrive: Int) -> Bool {
        notADrive >= 2 && notADrive >= confirmed
    }

    public func isTrusted(confirmed: Int, notADrive: Int, displayName: String?) -> Bool {
        guard !isBlocked(confirmed: confirmed, notADrive: notADrive) else { return false }
        return confirmed >= Self.trustThreshold(displayName: displayName)
            && confirmed >= 2 * notADrive
    }

    package static func trustThreshold(displayName: String?) -> Int {
        switch BluetoothVehicleNameMatcher.classify(displayName) {
        case .vehicle: 2
        case .unknown: 3
        case .rejected: 5
        }
    }
}
