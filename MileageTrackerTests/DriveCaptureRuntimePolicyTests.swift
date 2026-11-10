import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

@MainActor
final class DriveCaptureRuntimePolicyTests: XCTestCase {
    func testThreeModesDistinguishPendingCarAutomationFromPassiveMotion() throws {
        for mode in AutomaticTripStartMode.allCases {
            let automated = try makeHarness(automaticTripStartMode: mode)
            _ = try automated.pendingStore.save(trigger: .carPlay, at: Date(), policy: .balanced)
            automated.runtime.startMonitoring()
            XCTAssertEqual(automated.runtime.state.phase, mode == .motionDetection ? .idle : .candidate)

            let passive = try makeHarness(automaticTripStartMode: mode)
            passive.runtime.startMonitoring()
            passive.motion.onActivity?(MotionActivitySnapshot(startDate: Date(), confidence: .high, hints: [.automotive]))
            XCTAssertEqual(passive.runtime.state.phase, mode == .bluetoothOrCarPlay ? .idle : .candidate)
        }
    }

    func testAutomationModeIgnoresMotionRoutesAndUnapprovedShortcutTriggers() throws {
        let harness = try makeHarness(automaticTripStartMode: .bluetoothOrCarPlay)
        harness.runtime.startMonitoring()
        let start = Date()
        harness.runtime.armDriveStart(trigger: .manual, at: start)
        harness.runtime.armDriveStart(trigger: .charger, at: start)
        harness.runtime.vehicleConnectionChanged(active: true, source: .carPlayAudio, at: start)
        harness.motion.onActivity?(MotionActivitySnapshot(startDate: start, confidence: .high, hints: [.automotive]))
        harness.backgroundWake.onVisitDeparture?(start)
        harness.location.emit(sample: sample(at: start.addingTimeInterval(10), metersNorth: 120, speed: 12, hint: .automotive))
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertTrue(harness.location.startedConfigurations.isEmpty)
        XCTAssertFalse(harness.serviceSession.isActive)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        XCTAssertTrue(harness.completionCoordinator.completedDrafts.isEmpty)
    }

    func testPendingBluetoothAndCarPlayAutomationsStartWithoutSavedVehicleMapping() throws {
        for trigger in [DriveStartExternalTrigger.vehicleBluetooth, .carPlay] {
            let harness = try makeHarness(automaticTripStartMode: .bluetoothOrCarPlay)
            let start = Date()
            _ = try harness.pendingStore.save(trigger: trigger, at: start, policy: .balanced)
            harness.runtime.startMonitoring()
            XCTAssertEqual(harness.runtime.state.phase, .candidate)
            XCTAssertEqual(harness.runtime.state.vehicleAutomationStartSignal?.externalTrigger, trigger)
            XCTAssertNil(harness.runtime.state.startVehicleHint)
            XCTAssertFalse(harness.location.startedConfigurations.isEmpty)
            for offset in [0, 15, 30, 45] {
                harness.location.emit(sample: sample(at: start.addingTimeInterval(Double(offset)), metersNorth: Double(offset) * 12, speed: 12, hint: .automotive))
            }
            XCTAssertEqual(harness.runtime.state.phase, .recording)
            let tripID = harness.runtime.state.pendingTripID
            harness.runtime.vehicleConnectionChanged(active: false, source: .carPlayAudio, at: start.addingTimeInterval(46))
            XCTAssertEqual(harness.runtime.state.phase, .recording)
            XCTAssertEqual(harness.runtime.state.pendingTripID, tripID)
        }
    }

    func testAutomationModeRejectsPendingManualAndChargerSignals() throws {
        let harness = try makeHarness(automaticTripStartMode: .bluetoothOrCarPlay)
        for trigger in [DriveStartExternalTrigger.manual, .charger] {
            _ = try harness.pendingStore.save(trigger: trigger, at: Date(), policy: .balanced)
        }
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertNil(harness.runtime.state.vehicleAutomationStartSignal)
        XCTAssertTrue(harness.location.startedConfigurations.isEmpty)
    }

    func testAutomationCannotStartWhenMonitoringIsOff() throws {
        let harness = try makeHarness(automaticTripStartMode: .bluetoothOrCarPlay)
        harness.runtime.armDriveStart(trigger: .carPlay)
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertNil(harness.runtime.state.vehicleAutomationStartSignal)
        XCTAssertTrue(harness.location.startedConfigurations.isEmpty)
    }

    func testAutomationModeRestoresOnlyExplicitUnexpiredCandidatePermission() throws {
        let start = Date()
        let signal = DriveStartEngine.signal(forExternalTrigger: .carPlay, at: start)
        var state = DriveCaptureState(phase: .candidate, automaticTripStartMode: .bluetoothOrCarPlay)
        state.pendingTripID = UUID()
        state.candidateStartedAt = start
        state.startSignal = signal
        state.vehicleConnectionActive = true
        let missing = try makeHarness(initialState: state, automaticTripStartMode: .bluetoothOrCarPlay)
        missing.runtime.startMonitoring()
        XCTAssertEqual(missing.runtime.state.phase, .idle, "A cached live route is not an automation")
        state.vehicleAutomationStartSignal = signal
        let authorized = try makeHarness(initialState: state, automaticTripStartMode: .bluetoothOrCarPlay)
        authorized.runtime.startMonitoring()
        XCTAssertEqual(authorized.runtime.state.phase, .candidate)
        state.vehicleAutomationStartSignal?.expiresAt = start.addingTimeInterval(-1)
        let expired = try makeHarness(initialState: state, automaticTripStartMode: .bluetoothOrCarPlay)
        expired.runtime.startMonitoring()
        expired.runtime.sceneEnteredBackground()
        XCTAssertEqual(expired.runtime.state.phase, .idle)
        XCTAssertTrue(expired.location.startedConfigurations.isEmpty)
    }

