import AppCore
import CoreLocation
import XCTest

@MainActor
final class CoreLocationRegionIdleWakeProviderTests: XCTestCase {
    private static let regionIdentifier = "MileageTrackerParkedAnchor"

    private func anchor(lat: Double = 42.3682954, lon: Double = -71.1046248) -> LocationSample {
        LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            latitude: lat,
            longitude: lon,
            horizontalAccuracy: 8
        )
    }

    private func region(
        lat: Double = 42.3682954,
        lon: Double = -71.1046248,
        identifier: String = regionIdentifier
    ) -> CLCircularRegion {
        CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            radius: 250,
            identifier: identifier
        )
    }

    func testStartMonitoringWritesBeaconAndStopClearsIt() {
        let beacon = RegionTestBeacon()
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: RegionCapturingLocationManager(),
            systemRegionRegistrationEnabled: false
        )

        provider.startMonitoring(anchor: anchor())
        XCTAssertTrue(provider.isMonitoring)
        XCTAssertEqual(beacon.stored?.radius ?? 0, 250, accuracy: 0.001)

        provider.stopMonitoring()
        XCTAssertFalse(provider.isMonitoring)
        XCTAssertNil(beacon.stored)
        XCTAssertEqual(beacon.clearCount, 1)
    }

    func testSuspendMonitoringStopsRegionButPreservesBeacon() {
        let beacon = RegionTestBeacon()
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: RegionCapturingLocationManager(),
            systemRegionRegistrationEnabled: false
        )

        provider.startMonitoring(anchor: anchor())
        XCTAssertTrue(provider.isMonitoring)
        XCTAssertNotNil(beacon.stored)

        provider.suspendMonitoring()
        XCTAssertFalse(provider.isMonitoring, "active region monitoring is torn down")
        XCTAssertNotNil(beacon.stored, "the cold-relaunch beacon is preserved while the anchor is authoritative")
        XCTAssertEqual(beacon.clearCount, 0, "suspend must not clear the parked-anchor beacon")
    }

    func testRestoreFromBeaconArmsMonitoring() {
        let beacon = RegionTestBeacon()
        beacon.stored = StoredParkingAnchor(
            latitude: 42.3682954,
            longitude: -71.1046248,
            radius: 250,
            horizontalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: RegionCapturingLocationManager(),
            systemRegionRegistrationEnabled: false
        )

        XCTAssertFalse(provider.isMonitoring)
        provider.restoreMonitoringIfNeeded()
        XCTAssertTrue(provider.isMonitoring)
    }

    func testRepeatedStartWithSameAnchorDoesNotChurnBeacon() {
        let beacon = RegionTestBeacon()
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: RegionCapturingLocationManager(),
            systemRegionRegistrationEnabled: false
        )

        provider.startMonitoring(anchor: anchor())
        provider.startMonitoring(anchor: anchor())
        XCTAssertEqual(beacon.saveCount, 1)

        provider.startMonitoring(anchor: anchor(lat: 42.40))
        XCTAssertEqual(beacon.saveCount, 2)
    }

    func testDidExitRegionFiresWake() async {
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: RegionTestBeacon(),
            systemRegionRegistrationEnabled: false,
            reconcileStateOnRegistration: false
        )
        provider.startMonitoring(anchor: anchor())
        let wake = expectation(description: "wake")
        provider.onWake = { _ in wake.fulfill() }

        provider.locationManager(CLLocationManager(), didExitRegion: region())

        await fulfillment(of: [wake], timeout: 1)
    }

    func testDidExitRegionIgnoresUnknownRegion() async {
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: RegionTestBeacon(),
            systemRegionRegistrationEnabled: false,
            reconcileStateOnRegistration: false
        )
        provider.startMonitoring(anchor: anchor())
        let wake = expectation(description: "no wake")
        wake.isInverted = true
        provider.onWake = { _ in wake.fulfill() }

        provider.locationManager(CLLocationManager(), didExitRegion: region(identifier: "some-other-region"))

        await fulfillment(of: [wake], timeout: 0.3)
    }

    func testDidDetermineOutsideStateReconcilesIntoWake() async {
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: RegionTestBeacon(),
            systemRegionRegistrationEnabled: false,
            reconcileStateOnRegistration: false
        )
        provider.startMonitoring(anchor: anchor())
        let wake = expectation(description: "wake")
        provider.onWake = { _ in wake.fulfill() }

        provider.locationManager(CLLocationManager(), didDetermineState: .outside, for: region())

        await fulfillment(of: [wake], timeout: 1)
    }

    func testDidDetermineInsideStateDoesNotWake() async {
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: RegionTestBeacon(),
            systemRegionRegistrationEnabled: false,
            reconcileStateOnRegistration: false
        )
        provider.startMonitoring(anchor: anchor())
        let wake = expectation(description: "no wake")
        wake.isInverted = true
        provider.onWake = { _ in wake.fulfill() }

        provider.locationManager(CLLocationManager(), didDetermineState: .inside, for: region())

        await fulfillment(of: [wake], timeout: 0.3)
    }

    // MARK: - Adopt-or-register (ADR-005, 2026-07-07 parked wake-churn)

    private func storedAnchor(lat: Double = 42.3682954, lon: Double = -71.1046248) -> StoredParkingAnchor {
        StoredParkingAnchor(
            latitude: lat,
            longitude: lon,
            radius: 250,
            horizontalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func makeAdoptionFixture(
        beaconStored: Bool = true,
        seededRegion: CLCircularRegion? = nil
    ) -> (provider: CoreLocationRegionDriveIdleWakeProvider, manager: RegionCapturingLocationManager, beacon: RegionTestBeacon) {
        let beacon = RegionTestBeacon()
        if beaconStored { beacon.stored = storedAnchor() }
        let manager = RegionCapturingLocationManager()
        if let seededRegion { manager.seed(region: seededRegion) }
        let provider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: manager
        )
        return (provider, manager, beacon)
    }

    func testRestoreAdoptsMatchingSystemRegion() {
        let (provider, manager, _) = makeAdoptionFixture(seededRegion: region())

        let outcome = provider.restoreMonitoringIfNeeded()

        XCTAssertEqual(outcome, .adopted)
        XCTAssertTrue(provider.isMonitoring)
        XCTAssertEqual(manager.startMonitoringCount, 0, "adoption must make zero Core Location calls")
        XCTAssertEqual(manager.stopMonitoringCount, 0)
        XCTAssertEqual(manager.requestStateCount, 0, "requestState per relaunch was the churn loop")
    }

    func testRestoreReRegistersWhenSystemRegionMissing() {
        let (provider, manager, _) = makeAdoptionFixture()

        let outcome = provider.restoreMonitoringIfNeeded()

        XCTAssertEqual(outcome, .rearmed)
        XCTAssertTrue(provider.isMonitoring)
        XCTAssertEqual(manager.startMonitoringCount, 1)
        XCTAssertEqual(manager.requestStateCount, 1, "true registration keeps the already-outside catch-up")
    }

    func testRestoreReRegistersOnCenterMismatch() {
        let (provider, manager, _) = makeAdoptionFixture(seededRegion: region(lat: 42.3690000))

        let outcome = provider.restoreMonitoringIfNeeded()

        XCTAssertEqual(outcome, .rearmed)
        XCTAssertEqual(manager.startMonitoringCount, 1)
        XCTAssertEqual(manager.stopMonitoringCount, 1, "the stale copy is removed before re-registering")
    }

    func testRestoreReRegistersOnRadiusMismatch() {
        let stale = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 42.3682954, longitude: -71.1046248),
            radius: 400,
            identifier: Self.regionIdentifier
        )
        let (provider, manager, _) = makeAdoptionFixture(seededRegion: stale)

        XCTAssertEqual(provider.restoreMonitoringIfNeeded(), .rearmed)
        XCTAssertEqual(manager.startMonitoringCount, 1)
    }

    func testRestoreRemovesOrphanRegionWhenBeaconMissing() {
        let (provider, manager, _) = makeAdoptionFixture(beaconStored: false, seededRegion: region())

        let outcome = provider.restoreMonitoringIfNeeded()

        XCTAssertEqual(outcome, .cleanedUpOrphan)
        XCTAssertFalse(provider.isMonitoring)
        XCTAssertEqual(manager.stopMonitoringCount, 1)
        XCTAssertTrue(manager.registeredRegions.isEmpty, "an orphan fence can relaunch the app indefinitely")
    }

    func testRestoreWithoutBeaconOrRegionIsNoOp() {
        let (provider, manager, _) = makeAdoptionFixture(beaconStored: false)

        XCTAssertEqual(provider.restoreMonitoringIfNeeded(), .notNeeded)
        XCTAssertFalse(provider.isMonitoring)
        XCTAssertEqual(manager.startMonitoringCount + manager.stopMonitoringCount + manager.requestStateCount, 0)
    }

    func testAnchorChangeAfterAdoptStillReRegisters() {
        let (provider, manager, beacon) = makeAdoptionFixture(seededRegion: region())
        XCTAssertEqual(provider.restoreMonitoringIfNeeded(), .adopted)

        provider.startMonitoring(anchor: anchor(lat: 42.4200000))

        XCTAssertEqual(manager.startMonitoringCount, 1, "a changed anchor must always re-register (ADR-001)")
        XCTAssertEqual(manager.requestStateCount, 1)
        XCTAssertEqual(beacon.saveCount, 1)
    }

    func testDetachPreservesRegionAndBeaconAndNextProviderAdopts() {
        // Keeper handoff: provider A registers, detaches; provider B (fresh
        // process stand-in, same system state) adopts with zero CL calls.
        let beacon = RegionTestBeacon()
        let manager = RegionCapturingLocationManager()
        let keeperProvider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: manager
        )
        keeperProvider.startMonitoring(anchor: anchor())
        XCTAssertEqual(manager.startMonitoringCount, 1)

        keeperProvider.detachMonitoring()
        XCTAssertFalse(keeperProvider.isMonitoring)
        XCTAssertNotNil(beacon.stored, "detach preserves the beacon")
        XCTAssertFalse(manager.registeredRegions.isEmpty, "detach preserves the system registration")

        let runtimeProvider = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: manager
        )
        XCTAssertEqual(runtimeProvider.restoreMonitoringIfNeeded(), .adopted)
        XCTAssertTrue(runtimeProvider.isMonitoring)
        XCTAssertEqual(manager.startMonitoringCount, 1, "the handoff must not re-register")
        XCTAssertEqual(manager.requestStateCount, 1, "only the original registration reconciles state")
    }

    /// 2026-07-07 churn replay: iOS relaunched the app every 2-6 minutes while
    /// parked; each relaunch re-registered the region and forced a
    /// `requestState` location determination, keeping the location arrow lit.
    /// Five cold relaunches over an unchanged anchor must produce exactly one
    /// registration and one state request — the rest adopt.
    func testFiveColdRelaunchesProduceZeroReRegistrations() {
        let beacon = RegionTestBeacon()
        let manager = RegionCapturingLocationManager()
        let original = CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: 250,
            beacon: beacon,
            locationManager: manager
        )
        original.startMonitoring(anchor: anchor())

        for relaunch in 1...5 {
            let fresh = CoreLocationRegionDriveIdleWakeProvider(
                radiusMeters: 250,
                beacon: beacon,
                locationManager: manager
            )
            XCTAssertEqual(fresh.restoreMonitoringIfNeeded(), .adopted, "relaunch \(relaunch) must adopt")
        }

        XCTAssertEqual(manager.startMonitoringCount, 1)
        XCTAssertEqual(manager.requestStateCount, 1)
        XCTAssertEqual(manager.stopMonitoringCount, 0)
    }

    func testForegroundVerifyRearmsWhenRegistrationLost() {
        let (provider, manager, _) = makeAdoptionFixture(seededRegion: region())
        XCTAssertEqual(provider.restoreMonitoringIfNeeded(), .adopted)

        // Location Services toggle / system reset: registrations vanish.
        manager.clearSeededRegions()

        XCTAssertTrue(provider.verifyOrRearmSystemRegistrationOnForeground())
        XCTAssertEqual(manager.startMonitoringCount, 1, "the lost registration is re-armed")
        XCTAssertFalse(manager.registeredRegions.isEmpty)
    }

    func testForegroundVerifyOnlyRequestsStateWhenPresent() {
        let (provider, manager, _) = makeAdoptionFixture(seededRegion: region())
        XCTAssertEqual(provider.restoreMonitoringIfNeeded(), .adopted)

        XCTAssertFalse(provider.verifyOrRearmSystemRegistrationOnForeground())
        XCTAssertEqual(manager.startMonitoringCount, 0)
        XCTAssertEqual(manager.requestStateCount, 1, "the adopt path's missed-exit catch-up lives here")
    }
}

