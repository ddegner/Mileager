import AppCore

@MainActor
extension MileageAppModel {
    func refreshVehicleAutomationReceipt() {
        lastVehicleAutomationReceivedAt = preferences.lastVehicleAutomationReceivedAt
    }

    @discardableResult
    func setAutomaticTripStartMode(_ mode: AutomaticTripStartMode) -> Bool {
        guard platform.capturesDrives else { return false }
        automaticTripStartMode = mode
        return true
    }
}