    func testModeSettingBeforeBootstrapCannotOverwriteRecordedCheckpoint() throws {
        let start = Date()
        let tripID = UUID()
        let state = DriveCaptureState(
            pendingTripID: tripID, phase: .recording, automaticTripStartMode: .bluetoothOrCarPlay,
            startedAt: start, samples: [sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)]
        )
        let harness = try makeHarness(initialState: state, automaticTripStartMode: .bluetoothOrCarPlay)
        harness.runtime.setAutomaticTripStartMode(.bluetoothOrCarPlay)
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertEqual(harness.runtime.state.pendingTripID, tripID)
    }

    func testStartMonitoringWithParkedAnchorUsesIdleWakeWithoutHighFidelityGPS() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))

        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.location.startedConfigurations, [])
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.count, 1)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.first, anchor)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        XCTAssertEqual(harness.backgroundWake.startCount, 1)
        XCTAssertFalse(harness.background.isActive)
        // Parked idle-anchored holds no service session — the geofence + SLC/visit
        // wakes need only `.always` authorization — so the indicator stays dark.
        XCTAssertFalse(harness.serviceSession.isActive)
        XCTAssertEqual(harness.serviceSession.startCount, 0)
    }

    func testParkedWakeBootstrapReleasesServiceSessionSoNoIndicator() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.first, anchor)
        XCTAssertTrue(harness.idleWake.isMonitoring)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        XCTAssertEqual(harness.backgroundWake.startCount, 1)
        XCTAssertFalse(harness.background.isActive)   // no background-activity session → no indicator at idle
        // Parked idle-anchored needs no service session: the geofence + SLC/visit
        // wakes deliver under bare `.always` authorization, so the session (and the
        // location indicator it lights) is released instead of held for the whole
        // idle period. A real drive-away wake re-establishes it (see
        // testDriveAwayWakeReestablishesServiceSessionFromIdleAnchored).
        XCTAssertFalse(harness.serviceSession.isActive)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.category == "lifecycle" && $0.message == "Location background wake" })
        XCTAssertTrue(events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap capture policy applied"
                && ($0.detectionReason?.contains("monitorActive=true") ?? false)
                && ($0.detectionReason?.contains("backgroundWakeActive=true") ?? false)
                && ($0.detectionReason?.contains("serviceSessionActive=false") ?? false)
                && ($0.detectionReason?.contains("liveGPSActive=false") ?? false)
        })
        XCTAssertTrue(events.contains { $0.category == "wakeBootstrap" && $0.message == "Wake bootstrap completed" })
    }

    /// 2026-07-07 stuck-arrow regression (ADR-003): repeated parked wakes must
    /// not churn the arming layer — SLC/visits arm once per process, and no
    /// "restored from beacon" row appears on warm bootstraps (pre-fix it was
    /// journaled once per relaunch).
    func testRepeatedWakeBootstrapsDoNotChurnArmingOrJournal() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        for _ in 1...5 {
            harness.runtime.bootstrapForWake(reason: .locationWake)
        }

        XCTAssertEqual(harness.backgroundWake.startCount, 1, "SLC/visits arm once per process, not once per wake")
        XCTAssertEqual(harness.idleWake.monitoredAnchors.count, 1)
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertEqual(
            events.filter { $0.message == "Parked anchor geofence restored from beacon" }.count, 0,
            "warm bootstraps report .notNeeded and stay silent"
        )
        XCTAssertEqual(
            events.filter { $0.message == "Background wake monitoring armed (SLC + visits)" }.count, 1
        )
    }

    /// Foreground opens were invisible in device pulls (only backgroundLaunch
    /// was journaled), which hampered the 2026-07-07 investigations.
    func testSceneBecameActiveJournalsLifecycleEvent() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        harness.runtime.sceneBecameActive()

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "lifecycle"
                && $0.message == "Scene became active"
                && $0.wakeReason == "sceneActive"
                && ($0.detectionReason?.contains("monitorActive=") ?? false)
        })
    }

    /// The foreground self-heal re-asserts SLC/visits past the in-process guard
    /// (registrations the system silently dropped) but is throttled so rapid
    /// app-switch bounces don't repeat it.
    func testSceneBecameActiveSelfHealForceRearmsOnceWithinThrottle() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.runtime.sceneBecameActive()
        harness.runtime.sceneBecameActive()

        XCTAssertEqual(harness.backgroundWake.forceRearmCount, 1, "second activation inside the throttle window must not re-heal")
    }

    func testStartMonitoringWithRecordingStateUsesHighFidelityCapture() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state)

        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.count, 0)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testLocationWakeBootstrapRestoresRecordingCapture() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        XCTAssertEqual(harness.runtime.activityStatus, .recording)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap capture policy applied"
                && ($0.detectionReason?.contains("activity=recording") ?? false)
                && ($0.detectionReason?.contains("serviceSessionActive=true") ?? false)
                && ($0.detectionReason?.contains("liveGPSActive=true") ?? false)
        })
    }

    func testNoAnchorStartupPrimesBrieflyThenStops() async throws {
        let harness = try makeHarness(idlePrimingDuration: 0.02)

        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.location.activeConfiguration, .default)
        XCTAssertEqual(harness.runtime.activityStatus, .idlePriming)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.serviceSession.isActive)   // priming needs the session
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertFalse(harness.serviceSession.isActive)  // dropped to idle-dormant → session released
    }

    func testForegroundAfterExhaustedNoAnchorPrimingDoesNotRestartGPS() async throws {
        let harness = try makeHarness(idlePrimingDuration: 0.02)
        harness.runtime.startMonitoring()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.serviceSession.isActive)   // idle-dormant → session released
        let startCount = harness.location.startedConfigurations.count
        let serviceSessionStartCount = harness.serviceSession.startCount

        harness.runtime.sceneBecameActive()

        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertEqual(harness.location.startedConfigurations.count, startCount)
        XCTAssertEqual(harness.serviceSession.startCount, serviceSessionStartCount)
        XCTAssertFalse(harness.serviceSession.isActive)   // foregrounding an exhausted-priming idle does not re-hold it
    }

    func testRelaunchAfterExhaustedNoAnchorPrimingDoesNotRestartGPS() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let first = try makeHarness(persistence: persistence, idlePrimingDuration: 0.02)
        first.runtime.startMonitoring()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(first.runtime.activityStatus, .idleDormant)

        let second = try makeHarness(persistence: persistence, idlePrimingDuration: 0.02)
        second.runtime.startMonitoring()

        XCTAssertNil(second.location.activeConfiguration)
        XCTAssertEqual(second.runtime.activityStatus, .idleDormant)
        XCTAssertTrue(second.motion.liveUpdatesStarted)
        XCTAssertEqual(second.location.startedConfigurations.count, 0)
        XCTAssertFalse(second.serviceSession.isActive)   // relaunch into idle-dormant → no session
    }

    func testServiceSessionStartAndStopAreJournaled() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let harness = try makeHarness(
            persistence: persistence,
            captureEventStore: captureEventStore,
            idlePrimingDuration: 0.02
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.startMonitoring()
        try await Task.sleep(nanoseconds: 80_000_000)
        // The session starts for the priming window then stops when the level drops
        // to idle-dormant; stopMonitoring is a no-op on the already-stopped session.
        harness.runtime.stopMonitoring()

        let events = try captureEventStore.fetchEvents(
            since: before,
            until: Date().addingTimeInterval(1)
        )
        XCTAssertTrue(events.contains { $0.message == "Location service session started" })
        XCTAssertTrue(events.contains { $0.message == "Location service session stopped" })
    }

    func testExplicitResumeRearmsOneNoAnchorPrimingWindow() async throws {
        let harness = try makeHarness(idlePrimingDuration: 0.02)
        harness.runtime.startMonitoring()
        try await Task.sleep(nanoseconds: 80_000_000)

        harness.runtime.resume()

        XCTAssertEqual(harness.location.activeConfiguration, .default)
        XCTAssertEqual(harness.runtime.activityStatus, .idlePriming)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testServiceSessionFollowsPermissionLeaseAtIdle() async throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            permissionServiceSessionLease: 0.02
        )
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        // Parked idle-anchored holds no session (nothing requires it, no lease yet),
        // so the location indicator stays dark.
        XCTAssertFalse(harness.serviceSession.isActive)

        // A permission request opens a brief service-session lease so CL can resolve
        // authorization; the session is active only for the duration of that lease.
        harness.runtime.requestLocationPermission()
        XCTAssertTrue(harness.serviceSession.isActive)
        XCTAssertEqual(harness.serviceSession.purposeKeys, ["MileageTripCapture"])

        try await Task.sleep(nanoseconds: 80_000_000)
        // Lease expired → session released again; still parked at idle-anchored.
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertFalse(harness.serviceSession.isActive)
    }

    func testIdleWakeStartsHighFidelityWithoutStartingTrip() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.idleWake.emitWake(at: anchor.timestamp.addingTimeInterval(300))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .parkedAnchorExit)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertEqual(harness.idleWake.stopCount, 1)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    // MARK: - Parked-anchor beacon survives an unconfirmed candidate (P2b)

    func testUnconfirmedCandidatePreservesParkedAnchorBeacon() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()
        XCTAssertTrue(harness.idleWake.beaconArmed, "parked idle arms the cold-relaunch beacon")

        // A probe arms a start candidate. Arming does NOT clear `parkedStartAnchor`,
        // so the parked spot is still authoritative and the non-secure beacon must
        // survive even though the live region is torn down — otherwise an iOS
        // suspend/terminate during the candidate window strands the phone (P2b).
        harness.runtime.armDriveStart(trigger: .vehicleBluetooth, at: anchor.timestamp.addingTimeInterval(5))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertNotNil(harness.runtime.state.parkedStartAnchor)
        XCTAssertTrue(
            harness.idleWake.beaconArmed,
            "an unconfirmed candidate must not strip the cold-relaunch beacon (P2b)"
        )
        XCTAssertEqual(
            harness.idleWake.suspendCount, 1,
            "candidate entry suspends the region instead of clearing the beacon"
        )
    }

    func testConfirmedRecordingClearsParkedAnchorBeacon() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.runtime.armDriveStart(trigger: .vehicleBluetooth, at: start)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertTrue(harness.idleWake.beaconArmed, "a live candidate still preserves the beacon")

        // Confirm the drive: an automotive burst over distance promotes to .recording,
        // which clears `parkedStartAnchor` (the car has left the parked spot) — the now
        // stale beacon must be cleared too, so cold relaunch never re-arms a stale fence.
        for offset in [0.0, 5, 10, 15, 20] {
            let hint: MotionHint = offset < 15 ? .stationary : .walking
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset,
                speed: hint == .stationary ? 0 : 1.3,
                hint: hint
            ))
        }
        for offset in stride(from: 30.0, through: 80.0, by: 5.0) {
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset * 12,
                speed: 12,
                hint: .automotive
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertNil(harness.runtime.state.parkedStartAnchor)
        XCTAssertFalse(
            harness.idleWake.beaconArmed,
            "a confirmed drive start clears the stale parked-anchor beacon"
        )
    }

    // MARK: - SLC + visit background-wake backbone

    func testStartMonitoringWithParkedAnchorArmsGeofenceAndBackgroundWakeBackbone() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.startMonitoring()

        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        XCTAssertEqual(harness.backgroundWake.startCount, 1)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Background wake monitoring armed (SLC + visits)" })
        XCTAssertTrue(events.contains { $0.message == "Parked anchor geofence armed" })
    }

    func testNoAnchorStartupJournalsGeofenceSkipped() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Parked anchor geofence skipped — no parked anchor" })
    }

    // A cold launch with no saved checkpoint (e.g. the very first launch, or a fetch that
    // silently comes back empty) previously left no trace in the persistent journal — only an
    // in-memory DiagnosticsService entry that is lost if the process is killed again before a
    // foreground export. This must be journaled so a device pull can distinguish "no checkpoint
    // was ever written" from "a checkpoint existed but couldn't be read."
    func testWakeBootstrapWithNoSavedCheckpointJournalsNoRow() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let harness = try makeHarness(
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "tracking"
                && $0.message == "Active drive checkpoint load returned no row"
                && $0.wakeReason == DriveCaptureWakeReason.locationWake.rawValue
        })
    }

    // A checkpoint row that fails to decode (corrupt `stateData`) previously fell back to the
    // reducer's default in-memory state with no persistent trace at all. This confirms the
    // decode failure now lands in the journal with the underlying error description, so a
    // decode failure is distinguishable from a genuinely-missing row.
    func testWakeBootstrapWithCorruptCheckpointJournalsLoadFailure() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let context = persistence.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "ActiveDriveEntity")
        request.predicate = NSPredicate(format: "id == %@", "current")
        let entity = try XCTUnwrap(context.fetch(request).first)
        entity.setValue(Data("not valid json".utf8), forKey: "stateData")
        try context.save()
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "tracking"
                && $0.message == "Failed to load active drive checkpoint"
                && $0.wakeReason == DriveCaptureWakeReason.locationWake.rawValue
                && ($0.detectionReason?.isEmpty == false)
        })
    }

    // Classic region monitoring is disabled entirely under Reduced Accuracy, so the geofence
    // must not be armed and the skip must be journaled with the accuracy reason — a plausible
    // second cause of idleWake never firing that the API swap alone would not surface.
    func testReducedAccuracyJournalsGeofenceSkippedAndDoesNotArm() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.healthStatus.preciseLocationEnabled = false
        let before = Date().addingTimeInterval(-1)

        harness.runtime.startMonitoring()

        XCTAssertFalse(harness.idleWake.isMonitoring)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Parked anchor geofence skipped — reduced accuracy" })
        XCTAssertFalse(events.contains { $0.message == "Parked anchor geofence armed" })
    }

    func testStopMonitoringStopsBackgroundWakeBackbone() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        let beforeStop = Date().addingTimeInterval(-1)

        harness.runtime.stopMonitoring()

        XCTAssertFalse(harness.backgroundWake.isMonitoring)
        XCTAssertGreaterThanOrEqual(harness.backgroundWake.stopCount, 1)
        let events = try captureEventStore.fetchEvents(since: beforeStop, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Background wake monitoring stopped (SLC + visits)" })
    }

    func testBackgroundRefreshUnavailableProducesHealthIssue() throws {
        let harness = try makeHarness()
        harness.healthStatus.backgroundRefreshAvailable = false
        var latestHealth: TrackingHealth?
        harness.runtime.onHealthChanged = { latestHealth = $0 }

        harness.runtime.startMonitoring()

        let health = try XCTUnwrap(latestHealth)
        XCTAssertFalse(health.backgroundRefreshAvailable)
        XCTAssertTrue(health.issues.contains("Enable Background App Refresh so location wakes can relaunch the app."))
        XCTAssertFalse(health.isAllClear)
    }

    func testSignificantLocationChangeWakeOpensProbeWithoutStartingTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        let wakeAt = Date()

        harness.backgroundWake.emitSignificantChange(at: wakeAt)

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .significantLocationChange)
        XCTAssertEqual(harness.runtime.activityStatus, .candidate)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        // The relaunch backbone stays armed through the probe.
        XCTAssertTrue(harness.backgroundWake.isMonitoring)

        let events = try captureEventStore.fetchEvents(since: wakeAt.addingTimeInterval(-1), until: wakeAt.addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Significant location change wake" && $0.wakeReason == "significantLocationChange" })
    }

    /// 2026-07-07 regression (12 mini): a relaunch flushed an SLC event 18.5 h
    /// old, and the very staleness that proved it said nothing about current
    /// movement also failed the anchor gate's freshness check — so it fell
    /// through and armed a GPS probe that a stationary burst killed within a
    /// second. Events past the staleness bound must be journaled and dropped.
    func testStaleSignificantLocationChangeWakeIsDropped() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()
        let now = Date()

        harness.backgroundWake.emitSignificantChange(at: now.addingTimeInterval(-66_533))

        XCTAssertEqual(harness.runtime.state.phase, .idle, "an hours-old SLC event must not arm a probe")
        XCTAssertNil(harness.runtime.state.startSignal)
        let events = try captureEventStore.fetchEvents(since: now.addingTimeInterval(-1), until: now.addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Stale significant change wake dropped" })
        XCTAssertFalse(events.contains { $0.message == "Significant location change wake" })
    }

    /// A minutes-late SLC delivery is normal mid-drive latency and must keep
    /// arming the probe.
    func testSlightlyDelayedSignificantLocationChangeWakeStillArms() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: Date().addingTimeInterval(-120))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .significantLocationChange)
    }

    func testVisitDepartureWakeOpensProbeWithoutStartingTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        let wakeAt = Date()

        harness.backgroundWake.emitVisitDeparture(at: wakeAt)

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .visitDeparture)
        XCTAssertEqual(harness.runtime.activityStatus, .candidate)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)

        let events = try captureEventStore.fetchEvents(since: wakeAt.addingTimeInterval(-1), until: wakeAt.addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Visit departure wake" && $0.wakeReason == "visitDeparture" })
    }

    /// The 2026-06-22/07-01 stall: live GPS is nominally running for a candidate
    /// but Core Location reports `serviceSessionRequired` and withholds every fix
    /// (a session started from a non-location background context is never
    /// fulfilled). A later movement-proving wake restores location eligibility,
    /// so it must cycle the service session and the live stream instead of
    /// letting the candidate time out at samples=0.
    func testMovementWakeCyclesStalledLiveGPS() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertTrue(harness.location.isActive)
        let gpsStartsBefore = harness.location.startedConfigurations.count
        let sessionStartsBefore = harness.serviceSession.startCount
        let sessionStopsBefore = harness.serviceSession.stopCount

        harness.location.emitServiceSessionRequired()
        let backgroundStopsBefore = harness.background.stopCount
        let backgroundStartsBefore = harness.background.startCount
        let wakeAt = Date()
        harness.backgroundWake.emitVisitDeparture(at: wakeAt)

        XCTAssertEqual(harness.location.startedConfigurations.count, gpsStartsBefore + 1)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertEqual(harness.serviceSession.stopCount, sessionStopsBefore + 1)
        XCTAssertEqual(harness.serviceSession.startCount, sessionStartsBefore + 1)
        XCTAssertTrue(harness.serviceSession.isActive)
        // The background-activity session is PRESERVED, not cycled: per
        // CLBackgroundActivitySession.h a new session created in the background
        // can never activate, while an existing one (taken earlier while in
        // use) keeps the app in-use — invalidating it here could destroy the
        // only thing still helping (2026-07-05).
        XCTAssertEqual(harness.background.stopCount, backgroundStopsBefore)
        XCTAssertEqual(harness.background.startCount, backgroundStartsBefore)
        XCTAssertTrue(harness.background.isActive)
        let events = try captureEventStore.fetchEvents(since: wakeAt.addingTimeInterval(-1), until: wakeAt.addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Restarted stalled live GPS" && $0.wakeReason == "visitDeparture" })
        XCTAssertTrue(events.contains { $0.message == "Background activity session preserved" })
    }

    /// `CLServiceSession.diagnostics` is the push-delivered "this session is
    /// not honored" signal (e.g. `insufficientlyInUse` after a device restart).
    /// It must be journaled, surfaced to the app layer, and must arm the
    /// wake-path stall recovery even when no location update ever arrives.
    func testSessionDiagnosticJournalsAndArmsStallRecovery() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        var unfulfilled: [DriveServiceSessionDiagnostic] = []
        harness.runtime.onServiceSessionUnfulfilled = { unfulfilled.append($0) }
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        let gpsStartsBefore = harness.location.startedConfigurations.count
        let diagnosticAt = Date()

        let diagnostic = DriveServiceSessionDiagnostic(insufficientlyInUse: true)
        harness.serviceSession.emitDiagnostic(diagnostic)
        // Repeats of the same state must not re-journal or re-fire.
        harness.serviceSession.emitDiagnostic(diagnostic)

        XCTAssertEqual(unfulfilled, [diagnostic])
        let events = try captureEventStore.fetchEvents(since: diagnosticAt.addingTimeInterval(-1), until: diagnosticAt.addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message == "Service session diagnostic" }.count, 1)
        XCTAssertTrue(events.contains {
            $0.message == "Service session diagnostic"
                && ($0.detectionReason?.contains("insufficientlyInUse") ?? false)
        })

        // No location update carried the stall flag, but the diagnostic did —
        // the next movement-proving wake must still cycle the session + stream.
        harness.backgroundWake.emitVisitDeparture(at: Date())
        XCTAssertEqual(harness.location.startedConfigurations.count, gpsStartsBefore + 1)
    }

    /// A `liveUpdates` stream that ends (Core Location terminates async
    /// streams on lifecycle changes) must be restarted immediately — before
    /// this, `isActive` lied forever and a same-configuration `start()` was a
    /// no-op, so a mid-drive stream death cost the rest of the segment until
    /// the next movement-proving wake.
    func testStreamDeathIsJournaledAndRestarted() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        let gpsStartsBefore = harness.location.startedConfigurations.count
        let deathAt = Date()

        harness.location.endStream(at: deathAt)

        XCTAssertEqual(harness.location.startedConfigurations.count, gpsStartsBefore + 1)
        XCTAssertTrue(harness.location.isActive)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        let events = try captureEventStore.fetchEvents(since: deathAt.addingTimeInterval(-1), until: deathAt.addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.message == "Live GPS stream ended" && ($0.detectionReason?.contains("restart=attempted") ?? false)
        })
    }

    func testStreamDeathRestartsAreBoundedPerWindow() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, captureEventStore: captureEventStore)
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        harness.location.endStream()
        harness.location.endStream()
        let gpsStartsBefore = harness.location.startedConfigurations.count
        let thirdDeathAt = Date()

        harness.location.endStream(at: thirdDeathAt)

        XCTAssertEqual(harness.location.startedConfigurations.count, gpsStartsBefore, "third death within the window must not restart")
        XCTAssertFalse(harness.location.isActive)
        let events = try captureEventStore.fetchEvents(since: thirdDeathAt.addingTimeInterval(-1), until: thirdDeathAt.addingTimeInterval(1))
        XCTAssertTrue(events.contains { $0.message == "Live GPS restart suppressed" })

        // The wake-path stall recovery still owns revival after suppression.
        harness.backgroundWake.emitVisitDeparture(at: Date())
        XCTAssertTrue(harness.location.isActive)
    }

    func testMovementWakeLeavesHealthyLiveGPSAlone() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        let start = Date()
        harness.backgroundWake.emitSignificantChange(at: start)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        harness.location.emit(sample: sample(at: Date(), metersNorth: 40, speed: 14, hint: .automotive))
        let gpsStartsBefore = harness.location.startedConfigurations.count
        let sessionStopsBefore = harness.serviceSession.stopCount

        harness.backgroundWake.emitVisitDeparture(at: Date())

        XCTAssertEqual(harness.location.startedConfigurations.count, gpsStartsBefore)
        XCTAssertEqual(harness.serviceSession.stopCount, sessionStopsBefore)
        XCTAssertTrue(harness.location.isActive)
    }

    func testResumeReArmsBackgroundWakeBackbone() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()
        XCTAssertTrue(harness.backgroundWake.isMonitoring)

        harness.runtime.pause(for: 3600)
        // A pause must remain endable: SLC + visits stay armed so a background
        // wake can reach the expiry check on a suspended/terminated app.
        XCTAssertTrue(harness.backgroundWake.isMonitoring, "pause must keep the relaunch backbone armed")
        XCTAssertEqual(harness.runtime.activityStatus, .paused)

        harness.runtime.resume()
        XCTAssertTrue(harness.backgroundWake.isMonitoring, "resume must keep the relaunch backbone armed")
        XCTAssertNotEqual(harness.runtime.activityStatus, .paused)
    }

    /// "Pause Today" must never become "pause forever": an expired pause is
    /// cleared by the next wake bootstrap even though GPS was off the whole
    /// time (no location sample can arrive to clear it).
    func testExpiredPauseAutoResumesOnWakeBootstrap() async throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        var latestHealth: TrackingHealth?
        harness.runtime.onHealthChanged = { latestHealth = $0 }
        harness.runtime.startMonitoring()

        harness.runtime.pause(for: 0.05)
        XCTAssertEqual(harness.runtime.activityStatus, .paused)
        XCTAssertNotNil(latestHealth?.trackingPausedUntil)
        try await Task.sleep(for: .milliseconds(120))

        harness.runtime.bootstrapForWake(reason: .locationWake)

        XCTAssertNotEqual(harness.runtime.activityStatus, .paused)
        XCTAssertNil(harness.runtime.state.pausedUntil)
        XCTAssertNil(latestHealth?.trackingPausedUntil)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
    }

    /// The in-process expiry path: if the app stays alive, the pause ends at
    /// its deadline via the resume timer without any wake or foreground pass.
    func testPauseTimerAutoResumes() async throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        var latestHealth: TrackingHealth?
        harness.runtime.onHealthChanged = { latestHealth = $0 }
        harness.runtime.startMonitoring()

        harness.runtime.pause(for: 0.05)
        XCTAssertEqual(harness.runtime.activityStatus, .paused)

        // Timer fires at deadline + 1s slack.
        try await Task.sleep(for: .milliseconds(1600))

        XCTAssertNotEqual(harness.runtime.activityStatus, .paused)
        XCTAssertNil(harness.runtime.state.pausedUntil)
        XCTAssertNil(latestHealth?.trackingPausedUntil)
    }

    /// CLVisit departures are delivered minutes after the fact. The signal must be
    /// stamped at delivery time, not the departure time — otherwise the candidate
    /// arms with a `candidateStartedAt` already past the unconfirmed-candidate
    /// timeout and is killed on the first non-moving sample.
    func testDelayedVisitDepartureProbeSurvivesFirstStationarySample() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)

        // Departure happened 10 minutes before iOS delivered the visit.
        harness.backgroundWake.emitVisitDeparture(at: Date().addingTimeInterval(-600))
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        harness.location.emit(sample: sample(at: Date(), metersNorth: 0, speed: 0, hint: .stationary))

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "delayed-visit probe must not time out instantly")
    }

    func testNoisyWalkingAndStationaryWakeCanRecoverIntoTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.idleWake.emitWake(at: start)
        for offset in stride(from: 0.0, through: 70.0, by: 10.0) {
            let hint: MotionHint = offset < 40 ? .walking : .stationary
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset,
                speed: hint == .walking ? 1.2 : 0,
                hint: hint
            ))
        }

        for offset in stride(from: 85.0, through: 150.0, by: 5.0) {
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset * 12,
                speed: 12,
                hint: .automotive
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testExternalWakeWithEarlyNoiseCanRecoverIntoTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = start.addingTimeInterval(-60)
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.runtime.armDriveStart(trigger: .vehicleBluetooth, at: start)
        for offset in [0.0, 5, 10, 15, 20] {
            let hint: MotionHint = offset < 15 ? .stationary : .walking
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset,
                speed: hint == .stationary ? 0 : 1.3,
                hint: hint
            ))
        }

        for offset in stride(from: 30.0, through: 80.0, by: 5.0) {
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: offset * 12,
                speed: 12,
                hint: .automotive
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, nil)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testUntrustedVehicleRouteObservationWarmsIdleCaptureWithoutStartingTrip() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.serviceSession.isActive)   // idle-dormant holds no session

        harness.runtime.vehicleRouteObserved(source: .bluetoothAudio, at: Date().addingTimeInterval(60))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .weakBluetoothName)
        XCTAssertEqual(harness.runtime.activityStatus, .candidate)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testAutomotiveMotionStartsCandidateAndHighFidelityCapture() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleDormant)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.serviceSession.isActive)   // idle-dormant holds no session

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        harness.motion.emit(MotionActivitySnapshot(startDate: start, confidence: .medium, hints: [.automotive]))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .motionAutomotive)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testServiceSessionReleasedAtIdleAnchored() throws {
        // Parked idle-anchored holds NO service session: the `.always` full-accuracy
        // session lights the location indicator on its own, and the geofence + SLC/
        // visit wakes that watch for the next drive deliver under bare `.always`
        // authorization with no session. So while parked, every indicator-bearing
        // piece — service session, background-activity session, live GPS — is OFF.
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))

        harness.runtime.startMonitoring()

        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertFalse(harness.serviceSession.isActive)      // no authorization assertion → indicator dark
        XCTAssertFalse(harness.background.isActive)          // no background-activity session
        XCTAssertNil(harness.location.activeConfiguration)   // no live GPS while parked
    }

    func testServiceSessionReleasedWhenMonitoringStops() throws {
        // Start from a recording state so the session is genuinely held, then confirm
        // stopMonitoring tears it down.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        ))
        harness.runtime.startMonitoring()
        XCTAssertTrue(harness.serviceSession.isActive)

        harness.runtime.stopMonitoring()
        XCTAssertFalse(harness.serviceSession.isActive)
    }

    func testPossibleDriveRecoveryJournalsDiagnosticsWithoutCompletingTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            diagnostics: DiagnosticsService(),
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // No GPS-reported speed: derived-speed-only candidates can never
        // confirm a visible trip (the no-trust confirmation fallback requires
        // reported speed). Since 2026-07-07 they keep collecting instead of
        // dying at the first policy evaluation, so they resolve through the
        // candidate expiry timeout — which is what feeds the possible-drive
        // recovery pipeline.
        let samples = [
            sample(at: start.addingTimeInterval(1), metersNorth: 120, speed: nil, hint: .unknown),
            sample(at: start.addingTimeInterval(4), metersNorth: 180, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(7), metersNorth: 260, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(12), metersNorth: 360, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(30), metersNorth: 520, speed: nil, hint: .automotive),
            // Rides past the signal high-fidelity window and times the candidate out.
            sample(at: start.addingTimeInterval(190), metersNorth: 900, speed: nil, hint: .automotive)
        ]
        samples.forEach { harness.location.emit(sample: $0) }

        XCTAssertEqual(harness.runtime.state.phase, .idle, "derived-speed-only candidate must time out, not confirm")
        let diagnosticSamples = try diagnosticSampleStore.fetchSamples(
            since: start.addingTimeInterval(-1),
            until: start.addingTimeInterval(200)
        )
        let candidates = DiagnosticDriveAnalyzer.possibleDriveCandidates(from: diagnosticSamples)
        let events = try captureEventStore.fetchEvents(
            since: start.addingTimeInterval(-1),
            until: start.addingTimeInterval(240)
        )

        XCTAssertTrue(harness.completionCoordinator.completedDrafts.isEmpty)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(events.contains { $0.message == "Retained possible drive candidate from diagnostic samples" })
    }

    func testStrictSpeedOnlyRecoverySurfacesRecentCandidateForReviewOnStartup() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sessionID = UUID()
        let start = Date().addingTimeInterval(-5 * 60)
        for index in 0..<5 {
            let timestamp = start.addingTimeInterval(TimeInterval(index * 12))
            try diagnosticSampleStore.save(DiagnosticLocationSample(
                monitoringSessionID: sessionID,
                receivedAt: timestamp,
                sample: sample(
                    at: timestamp,
                    metersNorth: Double(index) * 70,
                    speed: 12,
                    hint: .unknown
                ),
                trackingPhase: index == 0 ? "idle" : "candidate",
                powerConnected: false,
                recentPowerConnected: false,
                recentPowerDisconnected: false,
                trustedBluetoothVehicleHint: false,
                acceptedForDetection: true,
                detectionOutput: index == 0
                    ? "candidateStarted, checkpointChanged"
                    : "tripUpdated, checkpointChanged",
                detectionReason: index == 4
                    ? "Diagnostic-only drive candidate: speedOnlyNoAssist: samples=5, elapsed=48s, distance=280m"
                    : nil,
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            ))
        }
        let harness = try makeHarness(
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            diagnosticsMode: .standard
        )

        harness.runtime.startMonitoring()

        let draft = try XCTUnwrap(harness.completionCoordinator.completedDrafts.first)
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)
        XCTAssertNil(draft.classification)
        XCTAssertGreaterThanOrEqual(
            draft.distanceMeters,
            200
        )
        XCTAssertTrue(draft.attentionReasons.contains(PossibleDriveCandidate.attentionReason))

        let restricted = try makeHarness(
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            diagnosticsMode: .standard,
            automaticTripStartMode: .bluetoothOrCarPlay
        )
        restricted.runtime.startMonitoring()
        XCTAssertTrue(restricted.completionCoordinator.completedDrafts.isEmpty,
                      "Bluetooth or CarPlay cannot materialize old diagnostics lacking automation admission")
    }

    /// The one duplicate source recovery can create: a deferral burst split
    /// from its confirmed trip by a >5-minute GPS gap analyzes as its own
    /// untagged candidate. With the duplicate resolver removed as a product
    /// decision, recovery must never materialize a candidate that overlaps a
    /// trip that already exists.
    func testStrictRecoverySkipsCandidateOverlappingExistingTrip() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let sessionID = UUID()
        let start = Date().addingTimeInterval(-5 * 60)
        for index in 0..<5 {
            let timestamp = start.addingTimeInterval(TimeInterval(index * 12))
            try diagnosticSampleStore.save(DiagnosticLocationSample(
                monitoringSessionID: sessionID,
                receivedAt: timestamp,
                sample: sample(
                    at: timestamp,
                    metersNorth: Double(index) * 70,
                    speed: 12,
                    hint: .unknown
                ),
                trackingPhase: index == 0 ? "idle" : "candidate",
                powerConnected: false,
                recentPowerConnected: false,
                recentPowerDisconnected: false,
                trustedBluetoothVehicleHint: false,
                acceptedForDetection: true,
                detectionOutput: index == 0
                    ? "candidateStarted, checkpointChanged"
                    : "tripUpdated, checkpointChanged",
                detectionReason: index == 4
                    ? "Diagnostic-only drive candidate: speedOnlyNoAssist: samples=5, elapsed=48s, distance=280m"
                    : nil,
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            ))
        }
        let harness = try makeHarness(
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            diagnosticsMode: .standard
        )
        harness.completionCoordinator.overlappingTripExists = true

        harness.runtime.startMonitoring()

        XCTAssertTrue(harness.completionCoordinator.completedDrafts.isEmpty)
        XCTAssertEqual(harness.completionCoordinator.overlapQueries.count, 1)
    }

    func testStrictSpeedOnlyRecoveryWaitsForQuietAndKeepsLaterEndpoint() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let harness = try makeHarness(
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            diagnosticsMode: .standard,
            possibleDriveRecoveryQuietPeriod: 0.05
        )
        harness.runtime.startMonitoring()
        let sessionID = UUID()
        let start = Date()
        for index in 0..<5 {
            let timestamp = start.addingTimeInterval(TimeInterval(index * 12))
            try diagnosticSampleStore.save(DiagnosticLocationSample(
                monitoringSessionID: sessionID,
                receivedAt: timestamp,
                sample: sample(
                    at: timestamp,
                    metersNorth: Double(index) * 70,
                    speed: 12,
                    hint: .unknown
                ),
                trackingPhase: index == 0 ? "idle" : "candidate",
                powerConnected: false,
                recentPowerConnected: false,
                recentPowerDisconnected: false,
                trustedBluetoothVehicleHint: false,
                acceptedForDetection: true,
                detectionOutput: index == 0
                    ? "candidateStarted, checkpointChanged"
                    : "tripUpdated, checkpointChanged",
                detectionReason: index == 4
                    ? "Diagnostic-only drive candidate: speedOnlyNoAssist: samples=5, elapsed=48s, distance=280m"
                    : nil,
                expiresAt: Date().addingTimeInterval(24 * 60 * 60)
            ))
        }
        let completed = expectation(description: "strict recovery completed after quiet period")
        harness.runtime.onTripCompleted = { _, _, _ in completed.fulfill() }
        let finalTimestamp = start.addingTimeInterval(55)

        harness.location.emit(sample: sample(
            at: start.addingTimeInterval(49),
            metersNorth: 300,
            speed: 5,
            hint: .unknown
        ))
        harness.location.emit(sample: sample(
            at: finalTimestamp,
            metersNorth: 350,
            speed: 5,
            hint: .unknown
        ))
        await fulfillment(of: [completed], timeout: 1)

        let draft = try XCTUnwrap(harness.completionCoordinator.completedDrafts.first)
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)
        XCTAssertEqual(draft.endDate, finalTimestamp)
        XCTAssertGreaterThan(draft.distanceMeters, 300)
    }

    func testStandardDiagnosticsKeepsSamplesButDoesNotJournalCaptureEvents() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: DriveCaptureState(
                phase: .recording,
                startedAt: start,
                lastMovingAt: start,
                samples: [sample(at: start, metersNorth: 0, speed: 12, hint: .automotive)]
            ),
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore,
            diagnosticsMode: .standard
        )
        harness.runtime.startMonitoring()
        harness.location.emit(sample: sample(
            at: start.addingTimeInterval(10),
            metersNorth: 120,
            speed: 12,
            hint: .automotive
        ))

        let samples = try diagnosticSampleStore.fetchSamples(since: nil, until: nil)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(
            samples[0].expiresAt.timeIntervalSince(samples[0].receivedAt),
            24 * 60 * 60,
            accuracy: 1
        )
        XCTAssertTrue(try captureEventStore.fetchEvents(since: nil, until: nil).isEmpty)
    }

    func testLowMotionDoesNotStartCandidateOrGPS() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.motion.emit(MotionActivitySnapshot(startDate: Date(), confidence: .low, hints: [.automotive]))

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertNil(harness.runtime.state.startSignal)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertFalse(harness.serviceSession.isActive)   // idle-dormant holds no session
    }

    func testFailedCandidateReturnsToAnchoredIdleWake() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let moving = sample(at: start, metersNorth: 200, speed: 12, hint: .automotive)
        let state = DriveCaptureState(
            phase: .candidate,
            candidateStartedAt: start,
            candidateSamples: [moving],
            parkedStartAnchor: anchor
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        // Candidate resilience tolerates two contradictions; the third kills.
        harness.location.emit(sample: sample(at: start.addingTimeInterval(5), metersNorth: 205, speed: 0, hint: .stationary))
        harness.location.emit(sample: sample(at: start.addingTimeInterval(9), metersNorth: 205, speed: 0, hint: .stationary))
        harness.location.emit(sample: sample(at: start.addingTimeInterval(13), metersNorth: 205, speed: 0, hint: .stationary))

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertGreaterThanOrEqual(harness.idleWake.monitoredAnchors.count, 1)
        XCTAssertFalse(harness.serviceSession.isActive)   // back to parked idle-anchored → session released
    }

    func testCompletedTripHoldsResumptionGraceKeepingAppAlive() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        completeOutboundWithPedestrianExit(harness, start: start)

        // The trip completed, but the post-drive resumption grace holds the app
        // alive in .idleWake (live GPS + background-activity session) instead of
        // dropping straight to terminable, indicator-free .idleAnchored — so a
        // quick return leg is captured directly rather than depending on an
        // unreliable iOS terminated-app relaunch (the 2026-06-22 evening miss).
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleWake)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.background.isActive)
        XCTAssertTrue(harness.serviceSession.isActive)
        XCTAssertNotNil(harness.runtime.state.parkedStartAnchor,
                        "park anchor is captured so the geofence arms once the grace expires")
    }

    func testResumptionGraceSurvivesParkedSamplesThenCapturesLongNoTrustReturn() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        // Outbound leg ends with a confirmed pedestrian exit, so this test stays
        // focused on post-completion grace rather than weak disconnect parking.
        let parkedAt = start.addingTimeInterval(86)
        completeOutboundWithPedestrianExit(harness, start: start)
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleWake)

        // Parked, app still alive: live GPS keeps emitting stationary samples,
        // each of which ingestIdle reports as "No driving signal". The grace must
        // ride through them — otherwise clearIdleHighFidelityAfterRejectedProbe
        // would collapse it to terminable .idleAnchored within ~1s of parking.
        for offset in stride(from: 35.0, through: 95.0, by: 20.0) {
            harness.location.emit(sample: sample(at: parkedAt.addingTimeInterval(offset), metersNorth: 860, speed: 0, hint: .stationary))
            XCTAssertEqual(harness.runtime.state.phase, .idle)
            XCTAssertEqual(harness.runtime.activityStatus, .idleWake, "parked stationary samples must not cancel the resumption grace")
            XCTAssertTrue(harness.background.isActive, "app stays held alive through parked samples")
        }

        // Return leg starts ~2 min later with NO Bluetooth/vehicle signal. This
        // is the easy no-trust path: sustained movement well past the fallback
        // threshold should confirm while grace keeps the app alive.
        let resumeAt = parkedAt.addingTimeInterval(120)
        for offset in stride(from: 0.0, through: 60.0, by: 5.0) {
            harness.location.emit(sample: sample(
                at: resumeAt.addingTimeInterval(offset),
                metersNorth: 900 + offset * 12,
                speed: 12,
                hint: .automotive
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .recording, "return leg captured via GPS/motion alone, no Bluetooth")
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
    }

    func testShortNoTrustReturnAboveFallbackDistanceRecordsWithinGrace() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        let parkedAt = start.addingTimeInterval(86)
        completeOutboundWithPedestrianExit(harness, start: start)
        XCTAssertEqual(harness.runtime.activityStatus, .idleWake)
        let completedOutboundCount = harness.completionCoordinator.completedDrafts.count

        // This models the 12 mini's hard case from the June 22 data: no trusted
        // vehicle evidence, automotive/speed/displacement all present, but only
        // about 219m of movement. Grace keeps the app alive, and the sustained
        // no-trust fallback should now confirm this as a visible trip.
        let resumeAt = parkedAt.addingTimeInterval(120)
        let duration: TimeInterval = 87
        let distance: Double = 219
        for offset in stride(from: 0.0, through: duration, by: 3.0) {
            harness.location.emit(sample: sample(
                at: resumeAt.addingTimeInterval(offset),
                metersNorth: 900 + distance * (offset / duration),
                speed: distance / duration,
                hint: .automotive
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertEqual(harness.runtime.activityStatus, .recording)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, completedOutboundCount)
    }

    func testPostDriveResumptionGraceExpiresToIdleAnchored() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(60),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state, postDriveResumptionGrace: 0.05)
        harness.runtime.startMonitoring()

        completeOutboundWithPedestrianExit(harness, start: start)

        XCTAssertEqual(harness.runtime.activityStatus, .idleWake)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.background.isActive)
        // During the grace the level stays .idleWake, so the service session is held
        // warm — a quick inter-leg return still has a session ready for background GPS.
        XCTAssertTrue(harness.serviceSession.isActive)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertGreaterThanOrEqual(harness.idleWake.monitoredAnchors.count, 1)
        // Grace expired → parked at idle-anchored → session released so the location
        // indicator goes dark (the reported "arrow stuck on for an hour" symptom).
        XCTAssertFalse(harness.serviceSession.isActive)
        XCTAssertGreaterThanOrEqual(harness.serviceSession.stopCount, 1)
    }

    func testDriveAwayWakeReestablishesServiceSessionFromIdleAnchored() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        // Parked: the session is released, so there is no indicator while idle.
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertFalse(harness.serviceSession.isActive)

        // Driving away trips the parked-anchor geofence exit. The wake escalates to
        // .idleWake and re-establishes the service session synchronously — before any
        // GPS is consumed — so releasing it while parked opens no detection gap.
        harness.idleWake.emitWake(at: anchor.timestamp.addingTimeInterval(300))

        XCTAssertNotEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testPauseAndStopInvalidateCaptureProviders() throws {
        let harness = try makeHarness()
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.location.activeConfiguration, .default)
        XCTAssertTrue(harness.motion.liveUpdatesStarted)
        XCTAssertTrue(harness.serviceSession.isActive)

        harness.runtime.pause(for: 60 * 60)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertGreaterThanOrEqual(harness.idleWake.stopCount, 1)
        XCTAssertFalse(harness.serviceSession.isActive)

        harness.runtime.stopMonitoring()
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.motion.liveUpdatesStarted)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertFalse(harness.serviceSession.isActive)
    }

    func testPendingIntentSignalIsConsumedOnStartup() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let pendingStore = PendingDriveStartSignalStore(context: context)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = try pendingStore.save(trigger: .vehicleBluetooth, at: createdAt, policy: .balanced)

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence)
        harness.runtime.startMonitoring()

        let latest = try XCTUnwrap(harness.pendingStore.fetchLatest())
        XCTAssertEqual(latest.id, pending.id)
        XCTAssertEqual(latest.status, .consumed)
        XCTAssertEqual(latest.captureID, harness.runtime.state.captureID)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .externalVehicleAutomation)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testArmDriveStartIntentSignalIsConsumedByRuntimeStartup() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileageTrackerIntentRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        var openPersistences: [PersistenceController] = []
        var stopRuntime: (() -> Void)?
        defer {
            stopRuntime?()
            IntentDataProvider.resetFactoryForTesting()
            for persistence in openPersistences {
                persistence.container.viewContext.reset()
                let coordinator = persistence.container.persistentStoreCoordinator
                for store in coordinator.persistentStores {
                    try? coordinator.remove(store)
                }
            }
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        IntentDataProvider.stackFactory = {
            let stack = try IntentDataStack(mode: .localOnly, storeDirectory: storeDirectory)
            openPersistences.append(stack.persistence)
            return stack
        }

        _ = try await ArmDriveStartIntent(trigger: .charger).perform()

        let persistence = try PersistenceController(mode: .localOnly, storeDirectory: storeDirectory)
        openPersistences.append(persistence)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence)
        stopRuntime = { harness.runtime.stopMonitoring() }

        harness.runtime.startMonitoring()

        let latest = try XCTUnwrap(harness.pendingStore.fetchLatest())
        XCTAssertEqual(latest.trigger, .charger)
        XCTAssertEqual(latest.status, .consumed)
        XCTAssertEqual(latest.captureID, harness.runtime.state.captureID)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .externalChargerAutomation)
    }

    func testWakeBootstrapConsumesPendingIntentSignalAndJournalsCount() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let pendingStore = PendingDriveStartSignalStore(context: context)
        let captureEventStore = DriveCaptureEventStore(context: context)
        let pending = try pendingStore.save(trigger: .vehicleBluetooth, at: Date(), policy: .balanced)

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        let latest = try XCTUnwrap(harness.pendingStore.fetchLatest())
        XCTAssertEqual(latest.id, pending.id)
        XCTAssertEqual(latest.status, .consumed)
        XCTAssertNotNil(latest.consumedAt)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .externalVehicleAutomation)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.serviceSession.isActive)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap pending signals consumed"
                && $0.wakeReason == DriveCaptureWakeReason.locationWake.rawValue
                && $0.detectionReason == "count=1"
        })
    }

    /// An App-Intent (Shortcut automation) launch bootstraps with
    /// `.backgroundLaunch`. It must arm the relaunch backbone and consume the
    /// intent's pending signal exactly like a location wake — deferring left a
    /// suspended process with no armed CoreLocation clients, losing whole
    /// drives (2026-07-01).
    func testBackgroundLaunchBootstrapConsumesPendingIntentSignal() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let pendingStore = PendingDriveStartSignalStore(context: context)
        let captureEventStore = DriveCaptureEventStore(context: context)
        let pending = try pendingStore.save(trigger: .vehicleBluetooth, at: Date(), policy: .balanced)

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)

        harness.runtime.bootstrapForWake(reason: .backgroundLaunch)

        let latest = try XCTUnwrap(harness.pendingStore.fetchLatest())
        XCTAssertEqual(latest.id, pending.id)
        XCTAssertEqual(latest.status, .consumed)
        XCTAssertNotNil(latest.consumedAt)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .externalVehicleAutomation)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.backgroundWake.isMonitoring, "background launch must arm the SLC + visit relaunch backbone")

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap started"
                && $0.wakeReason == DriveCaptureWakeReason.backgroundLaunch.rawValue
        })
        XCTAssertTrue(events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Wake bootstrap pending signals consumed"
                && $0.wakeReason == DriveCaptureWakeReason.backgroundLaunch.rawValue
                && $0.detectionReason == "count=1"
        })
    }

    func testLocationBackgroundWakeConsumesPendingIntentSignal() throws {
        let persistence = try PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let pendingStore = PendingDriveStartSignalStore(context: context)
        let pending = try pendingStore.save(trigger: .vehicleBluetooth, at: Date(), policy: .balanced)
        let diagnostics = DiagnosticsService()

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state, persistence: persistence, diagnostics: diagnostics)

        harness.runtime.startMonitoring()
        harness.runtime.bootstrapForWake(reason: .locationWake)

        let latest = try XCTUnwrap(harness.pendingStore.fetchLatest())
        XCTAssertEqual(latest.id, pending.id)
        XCTAssertEqual(latest.status, .consumed)
        XCTAssertNotNil(latest.consumedAt)
        XCTAssertTrue(harness.serviceSession.isActive)

        let data = try diagnostics.export(health: .unknown)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DiagnosticsExport.self, from: data)
        XCTAssertTrue(export.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Location background wake"
        })
    }

    func testExternalChargerAutomationStartsAssistCandidate() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.runtime.armDriveStart(trigger: .charger, at: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .externalChargerAutomation)
        XCTAssertEqual(harness.runtime.state.startSignal?.confidence, .assist)
        XCTAssertTrue(harness.runtime.state.startSignal?.powerContributed == true)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.serviceSession.isActive)
    }

    func testRescheduledStopDeadlineDoesNotFireSpuriously() async throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()
        var outputCount = 0
        harness.runtime.onOutput = { _ in outputCount += 1 }

        // Each re-arm cancels and replaces the pending candidate-expiry task.
        // A cancelled task that fires anyway re-enters persistStateAndHandle,
        // which reschedules (cancelling the replacement), producing a
        // perpetual fire/cancel loop that floods outputs.
        harness.runtime.armDriveStart(trigger: .charger, at: Date())
        harness.runtime.armDriveStart(trigger: .charger, at: Date())
        harness.runtime.armDriveStart(trigger: .charger, at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertTrue(harness.serviceSession.isActive)

        let settled = outputCount
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(outputCount, settled)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
    }

    /// 2026-08 field freeze: a checkpoint persisted `.paused` with a stop
    /// deadline already in the past ("Pause Today" while a park countdown was
    /// armed). `finalizeIfDue` cannot advance that state, so an armed timer
    /// fires at zero delay, re-arms, and spins the main actor — surviving
    /// every relaunch because the checkpoint reloads the same state.
    func testWedgedPausedCheckpointWithStaleStopDeadlineDoesNotSpin() async throws {
        let now = Date()
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = now
        state.phase = .paused
        state.pausedUntil = now.addingTimeInterval(3_600)
        state.stopDueAt = now.addingTimeInterval(-600)
        state.startedAt = now.addingTimeInterval(-1_200)
        state.pendingTripID = UUID()
        state.samples = [sample(at: now.addingTimeInterval(-700), metersNorth: 0, speed: 12, hint: .automotive)]
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()
        var outputCount = 0
        harness.runtime.onOutput = { _ in outputCount += 1 }

        let settled = outputCount
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(outputCount, settled, "a non-recording stop deadline must never arm a timer")
        XCTAssertEqual(harness.runtime.state.phase, .paused)
    }

    func testLocationCheckpointSaveIsThrottledOnUnchangedSignature() throws {
        let now = Date()
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = now
        state.phase = .recording
        state.pendingTripID = UUID()
        state.startedAt = now.addingTimeInterval(-60)
        state.samples = [sample(at: now.addingTimeInterval(-2), metersNorth: 0, speed: 12, hint: .automotive)]
        state.lastMovingAt = now.addingTimeInterval(-2)
        let harness = try makeHarness(
            initialState: state,
            checkpointSaveThrottleInterval: 600
        )
        harness.runtime.startMonitoring()
        let baseline = try checkpointSampleCount(in: harness.persistence)

        harness.location.emit(sample: sample(at: now.addingTimeInterval(1), metersNorth: 30, speed: 12, hint: .automotive))
        harness.location.emit(sample: sample(at: now.addingTimeInterval(2), metersNorth: 60, speed: 12, hint: .automotive))
        harness.location.emit(sample: sample(at: now.addingTimeInterval(3), metersNorth: 90, speed: 12, hint: .automotive))

        XCTAssertEqual(harness.runtime.state.samples.count, 4, "the live reducer keeps every sample")
        XCTAssertEqual(
            try checkpointSampleCount(in: harness.persistence),
            baseline,
            "unchanged-signature 1 Hz samples must not re-encode the checkpoint"
        )

        // A confirmed pedestrian walk-away completes the drive through the
        // same throttled location path — a signature change (phase and
        // pending draft) that must flush the checkpoint immediately.
        harness.location.emit(sample: sample(at: now.addingTimeInterval(40), metersNorth: 100, speed: 1.4, hint: .walking))
        harness.location.emit(sample: sample(at: now.addingTimeInterval(51), metersNorth: 120, speed: 1.4, hint: .walking))

        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)
        XCTAssertEqual(
            try checkpointPhaseRaw(in: harness.persistence),
            DriveCapturePhase.idle.rawValue,
            "the completion transition must persist through the throttled path"
        )
        XCTAssertEqual(try checkpointSampleCount(in: harness.persistence), 0)
    }

    func testCompletionRetryIsThrottledAndDraftIsRetained() throws {
        let now = Date()
        let draft = TripDraft(
            id: UUID(),
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(-300),
            samples: [
                sample(at: now.addingTimeInterval(-600), metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: now.addingTimeInterval(-300), metersNorth: 1_000, speed: 12, hint: .automotive)
            ],
            distanceMeters: 1_000
        )
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = now
        state.pendingCompletionDraft = draft
        let harness = try makeHarness(
            initialState: state,
            completionRetryMinimumInterval: 600
        )
        harness.completionCoordinator.completeError = RuntimePolicyTestError.completionRefused

        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)

        // Further capture events inside the interval must not re-attempt.
        harness.runtime.sceneBecameActive()
        harness.runtime.sceneEnteredBackground()

        XCTAssertEqual(
            harness.completionCoordinator.completedDrafts.count,
            1,
            "a throwing draft costs one attempt per interval, not one per event"
        )
        XCTAssertEqual(
            harness.runtime.state.pendingCompletionDraft?.id,
            draft.id,
            "the draft — and any user-entered fields it carries — is never discarded"
        )
    }

    func testCompletionRetriesAfterThrottleIntervalAndSavesTrip() async throws {
        let now = Date()
        let draft = TripDraft(
            id: UUID(),
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(-300),
            samples: [
                sample(at: now.addingTimeInterval(-600), metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: now.addingTimeInterval(-300), metersNorth: 1_000, speed: 12, hint: .automotive)
            ],
            distanceMeters: 1_000
        )
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = now
        state.pendingCompletionDraft = draft
        let harness = try makeHarness(
            initialState: state,
            completionRetryMinimumInterval: 0.05
        )
        harness.completionCoordinator.completeError = RuntimePolicyTestError.completionRefused
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)

        // Transient failure clears; the next event past the interval succeeds.
        harness.completionCoordinator.completeError = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        harness.runtime.sceneBecameActive()

        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 2)
        XCTAssertNil(
            harness.runtime.state.pendingCompletionDraft,
            "a transient error must never permanently drop a real trip"
        )
    }

    private func checkpointSampleCount(in persistence: PersistenceController) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ActiveDriveEntity")
        let rows = try persistence.container.viewContext.fetch(request)
        return (rows.first?.value(forKey: "sampleCount") as? Int) ?? 0
    }

    private func checkpointPhaseRaw(in persistence: PersistenceController) throws -> String? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ActiveDriveEntity")
        let rows = try persistence.container.viewContext.fetch(request)
        return rows.first?.value(forKey: "phaseRaw") as? String
    }

    func testRecoveryJournalsExactlyOncePerBurstAcrossKillCycles() throws {
        let persistence = try PersistenceController(inMemory: true)
        let diagnosticSampleStore = DiagnosticSampleStore(context: persistence.container.viewContext)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // First cycle: derived-speed-only candidate collects through its
        // signal window (it can never confirm without reported speed) and
        // times out at the +190 sample.
        let firstCycle = [
            sample(at: start.addingTimeInterval(1), metersNorth: 120, speed: nil, hint: .unknown),
            sample(at: start.addingTimeInterval(4), metersNorth: 180, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(7), metersNorth: 260, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(12), metersNorth: 360, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(30), metersNorth: 520, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(190), metersNorth: 900, speed: nil, hint: .automotive)
        ]
        firstCycle.forEach { harness.location.emit(sample: $0) }
        XCTAssertEqual(harness.runtime.state.phase, .idle)

        // Second cycle in the same diagnostic burst (gaps < 5 min): the revived
        // candidate inherits the first cycle's elapsed clock, so the walking
        // flicker's fresh contradiction hold defers it to diagnostics on the
        // very next sample (+210) — a second kill in the same burst that must
        // not journal a second recovery. No trailing sample: it would arm a
        // fresh candidate and mask the post-kill idle assertion.
        let secondCycle = [
            sample(at: start.addingTimeInterval(200), metersNorth: 1_020, speed: nil, hint: .automotive),
            sample(at: start.addingTimeInterval(205), metersNorth: 1_040, speed: 1.4, hint: .walking),
            sample(at: start.addingTimeInterval(210), metersNorth: 1_140, speed: nil, hint: .automotive)
        ]
        secondCycle.forEach { harness.location.emit(sample: $0) }
        XCTAssertEqual(harness.runtime.state.phase, .idle)

        let events = try captureEventStore.fetchEvents(
            since: start.addingTimeInterval(-1),
            until: start.addingTimeInterval(300)
        )
        let recoveryEvents = events.filter { $0.message == "Retained possible drive candidate from diagnostic samples" }
        XCTAssertEqual(recoveryEvents.count, 1)
    }

    func testBackgroundWakeJournalIsThrottled() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()

        harness.runtime.bootstrapForWake(reason: .locationWake)
        harness.runtime.bootstrapForWake(reason: .locationWake)
        harness.runtime.bootstrapForWake(reason: .locationWake)

        let events = try captureEventStore.fetchEvents(
            since: Date().addingTimeInterval(-60),
            until: Date().addingTimeInterval(60)
        )
        let wakeEvents = events.filter { $0.message == "Location background wake" }
        XCTAssertEqual(wakeEvents.count, 1)
    }

    // 2026-06-18 P2a regression: the 17 Pro left a zero-sample candidate live for
    // minutes because a warm (already-monitoring) location-wake bootstrap reloaded
    // state and applied policy but never settled due work. The warm branch must now
    // time out a candidate that is already past its expiry.
    func testLocationWakeBootstrapExpiresStaleCandidate() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        // A probe armed by an earlier wake whose start signal is already past expiry
        // and that never saw a driving sample.
        harness.runtime.armDriveStart(trigger: .vehicleBluetooth, at: Date().addingTimeInterval(-3600))
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        XCTAssertEqual(harness.runtime.state.phase, .idle, "a warm wake must time out the expired candidate")
    }

    // Guard rail for the wake-finalize: a freshly-armed candidate (expiry in the
    // future) must survive a wake and is not killed early.
    func testLocationWakeBootstrapKeepsFreshCandidate() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.runtime.armDriveStart(trigger: .vehicleBluetooth, at: Date())
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        harness.runtime.bootstrapForWake(reason: .locationWake)

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "a live candidate must not be finalized by a wake")
    }

    func testStartSignalForcesRouteObservationRequestWithTenSecondFloor() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        var requestCount = 0
        let harness = try makeHarness(initialState: state, routeObservationRequest: { requestCount += 1 })
        harness.runtime.startMonitoring()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        harness.runtime.armDriveStart(trigger: .charger, at: start)
        XCTAssertEqual(requestCount, 1)

        // Forced requests still respect the 10 s floor...
        harness.runtime.armDriveStart(trigger: .charger, at: start.addingTimeInterval(5))
        XCTAssertEqual(requestCount, 1)

        // ...and fire again once it has elapsed.
        harness.runtime.armDriveStart(trigger: .charger, at: start.addingTimeInterval(15))
        XCTAssertEqual(requestCount, 2)
    }

    func testRouteObservationPollsOnSixtySecondCadenceWhileRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        )
        var requestCount = 0
        let harness = try makeHarness(initialState: state, routeObservationRequest: { requestCount += 1 })
        harness.runtime.startMonitoring()

        harness.location.emit(sample: sample(at: start.addingTimeInterval(40), metersNorth: 520, speed: 12, hint: .automotive))
        XCTAssertEqual(requestCount, 1)

        harness.location.emit(sample: sample(at: start.addingTimeInterval(70), metersNorth: 900, speed: 12, hint: .automotive))
        XCTAssertEqual(requestCount, 1)

        harness.location.emit(sample: sample(at: start.addingTimeInterval(101), metersNorth: 1_300, speed: 12, hint: .automotive))
        XCTAssertEqual(requestCount, 2)
    }

    func testNoRouteObservationRequestsWhileIdle() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        var requestCount = 0
        let harness = try makeHarness(initialState: state, routeObservationRequest: { requestCount += 1 })
        harness.runtime.startMonitoring()

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        harness.location.emit(sample: sample(at: start, metersNorth: 0, speed: 0, hint: .stationary))
        harness.location.emit(sample: sample(at: start.addingTimeInterval(90), metersNorth: 2, speed: 0, hint: .stationary))

        XCTAssertEqual(requestCount, 0)
    }

    func testRejectedAssistCandidateStopsHighFidelityImmediately() throws {
        var configuration = DriveCaptureConfiguration.automatic
        configuration.startPolicy.signalHighFidelityWindow = 1.0
        // Charger connects while parked at a known anchor.
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            configuration: configuration,
            idlePrimingDuration: 0.25
        )
        harness.runtime.startMonitoring()
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertFalse(harness.serviceSession.isActive)   // parked → no session

        // Charger connects → assist candidate → high-fidelity GPS + session on.
        let armAt = Date()
        harness.runtime.armDriveStart(trigger: .charger, at: armAt)
        XCTAssertEqual(harness.runtime.activityStatus, .candidate)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertTrue(harness.serviceSession.isActive)

        // User walks away instead of driving. The charger trigger opens the
        // pre-movement grace, which tolerates stationary/low-speed samples — but
        // pedestrian (walking) samples are never graced, so three of them reject the
        // candidate (resilience tolerates two). Rejection should close the
        // high-fidelity window immediately — not burn the charger's high-fidelity
        // budget waiting for a background timer that iOS may suspend.
        for offset in [1.0, 2.0, 3.0] {
            harness.location.emit(sample: sample(at: armAt.addingTimeInterval(offset), metersNorth: offset, speed: 1.3, hint: .walking))
        }
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        // Back to parked idle-anchored → high-fidelity GPS and service session released.
        XCTAssertFalse(harness.serviceSession.isActive)
    }

    func testIdleAnchoredReassertsMonitorOnWarmWakeWithoutDuplicateAnchor() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))

        harness.runtime.bootstrapForWake(reason: .locationWake)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        let ensureAfterFirstWake = harness.idleWake.ensureCount
        XCTAssertGreaterThanOrEqual(ensureAfterFirstWake, 1)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.count, 1)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)

        // A second wake at the unchanged idle-anchored level must still re-assert
        // monitoring (idempotent re-attach) without arming a duplicate anchor.
        harness.runtime.bootstrapForWake(reason: .locationWake)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertGreaterThan(harness.idleWake.ensureCount, ensureAfterFirstWake)
        XCTAssertEqual(harness.idleWake.monitoredAnchors.count, 1)
    }

    func testFalseWakeReturnsToIdleAnchoredAfterNoDrivingSignal() throws {
        var configuration = DriveCaptureConfiguration.automatic
        configuration.startPolicy.signalHighFidelityWindow = 0.4
        let start = Date()
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            configuration: configuration,
            idlePrimingDuration: 0.25
        )
        harness.runtime.startMonitoring()

        harness.idleWake.emitWake(at: start)
        for offset in [0.0, 0.01, 0.02, 0.03] {
            harness.location.emit(sample: sample(
                at: start.addingTimeInterval(offset),
                metersNorth: 1,
                speed: 0,
                hint: .stationary
            ))
        }

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertNil(harness.location.activeConfiguration)
        XCTAssertFalse(harness.background.isActive)
        XCTAssertTrue(harness.backgroundWake.isMonitoring)
        XCTAssertFalse(harness.serviceSession.isActive)   // false wake settled back to parked idle → session released
        XCTAssertTrue(harness.completionCoordinator.completedDrafts.isEmpty)
    }

    func testSplitCurrentDriveNowSavesLegAndKeepsRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let state = DriveCaptureState(
            pendingTripID: UUID(),
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()
        let beforeSummary = try XCTUnwrap(harness.runtime.activeDriveSummary)

        let splitDate = start.addingTimeInterval(60)
        harness.runtime.splitCurrentDriveNow(at: splitDate)

        // The finished leg is saved exactly once, ending at the split.
        XCTAssertEqual(harness.completionCoordinator.completedDrafts.count, 1)
        let draft = try XCTUnwrap(harness.completionCoordinator.completedDrafts.first)
        XCTAssertEqual(draft.endDate, splitDate)
        XCTAssertEqual(draft.startDate, start)

        // Recording continues as a fresh leg without dropping GPS fidelity.
        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertEqual(harness.runtime.activityStatus, .recording)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        let after = try XCTUnwrap(harness.runtime.activeDriveSummary)
        XCTAssertEqual(after.startedAt, splitDate)
        XCTAssertNotEqual(after.pendingTripID, beforeSummary.pendingTripID)
        XCTAssertEqual(after.distanceMeters, 0)

        // The persisted checkpoint is the live new-leg recording, and the state
        // handed to the clear-if-idle step is a recording with no pending draft —
        // the real coordinator re-saves such a state rather than clearing it
        // (pinned by testCompletionCoordinatorKeepsRecordingCheckpoint in AppCore).
        let checkpoint = try XCTUnwrap(ActiveDriveStore(context: harness.persistence.container.viewContext).load())
        XCTAssertEqual(checkpoint.phase, .recording)
        XCTAssertEqual(checkpoint.startedAt, splitDate)
        let cleared = try XCTUnwrap(harness.completionCoordinator.clearedStates.last)
        XCTAssertEqual(cleared.phase, .recording)
        XCTAssertNil(cleared.pendingCompletionDraft)
    }

    func testSplitCurrentDriveNowWhileIdleCompletesNothing() throws {
        let harness = try makeHarness()
        harness.runtime.startMonitoring()

        harness.runtime.splitCurrentDriveNow()

        XCTAssertTrue(harness.completionCoordinator.completedDrafts.isEmpty)
        XCTAssertEqual(harness.runtime.state.phase, .idle)
    }

    func testActiveDriveClearsBeforeCompletedTripCallback() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let latchedVehicleID = UUID()
        let conflictingVehicleID = UUID()
        let state = DriveCaptureState(
            pendingTripID: UUID(),
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 500, speed: 12, hint: .automotive)
            ],
            startVehicleHint: latchedVehicleID,
            startVehicleAssignmentSource: .vehicleConnection,
            conflictingVehicleIDs: [conflictingVehicleID]
        )
        let harness = try makeHarness(initialState: state)
        var callbacks: [String] = []
        var deliveredConflicts: [UUID] = []
        harness.runtime.onActiveDriveChanged = { callbacks.append($0 == nil ? "idle" : "active") }
        harness.runtime.onTripCompleted = { _, _, conflicts in
            deliveredConflicts = conflicts
            callbacks.append("trip")
        }

        harness.runtime.startMonitoring()
        harness.runtime.endCurrentDriveNow(at: start.addingTimeInterval(60))

        XCTAssertEqual(callbacks, ["active", "idle", "trip"])
        XCTAssertEqual(deliveredConflicts, [conflictingVehicleID])
    }

    func testDiscardedCompletionClearsVehicleParkingAnchorBeforeCheckpointCleanup() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(600),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(600), metersNorth: 5_000, speed: 0, hint: .stationary)
            ],
            distanceMeters: 5_000
        )
        let anchor = sample(at: draft.endDate, metersNorth: 5_000, speed: 0, hint: .stationary)
        var state = DriveCaptureState()
        state.pendingCompletionDraft = draft
        state.pendingTripID = draft.id
        state.parkedStartAnchor = anchor
        state.vehicleParkingAnchor = anchor
        let harness = try makeHarness(initialState: state)
        harness.completionCoordinator.shouldDiscard = true

        harness.runtime.startMonitoring()

        XCTAssertNil(harness.runtime.state.vehicleParkingAnchor)
        XCTAssertEqual(harness.runtime.state.parkedStartAnchor, anchor)
        XCTAssertNil(harness.completionCoordinator.clearedStates.last?.vehicleParkingAnchor)
    }
}

