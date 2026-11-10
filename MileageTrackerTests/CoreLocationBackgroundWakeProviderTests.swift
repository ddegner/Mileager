import AppCore
import CoreLocation
import XCTest

/// ADR-005: the once-per-process SLC/visits re-arm is load-bearing (a
/// relaunched process must call the start methods again or the triggering
/// event is never delivered), while `forceRearm` is the foreground self-heal
/// that bypasses the in-process guard.
@MainActor
final class CoreLocationBackgroundWakeProviderTests: XCTestCase {
    func testStartMonitoringArmsOncePerProcess() {
        let manager = BackgroundWakeCapturingLocationManager()
        let provider = CoreLocationBackgroundWakeProvider(locationManager: manager)

        provider.startMonitoring()
        provider.startMonitoring()

        XCTAssertTrue(provider.isMonitoring)
        XCTAssertEqual(manager.slcStartCount, 1)
        XCTAssertEqual(manager.visitStartCount, 1)
    }

    func testForceRearmBypassesInProcessGuard() {
        let manager = BackgroundWakeCapturingLocationManager()
        let provider = CoreLocationBackgroundWakeProvider(locationManager: manager)

        provider.startMonitoring()
        provider.forceRearm()

        XCTAssertTrue(provider.isMonitoring)
        XCTAssertEqual(manager.slcStartCount, 2, "self-heal must re-assert even when the in-process flag says armed")
        XCTAssertEqual(manager.visitStartCount, 2)
    }

    func testStopMonitoringClearsRegistrations() {
        let manager = BackgroundWakeCapturingLocationManager()
        let provider = CoreLocationBackgroundWakeProvider(locationManager: manager)

        provider.startMonitoring()
        provider.stopMonitoring()

        XCTAssertFalse(provider.isMonitoring)
        XCTAssertEqual(manager.slcStopCount, 1)
        XCTAssertEqual(manager.visitStopCount, 1)
    }
}

private final class BackgroundWakeCapturingLocationManager: CLLocationManager {
    private(set) var slcStartCount = 0
    private(set) var slcStopCount = 0
    private(set) var visitStartCount = 0
    private(set) var visitStopCount = 0

    override func startMonitoringSignificantLocationChanges() { slcStartCount += 1 }
    override func stopMonitoringSignificantLocationChanges() { slcStopCount += 1 }
    override func startMonitoringVisits() { visitStartCount += 1 }
    override func stopMonitoringVisits() { visitStopCount += 1 }
}