/// CLLocationManager stand-in that records registration traffic and lets tests
/// seed the system-persisted region set a fresh process would observe.
private final class RegionCapturingLocationManager: CLLocationManager {
    private var backing: Set<CLRegion> = []
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringCount = 0
    private(set) var requestStateCount = 0

    var registeredRegions: Set<CLRegion> { backing }

    func seed(region: CLRegion) {
        backing.insert(region)
    }

    func clearSeededRegions() {
        backing.removeAll()
    }

    override var monitoredRegions: Set<CLRegion> { backing }

    override func startMonitoring(for region: CLRegion) {
        startMonitoringCount += 1
        backing = backing.filter { $0.identifier != region.identifier }
        backing.insert(region)
    }

    override func stopMonitoring(for region: CLRegion) {
        stopMonitoringCount += 1
        backing = backing.filter { $0.identifier != region.identifier }
    }

    override func requestState(for region: CLRegion) {
        requestStateCount += 1
    }
}

private final class RegionTestBeacon: ParkingAnchorBeaconStoring {
    var stored: StoredParkingAnchor?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func save(anchor: LocationSample, radius: CLLocationDistance) {
        saveCount += 1
        stored = StoredParkingAnchor(
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            radius: radius,
            horizontalAccuracy: anchor.horizontalAccuracy,
            timestamp: anchor.timestamp
        )
    }

    func load() -> StoredParkingAnchor? { stored }

    func clear() {
        clearCount += 1
        stored = nil
    }
}