private extension DriveCaptureRuntimePolicyTests {
    // MARK: - Classic-manager GPS fallback + restoration notice (2026-07-05 regression)
    //
    // Field incident: every CLServiceSession created from background wakes was
    // refused (`insufficientlyInUse`), liveUpdates delivered zero fixes for a
    // whole drive, and the trip was lost. The fallback carries the drive on the
    // classic delegate path; the notice is the human backstop.

    private func strongCandidateState(start: Date, anchor: LocationSample? = nil) -> DriveCaptureState {
        DriveCaptureState(
            phase: .candidate,
            candidateStartedAt: start,
            candidateSamples: [],
            parkedStartAnchor: anchor,
            startSignal: DriveStartSignal(
                source: .motionAutomotive,
                confidence: .strong,
                startedAt: start,
                expiresAt: start.addingTimeInterval(300)
            )
        )
    }

    private func recordingState(start: Date) -> DriveCaptureState {
        DriveCaptureState(
            phase: .recording,
            startedAt: start,
            lastMovingAt: start.addingTimeInterval(30),
            samples: [
                sample(at: start, metersNorth: 0, speed: 12, hint: .automotive),
                sample(at: start.addingTimeInterval(30), metersNorth: 400, speed: 12, hint: .automotive)
            ]
        )
    }

