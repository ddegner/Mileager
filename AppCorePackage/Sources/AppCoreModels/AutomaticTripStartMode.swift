/// The user's admission policy for a new automatically recorded drive.
/// Vehicle detection confidence and permission to record are separate facts.
public enum AutomaticTripStartMode: String, Codable, CaseIterable, Sendable {
    // Keep the persisted values so an existing selection survives this UI and
    // trigger-policy clarification.
    case motionDetection = "allDrives"
    case bluetoothOrCarPlay = "savedCarsOnly"
    case both = "both"
}
