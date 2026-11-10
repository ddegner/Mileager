import AppCore

extension TrackingHealth {
    var isAllClear: Bool {
        alwaysLocationAuthorized &&
            preciseLocationEnabled &&
            motionAuthorized &&
            backgroundRefreshAvailable &&
            issues.isEmpty
    }
}