    func testUnfulfilledDiagnosticEngagesFallbackDuringStrongCandidate() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: strongCandidateState(start: start),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        XCTAssertTrue(harness.fallback.isActive)
        XCTAssertEqual(harness.fallback.activeConfiguration, .automotiveNavigation)
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.message == "GPS fallback engaged"
                && ($0.detectionReason?.contains("trigger=sessionDiagnostic") ?? false)
        })
    }

    func testUnfulfilledDiagnosticEngagesFallbackWhileRecording() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        XCTAssertTrue(harness.fallback.isActive)
        XCTAssertEqual(harness.fallback.activeConfiguration, .automotiveNavigation)
    }

    func testUnfulfilledDiagnosticWhileIdleAnchoredDoesNotEngageFallback() throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        XCTAssertFalse(harness.fallback.isActive)
        XCTAssertEqual(harness.fallback.startedConfigurations, [])
    }

    func testWeakCandidateWithoutBluetoothOrPowerDoesNotEngageFallback() throws {
        // The evidence gate legitimately opens when the host reports connected
        // power (the runtime reads real UIDevice battery state, no seam).
        UIDevice.current.isBatteryMonitoringEnabled = true
        try XCTSkipIf(
            UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
            "test host reports power connected; the power leg of the evidence gate would open"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = strongCandidateState(start: start)
        state.startSignal = DriveStartSignal(
            source: .parkedAnchorExit,
            confidence: .assist,
            startedAt: start,
            expiresAt: start.addingTimeInterval(300)
        )
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        XCTAssertFalse(harness.fallback.isActive)
    }

    func testServiceSessionRequiredUpdateEngagesFallbackWithEvidence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()

        harness.location.emitServiceSessionRequired()

        XCTAssertTrue(harness.fallback.isActive)
    }

    func testFallbackSamplesFeedReducer() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        XCTAssertTrue(harness.fallback.isActive)
        let samplesBefore = harness.runtime.state.samples.count

        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(90), metersNorth: 1200, speed: 12, hint: .automotive))

        XCTAssertEqual(harness.runtime.state.phase, .recording)
        XCTAssertGreaterThan(harness.runtime.state.samples.count, samplesBefore)
        XCTAssertEqual(harness.runtime.state.lastProcessedLocationTimestamp, start.addingTimeInterval(90))
    }

    func testPrimarySampleDisengagesFallback() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        XCTAssertTrue(harness.fallback.isActive)

        harness.location.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))

        XCTAssertFalse(harness.fallback.isActive)
        XCTAssertEqual(harness.fallback.stopCount, 1)
    }

    func testPauseDisengagesFallback() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        XCTAssertTrue(harness.fallback.isActive)

        harness.runtime.pause(for: 3600)

        XCTAssertFalse(harness.fallback.isActive)
    }

    func testStopMonitoringStopsFallback() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        XCTAssertTrue(harness.fallback.isActive)

        harness.runtime.stopMonitoring()

        XCTAssertFalse(harness.fallback.isActive)
    }

    func testFallbackDoesNotConsumePrimaryRestartBudget() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        XCTAssertTrue(harness.fallback.isActive)
        let restartsBefore = harness.location.startedConfigurations.count

        // Primary stream deaths restart on the primary budget, untouched by the
        // engaged fallback.
        harness.location.endStream()
        XCTAssertEqual(harness.location.startedConfigurations.count, restartsBefore + 1)
        XCTAssertTrue(harness.fallback.isActive)
    }

    func testFallbackSamplesDoNotClearServiceSessionRequiredFlag() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))
        let cyclesBefore = harness.serviceSession.stopCount

        // A movement-proving wake still re-attempts to re-honor the session:
        // fallback samples must not have cleared `serviceSessionRequiredSinceLastSample`.
        harness.backgroundWake.emitSignificantChange(at: Date())

        XCTAssertEqual(harness.serviceSession.stopCount, cyclesBefore + 1)
    }

    func testSessionCyclingRateLimitedWhileFallbackDelivering() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: recordingState(start: start),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))
        let before = Date().addingTimeInterval(-1)

        harness.backgroundWake.emitSignificantChange(at: Date())
        let cyclesAfterFirst = harness.serviceSession.stopCount
        harness.backgroundWake.emitSignificantChange(at: Date())

        XCTAssertEqual(harness.serviceSession.stopCount, cyclesAfterFirst, "second wake inside the window must not cycle again")
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.message == "Stall recovery skipped"
                && ($0.detectionReason?.contains("fallbackDelivering") ?? false)
        })
    }

    func testBackgroundActivitySessionNotInvalidatedByBackgroundRecovery() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        XCTAssertTrue(harness.background.isActive)
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        harness.backgroundWake.emitSignificantChange(at: Date())

        // Per CLBackgroundActivitySession.h a replacement session created in the
        // background can never activate; the recovery path must preserve the
        // existing one instead of cycling it.
        XCTAssertEqual(harness.background.stopCount, 0)
        XCTAssertTrue(harness.background.isActive)
    }

    func testOutOfOrderFallbackSampleIsDropped() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: recordingState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.location.emit(sample: sample(at: start.addingTimeInterval(100), metersNorth: 1300, speed: 12, hint: .automotive))
        let samplesBefore = harness.runtime.state.samples.count

        // Late in-flight fallback batch from before the primary resumed.
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(50), metersNorth: 700, speed: 12, hint: .automotive))

        XCTAssertEqual(harness.runtime.state.samples.count, samplesBefore)
        XCTAssertEqual(harness.runtime.state.lastProcessedLocationTimestamp, start.addingTimeInterval(100))
    }

    func testPrimaryResumptionMidCandidatePreservesCandidateState() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(initialState: strongCandidateState(start: start))
        harness.runtime.startMonitoring()
        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(10), metersNorth: 100, speed: 12, hint: .automotive))
        XCTAssertFalse(harness.runtime.state.candidateSamples.isEmpty || harness.runtime.state.phase == .idle)

        harness.location.emit(sample: sample(at: start.addingTimeInterval(20), metersNorth: 220, speed: 12, hint: .automotive))

        XCTAssertFalse(harness.fallback.isActive)
        XCTAssertTrue(harness.runtime.state.phase == .candidate || harness.runtime.state.phase == .recording)
        XCTAssertEqual(harness.runtime.state.lastProcessedLocationTimestamp, start.addingTimeInterval(20))
    }

    func testRestorationNeededFiresAfterQuietUnfulfilledWithEvidence() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: strongCandidateState(start: start),
            trackingRestorationNoticeDelay: 0.05
        )
        harness.runtime.startMonitoring()
        let fired = expectation(description: "restoration notice requested")
        var received: DriveTrackingRestorationAdvice?
        harness.runtime.onTrackingRestorationNeeded = { advice in
            received = advice
            fired.fulfill()
        }

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(received?.phase, .candidate)
        XCTAssertEqual(received?.fallbackEngaged, true)
        XCTAssertEqual(received?.fallbackSampleCount, 0)
    }

    func testRestorationNeededSuppressedWhenFallbackDeliversSamples() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: recordingState(start: start),
            trackingRestorationNoticeDelay: 0.05
        )
        harness.runtime.startMonitoring()
        let fired = expectation(description: "restoration notice requested")
        fired.isInverted = true
        harness.runtime.onTrackingRestorationNeeded = { _ in fired.fulfill() }

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.fallback.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))

        await fulfillment(of: [fired], timeout: 0.4)
    }

    func testRestorationNeededSuppressedWhenPrimaryRecovers() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: recordingState(start: start),
            trackingRestorationNoticeDelay: 0.05
        )
        harness.runtime.startMonitoring()
        let fired = expectation(description: "restoration notice requested")
        fired.isInverted = true
        harness.runtime.onTrackingRestorationNeeded = { _ in fired.fulfill() }

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.location.emit(sample: sample(at: start.addingTimeInterval(60), metersNorth: 800, speed: 12, hint: .automotive))

        await fulfillment(of: [fired], timeout: 0.4)
    }

    func testRestorationNeededSuppressedWhenSceneBecomesActive() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let harness = try makeHarness(
            initialState: recordingState(start: start),
            trackingRestorationNoticeDelay: 0.05
        )
        harness.runtime.startMonitoring()
        let fired = expectation(description: "restoration notice requested")
        fired.isInverted = true
        harness.runtime.onTrackingRestorationNeeded = { _ in fired.fulfill() }

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))
        harness.runtime.sceneBecameActive()

        await fulfillment(of: [fired], timeout: 0.4)
    }

    func testRestorationNeededNotArmedWhileIdle() async throws {
        let anchor = sample(at: Date(timeIntervalSince1970: 1_800_000_000), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            trackingRestorationNoticeDelay: 0.05
        )
        harness.runtime.startMonitoring()
        let fired = expectation(description: "restoration notice requested")
        fired.isInverted = true
        harness.runtime.onTrackingRestorationNeeded = { _ in fired.fulfill() }

        harness.serviceSession.emitDiagnostic(DriveServiceSessionDiagnostic(insufficientlyInUse: true))

        await fulfillment(of: [fired], timeout: 0.4)
    }

    // MARK: - Anchor-exit churn cooldown + pending-signal replay (2026-07-05 regression, Phase 2)

    /// The walk-away loop: exit arms → walking kills → exit re-arms, each cycle
    /// cold-starting GPS and a service session (~20×/min in the field log).
    /// After the pedestrian kill, rapid exits must not touch the session stack.
    func testJuly5AnchorExitChurnDoesNotCycleServiceSession() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        harness.idleWake.emitWake(at: start)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.serviceSession.startCount, 1)

        harness.motion.emit(MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]))
        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)

        // Rapid re-fires: the first past the 15 s floor hits the cooldown gate
        // (journaled once); the rest are eaten silently.
        harness.idleWake.emitWake(at: start.addingTimeInterval(20))
        harness.idleWake.emitWake(at: start.addingTimeInterval(22))
        harness.idleWake.emitWake(at: start.addingTimeInterval(40))
        harness.idleWake.emitWake(at: start.addingTimeInterval(60))

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.runtime.activityStatus, .idleAnchored)
        XCTAssertEqual(harness.serviceSession.startCount, 1, "the churn must not restart the service session")
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message == "Parked anchor exit suppressed" }.count, 1)
        XCTAssertEqual(events.filter { $0.message.hasPrefix("Drive candidate started") }.count, 1)
    }

    func testDriveAwayDuringAnchorExitCooldownStillRecordsViaMotion() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()
        harness.idleWake.emitWake(at: start)
        harness.motion.emit(MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]))
        XCTAssertEqual(harness.runtime.state.phase, .idle)

        // User reaches the car inside the cooldown: automotive motion is not
        // gated and re-opens high-fidelity capture.
        harness.motion.emit(MotionActivitySnapshot(startDate: start.addingTimeInterval(30), confidence: .high, hints: [.automotive]))

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertEqual(harness.serviceSession.startCount, 2)
    }

    // MARK: - Still-parked SLC wake suppression (2026-07-06 stationary-home churn regression)

    /// 2026-07-06: iOS relaunched the app for an SLC event every 2-8 minutes
    /// while the phone sat at the parked anchor all day; each wake armed a
    /// candidate + full-accuracy service session that a stationary
    /// contradiction killed within a second, keeping the location indicator
    /// lit. A fresh, accurate SLC fix inside the parked-anchor fence carries
    /// no drive-start information and must not touch the GPS stack.
    func testJuly6StationaryHomeSlcChurnIsSuppressedAtParkedAnchor() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        harness.backgroundWake.emitSignificantChange(
            at: now,
            sample: sample(at: Date(), metersNorth: 0, speed: 0, hint: .stationary)
        )

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertNil(harness.location.activeConfiguration, "a suppressed wake must not open live GPS")
        XCTAssertEqual(harness.serviceSession.startCount, 0, "a suppressed wake must not start a service session")
        XCTAssertTrue(harness.backgroundWake.isMonitoring, "the relaunch backbone stays armed")

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message == "Significant change wake suppressed at parked anchor" }.count, 1)
        XCTAssertFalse(events.contains { $0.message == "Significant location change wake" })
        XCTAssertFalse(events.contains { $0.message.hasPrefix("Drive candidate started") })
    }

    func testJuly6SlcSuppressionJournalIsRateLimitedPerWindow() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        for _ in 0..<3 {
            harness.backgroundWake.emitSignificantChange(
                at: Date(),
                sample: sample(at: Date(), metersNorth: 0, speed: 0, hint: .stationary)
            )
        }

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.serviceSession.startCount, 0)
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message == "Significant change wake suppressed at parked anchor" }.count, 1)
    }

    func testSlcWakeOutsideAnchorRadiusStillArms() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(
            at: now,
            sample: sample(at: Date(), metersNorth: 300, speed: nil, hint: .unknown)
        )

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "a fix outside the fence is a real movement wake")
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .significantLocationChange)
        XCTAssertEqual(harness.location.activeConfiguration, .automotiveNavigation)
        XCTAssertEqual(harness.serviceSession.startCount, 1)
    }

    func testSlcWakeWithPoorAccuracyFixStillArms() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        let blurryFix = LocationSample(
            timestamp: Date(),
            latitude: 40,
            longitude: -73,
            horizontalAccuracy: 100,
            speedMetersPerSecond: nil,
            motionHint: .unknown
        )
        harness.backgroundWake.emitSignificantChange(at: now, sample: blurryFix)

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "an untrustworthy fix must fail open")
    }

    func testSlcWakeWithStaleFixStillArms() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(
            at: now,
            sample: sample(at: Date().addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        )

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "a stale cached fix must fail open")
    }

    func testSlcWakeWithoutLocationStillArms() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(at: now)

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "a wake without a fix must fail open")
    }

    func testSlcWakeWithoutParkedAnchorStillArms() throws {
        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(initialState: state)
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitSignificantChange(
            at: Date(),
            sample: sample(at: Date(), metersNorth: 0, speed: 0, hint: .stationary)
        )

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "no anchor means nothing to gate against")
    }

    /// A visit departure's coordinate is the place being LEFT — proximity to
    /// the anchor is expected for a genuine drive-away and must never gate it.
    func testVisitDepartureAtParkedAnchorStillArms() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()

        harness.backgroundWake.emitVisitDeparture(at: now)

        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.runtime.state.startSignal?.source, .visitDeparture)
    }

    func testSlcWakeAtAnchorWhileCandidateIsNotGated() throws {
        let now = Date()
        let anchor = sample(at: now.addingTimeInterval(-3600), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()
        harness.backgroundWake.emitSignificantChange(at: now)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        harness.backgroundWake.emitSignificantChange(
            at: Date(),
            sample: sample(at: Date(), metersNorth: 0, speed: 0, hint: .stationary)
        )

        XCTAssertEqual(harness.runtime.state.phase, .candidate, "the still-parked gate only applies at idle")
    }

    /// Gate B: right after a never-moved pedestrian/stationary kill, an SLC
    /// wake landing OUTSIDE the fence (so the spatial gate passes it) is still
    /// absorbed by the post-kill cooldown instead of reopening the probe.
    func testJuly6SlcWakeDuringPostKillCooldownIsSuppressed() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let start = Date()
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(
            initialState: DriveCaptureState(parkedStartAnchor: anchor),
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let before = Date().addingTimeInterval(-1)

        harness.idleWake.emitWake(at: start)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)
        XCTAssertEqual(harness.serviceSession.startCount, 1)
        harness.motion.emit(MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]))
        XCTAssertEqual(harness.runtime.state.phase, .idle)

        harness.backgroundWake.emitSignificantChange(
            at: Date(),
            sample: sample(at: Date(), metersNorth: 400, speed: nil, hint: .unknown)
        )

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.serviceSession.startCount, 1, "the cooldown must keep the session stack down")
        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertTrue(events.contains {
            $0.message == "Parked anchor exit suppressed" && $0.wakeReason == "significantLocationChange"
        })
    }

    func testVisitDepartureDuringPostKillCooldownIsSuppressed() throws {
        let start = Date()
        let anchor = sample(at: start.addingTimeInterval(-120), metersNorth: 0, speed: 0, hint: .stationary)
        let harness = try makeHarness(initialState: DriveCaptureState(parkedStartAnchor: anchor))
        harness.runtime.startMonitoring()
        harness.idleWake.emitWake(at: start)
        harness.motion.emit(MotionActivitySnapshot(startDate: start.addingTimeInterval(1), confidence: .high, hints: [.walking]))
        XCTAssertEqual(harness.runtime.state.phase, .idle)

        harness.backgroundWake.emitVisitDeparture(at: Date())

        XCTAssertEqual(harness.runtime.state.phase, .idle)
        XCTAssertEqual(harness.serviceSession.startCount, 1)
    }

    /// The 2026-07-05 journal carried 36 same-stamp "Drive candidate started"
    /// rows; accumulated same-trigger pending rows must collapse to the newest
    /// before anything is applied.
    func testPendingReplayCollapsesDuplicateTriggersToSingleArm() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let pendingStore = PendingDriveStartSignalStore(context: persistence.container.viewContext)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let old1 = try pendingStore.save(trigger: .vehicleBluetooth, at: createdAt, policy: .balanced)
        let old2 = try pendingStore.save(trigger: .vehicleBluetooth, at: createdAt.addingTimeInterval(1), policy: .balanced)
        let newest = try pendingStore.save(trigger: .vehicleBluetooth, at: createdAt.addingTimeInterval(2), policy: .balanced)
        let charger = try pendingStore.save(trigger: .charger, at: createdAt.addingTimeInterval(1), policy: .balanced)

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        let before = Date().addingTimeInterval(-1)
        harness.runtime.startMonitoring()

        let signals = try harness.pendingStore.fetchSignals(since: nil, until: nil)
        let byID = Dictionary(uniqueKeysWithValues: signals.map { ($0.id, $0) })
        XCTAssertEqual(byID[old1.id]?.result, "superseded")
        XCTAssertEqual(byID[old2.id]?.result, "superseded")
        XCTAssertEqual(byID[newest.id]?.status, .consumed)
        XCTAssertEqual(byID[newest.id]?.result, "candidate armed")
        XCTAssertEqual(byID[charger.id]?.status, .consumed)
        XCTAssertEqual(harness.runtime.state.phase, .candidate)

        let events = try captureEventStore.fetchEvents(since: before, until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message.hasPrefix("Drive candidate started") }.count, 1,
                       "one arm; the second applied signal merges into the live candidate")
        XCTAssertEqual(events.filter { $0.message.hasPrefix("Consumed pending drive start signal") }.count, 2)
        XCTAssertTrue(events.contains { $0.message == "Superseded 2 duplicate pending drive start signal(s)" })
    }

    func testSecondBootstrapAppliesNoPendingSignalsAfterConsumption() throws {
        let persistence = try PersistenceController(inMemory: true)
        let captureEventStore = DriveCaptureEventStore(context: persistence.container.viewContext)
        let pendingStore = PendingDriveStartSignalStore(context: persistence.container.viewContext)
        _ = try pendingStore.save(trigger: .vehicleBluetooth, at: Date(timeIntervalSince1970: 1_800_000_000), policy: .balanced)

        var state = DriveCaptureState()
        state.idlePrimingExhaustedAt = Date()
        let harness = try makeHarness(
            initialState: state,
            persistence: persistence,
            captureEventStore: captureEventStore
        )
        harness.runtime.startMonitoring()
        let betweenBootstraps = Date()

        harness.runtime.bootstrapForWake(reason: .locationWake)

        let events = try captureEventStore.fetchEvents(since: betweenBootstraps, until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.filter { $0.message.hasPrefix("Consumed pending drive start signal") }.count, 0,
                       "a consumed row must never replay on the next wake")
    }

    struct Harness {
        var runtime: DriveCaptureRuntime
        var location: FakeDriveLocationProvider
        var fallback: FakeFallbackLocationProvider
        var motion: FakeMotionEvidenceProvider
        var idleWake: FakeDriveIdleWakeProvider
        var backgroundWake: FakeDriveBackgroundWakeProvider
        var background: FakeBackgroundActivitySessionProvider
        var serviceSession: FakeDriveLocationServiceSessionProvider
        var healthStatus: FakeDriveCaptureHealthStatusProvider
        var completionCoordinator: FakeDriveCompletionCoordinator
        var diagnosticSampleStore: DiagnosticSampleStore?
        var captureEventStore: DriveCaptureEventStore?
        var pendingStore: PendingDriveStartSignalStore
        var persistence: PersistenceController
    }

    func makeHarness(
        initialState: DriveCaptureState? = nil,
        persistence: PersistenceController? = nil,
        diagnostics: DiagnosticsService? = nil,
        diagnosticSampleStore: DiagnosticSampleStore? = nil,
        captureEventStore: DriveCaptureEventStore? = nil,
        configuration: DriveCaptureConfiguration = .automatic,
        diagnosticsMode: DriveCaptureDiagnosticsMode = .detailed,
        idlePrimingDuration: TimeInterval = 45,
        permissionServiceSessionLease: TimeInterval = 60,
        postDriveResumptionGrace: TimeInterval? = nil,
        trackingRestorationNoticeDelay: TimeInterval? = nil,
        possibleDriveRecoveryQuietPeriod: TimeInterval? = nil,
        completionRetryMinimumInterval: TimeInterval? = nil,
        checkpointSaveThrottleInterval: TimeInterval? = nil,
        routeObservationRequest: (() -> Void)? = nil,
        // Legacy runtime regressions exercise combined passive + Shortcut
        // capture. The mode-specific tests above always choose their mode.
        automaticTripStartMode: AutomaticTripStartMode = .both
    ) throws -> Harness {
        let persistence = try persistence ?? PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let activeStore = ActiveDriveStore(context: context)
        let pendingStore = PendingDriveStartSignalStore(context: context)
        if let initialState {
            try activeStore.save(initialState)
        }
        let completionCoordinator = FakeDriveCompletionCoordinator()
        let location = FakeDriveLocationProvider()
        let fallback = FakeFallbackLocationProvider()
        let motion = FakeMotionEvidenceProvider()
        let idleWake = FakeDriveIdleWakeProvider()
        let backgroundWake = FakeDriveBackgroundWakeProvider()
        let background = FakeBackgroundActivitySessionProvider()
        let serviceSession = FakeDriveLocationServiceSessionProvider()
        let healthStatus = FakeDriveCaptureHealthStatusProvider()
        let runtime = DriveCaptureRuntime(
            activeDriveStore: activeStore,
            completionCoordinator: completionCoordinator,
            diagnostics: diagnostics,
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore,
            pendingStartSignalStore: pendingStore,
            routeObservationRequest: routeObservationRequest,
            configuration: configuration,
            locationProvider: location,
            fallbackLocationProvider: fallback,
            motionEvidenceProvider: motion,
            idleWakeProvider: idleWake,
            backgroundWakeProvider: backgroundWake,
            backgroundActivitySessionProvider: background,
            locationServiceSessionProvider: serviceSession,
            healthStatusProvider: healthStatus,
            diagnosticsMode: diagnosticsMode,
            idlePrimingDuration: idlePrimingDuration,
            permissionServiceSessionLease: permissionServiceSessionLease,
            postDriveResumptionGrace: postDriveResumptionGrace,
            trackingRestorationNoticeDelay: trackingRestorationNoticeDelay,
            possibleDriveRecoveryQuietPeriod: possibleDriveRecoveryQuietPeriod,
            completionRetryMinimumInterval: completionRetryMinimumInterval,
            checkpointSaveThrottleInterval: checkpointSaveThrottleInterval,
            automaticTripStartMode: automaticTripStartMode
        )
        return Harness(
            runtime: runtime,
            location: location,
            fallback: fallback,
            motion: motion,
            idleWake: idleWake,
            backgroundWake: backgroundWake,
            background: background,
            serviceSession: serviceSession,
            healthStatus: healthStatus,
            completionCoordinator: completionCoordinator,
            diagnosticSampleStore: diagnosticSampleStore,
            captureEventStore: captureEventStore,
            pendingStore: pendingStore,
            persistence: persistence
        )
    }

    func sample(
        at date: Date,
        metersNorth: Double,
        speed: Double?,
        hint: MotionHint
    ) -> LocationSample {
        LocationSample(
            timestamp: date,
            latitude: 40 + metersNorth / 111_111,
            longitude: -73,
            horizontalAccuracy: 10,
            speedMetersPerSecond: speed,
            motionHint: hint
        )
    }

    func completeOutboundWithPedestrianExit(
        _ harness: Harness,
        start: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let firstWalking = sample(at: start.addingTimeInterval(75), metersNorth: 830, speed: 1.4, hint: .walking)
        harness.location.emit(sample: firstWalking)
        XCTAssertEqual(harness.runtime.state.phase, .recording, file: file, line: line)

        let confirmedWalking = sample(at: start.addingTimeInterval(86), metersNorth: 860, speed: 1.4, hint: .walking)
        harness.location.emit(sample: confirmedWalking)
        XCTAssertEqual(harness.runtime.state.phase, .idle, file: file, line: line)
        XCTAssertEqual(harness.runtime.activityStatus, .idleWake, file: file, line: line)
    }
}

@MainActor
private final class FakeDriveLocationProvider: DriveLocationProvider {
    var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)?
    private(set) var startedConfigurations: [DriveLocationLiveConfiguration] = []
    private(set) var activeConfiguration: DriveLocationLiveConfiguration?
    var isActive: Bool {
        activeConfiguration != nil
    }

    func start(configuration: DriveLocationLiveConfiguration) {
        activeConfiguration = configuration
        startedConfigurations.append(configuration)
    }

    func stop() {
        activeConfiguration = nil
    }

    func emit(sample: LocationSample) {
        onUpdate?(DriveLocationUpdate(sample: sample, receivedAt: sample.timestamp))
    }

    /// Emit a no-sample update carrying `CLLocationUpdate.serviceSessionRequired`,
    /// reproducing the 2026-06-22 stall where Core Location withholds fixes.
    func emitServiceSessionRequired(at date: Date = Date()) {
        onUpdate?(DriveLocationUpdate(
            sample: nil,
            receivedAt: date,
            diagnosticMessages: ["Location service session required"],
            serviceSessionRequired: true
        ))
    }

    /// Mirror the real provider's stream-death contract: the provider clears
    /// its own state first, then delivers exactly one `streamEnded` update.
    func endStream(at date: Date = Date(), serviceSessionRequired: Bool = false) {
        activeConfiguration = nil
        onUpdate?(DriveLocationUpdate(
            sample: nil,
            receivedAt: date,
            diagnosticMessages: ["Location live updates ended after 1s"],
            serviceSessionRequired: serviceSessionRequired,
            streamEnded: true
        ))
    }
}

/// Stand-in for the classic-manager fallback provider; identical contract to
/// `FakeDriveLocationProvider` minus stream-death (the classic path has none).
@MainActor
private final class FakeFallbackLocationProvider: DriveLocationProvider {
    var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)?
    private(set) var startedConfigurations: [DriveLocationLiveConfiguration] = []
    private(set) var stopCount = 0
    private(set) var activeConfiguration: DriveLocationLiveConfiguration?
    var isActive: Bool {
        activeConfiguration != nil
    }

    func start(configuration: DriveLocationLiveConfiguration) {
        guard activeConfiguration != configuration else { return }
        activeConfiguration = configuration
        startedConfigurations.append(configuration)
    }

    func stop() {
        guard activeConfiguration != nil else { return }
        activeConfiguration = nil
        stopCount += 1
    }

    func emit(sample: LocationSample) {
        onUpdate?(DriveLocationUpdate(sample: sample, receivedAt: sample.timestamp))
    }
}

@MainActor
private final class FakeMotionEvidenceProvider: MotionEvidenceProvider {
    var onActivity: (@MainActor (MotionActivitySnapshot) -> Void)?
    private(set) var primeHistoryCount = 0
    private(set) var liveUpdatesStarted = false

    func snapshot(around timestamp: Date) async -> MotionActivitySnapshot? {
        nil
    }

    func primeHistory() {
        primeHistoryCount += 1
    }

    func startLiveUpdates() {
        liveUpdatesStarted = true
        primeHistory()
    }

    func stopLiveUpdates() {
        liveUpdatesStarted = false
    }

    func emit(_ snapshot: MotionActivitySnapshot) {
        onActivity?(snapshot)
    }
}

@MainActor
private final class FakeDriveIdleWakeProvider: DriveIdleWakeProvider {
    var onWake: (@MainActor (Date) -> Void)?
    // Distinct anchors that were configured (deduped, mirroring the real
    // provider's idempotent `startMonitoring`).
    private(set) var monitoredAnchors: [LocationSample] = []
    // Total `startMonitoring` calls, including idempotent re-asserts on
    // unchanged-level wakes — use this to assert re-attachment happened.
    private(set) var ensureCount = 0
    // Region/consumer teardowns — both `stopMonitoring` and `suspendMonitoring`
    // tear the region down, so both count here (existing assertions rely on this).
    private(set) var stopCount = 0
    // Teardowns that PRESERVED the beacon (suspend only).
    private(set) var suspendCount = 0
    // Models the on-disk parking-anchor beacon: written by `startMonitoring`,
    // erased only by `stopMonitoring` (`beacon.clear()`), preserved by
    // `suspendMonitoring`. The real providers couple the beacon exactly this way.
    private(set) var beaconArmed = false
    var isMonitoring: Bool {
        !monitoredAnchors.isEmpty && stopCount == 0
    }

    func startMonitoring(anchor: LocationSample) {
        stopCount = 0
        ensureCount += 1
        beaconArmed = true
        if monitoredAnchors.last != anchor {
            monitoredAnchors.append(anchor)
        }
    }

    func stopMonitoring() {
        stopCount += 1
        beaconArmed = false
    }

    func suspendMonitoring() {
        stopCount += 1
        suspendCount += 1
        // Beacon intentionally preserved — see the real providers' split.
    }

    func emitWake(at date: Date) {
        onWake?(date)
    }
}

@MainActor
private final class FakeDriveBackgroundWakeProvider: DriveBackgroundWakeProvider {
    var onSignificantChange: (@MainActor (Date, LocationSample?) -> Void)?
    var onVisitDeparture: (@MainActor (Date) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var forceRearmCount = 0
    private var monitoring = false
    var isMonitoring: Bool { monitoring }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        startCount += 1
    }

    func forceRearm() {
        monitoring = true
        forceRearmCount += 1
    }

    func stopMonitoring() {
        monitoring = false
        stopCount += 1
    }

    func emitSignificantChange(at date: Date, sample: LocationSample? = nil) {
        onSignificantChange?(date, sample)
    }

    func emitVisitDeparture(at date: Date) {
        onVisitDeparture?(date)
    }
}

@MainActor
private final class FakeDriveLocationServiceSessionProvider: DriveLocationServiceSessionProvider {
    private(set) var isActive = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var purposeKeys: [String] = []
    var onDiagnostic: (@MainActor (DriveServiceSessionDiagnostic) -> Void)?

    func startAlways(fullAccuracyPurposeKey: String) {
        guard !isActive else { return }
        isActive = true
        startCount += 1
        purposeKeys.append(fullAccuracyPurposeKey)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        stopCount += 1
    }

    func emitDiagnostic(_ diagnostic: DriveServiceSessionDiagnostic) {
        onDiagnostic?(diagnostic)
    }
}

@MainActor
private final class FakeDriveCaptureHealthStatusProvider: DriveCaptureHealthStatusProvider {
    var alwaysLocationAuthorized = true
    var preciseLocationEnabled = true
    var motionAuthorized = true
    var backgroundRefreshAvailable = true
}

@MainActor
private final class FakeBackgroundActivitySessionProvider: DriveBackgroundActivitySessionProvider {
    private(set) var isActive = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    // Mirror the real provider: `start()` is a no-op while a session object
    // exists, `stop()` while none does — count only genuine transitions.
    func start() {
        guard !isActive else { return }
        isActive = true
        startCount += 1
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        stopCount += 1
    }
}

private enum RuntimePolicyTestError: Error {
    case completionRefused
}

private final class FakeDriveCompletionCoordinator: DriveCompletionCoordinating {
    private(set) var completedDrafts: [TripDraft] = []
    private(set) var clearedStates: [DriveCaptureState] = []
    var shouldDiscard = false
    /// When set, `complete` records the attempt and throws — the persistently
    /// failing completion the runtime's retry throttle must bound.
    var completeError: Error?
    var overlappingTripExists = false
    private(set) var overlapQueries: [(start: Date, end: Date, excluding: UUID)] = []

    func hasTripOverlapping(start: Date, end: Date, excluding excludedID: UUID) throws -> Bool {
        overlapQueries.append((start, end, excludedID))
        return overlappingTripExists
    }

    func complete(_ draft: TripDraft, monitoringSessionID: UUID?) throws -> DriveCompletionOutcome {
        completedDrafts.append(draft)
        if let completeError {
            throw completeError
        }
        if shouldDiscard {
            return .discardedAutomaticCapture(source: .autoTransit, reason: "Transit test capture")
        }
        return .saved(DriveCompletionResult(
            trip: TripSummary(
                id: draft.id,
                createdAt: Date(),
                updatedAt: Date(),
                captureSource: "automatic",
                startDate: draft.startDate,
                endDate: draft.endDate,
                startCoordinate: draft.samples.first.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                endCoordinate: draft.samples.last.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                startAddress: nil,
                endAddress: nil,
                distanceMeters: draft.distanceMeters,
                routePolyline: nil,
                classification: nil,
                reviewStatus: .needsReview,
                businessPurpose: nil,
                notes: nil,
                tollsAmount: 0,
                parkingAmount: 0,
                needsAttention: !draft.attentionReasons.isEmpty,
                attentionReasons: draft.attentionReasons,
                manualDistanceOverrideMeters: nil
            ),
            samples: draft.samples,
            conflictingVehicleIDs: draft.conflictingVehicleIDs
        ))
    }

    func clearActiveStateIfIdle(_ state: DriveCaptureState) throws {
        clearedStates.append(state)
    }
}
