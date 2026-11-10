import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(MapKit)
import MapKit
#endif

#if os(iOS)
import CoreMotion
import UIKit

public struct DriveLocationUpdate: Sendable {
    public var sample: LocationSample?
    public var receivedAt: Date
    public var stationary: Bool
    public var diagnosticMessages: [String]
    /// Core Location reported `CLLocationUpdate.serviceSessionRequired`: it will
    /// not deliver fixes until a satisfying `CLServiceSession` exists. Threaded
    /// as a structured flag (not just a diagnostic string) so the runtime can
    /// detect the stall and attempt a bounded recovery.
    public var serviceSessionRequired: Bool
    /// The `liveUpdates` stream this update came from has ENDED (returned or
    /// threw). Delivered exactly once per stream death so the runtime can
    /// restart the stream — without this, a dead stream is indistinguishable
    /// from a quiet one until the next movement-proving wake.
    public var streamEnded: Bool

    public init(
        sample: LocationSample?,
        receivedAt: Date = Date(),
        stationary: Bool = false,
        diagnosticMessages: [String] = [],
        serviceSessionRequired: Bool = false,
        streamEnded: Bool = false
    ) {
        self.sample = sample
        self.receivedAt = receivedAt
        self.stationary = stationary
        self.diagnosticMessages = diagnosticMessages
        self.serviceSessionRequired = serviceSessionRequired
        self.streamEnded = streamEnded
    }
}

@MainActor
public protocol DriveLocationProvider: AnyObject {
    var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)? { get set }
    var isActive: Bool { get }
    func start(configuration: DriveLocationLiveConfiguration)
    func stop()
}

public enum DriveLocationLiveConfiguration: Equatable, Sendable {
    case `default`
    case automotiveNavigation
}

@MainActor
public protocol MotionEvidenceProvider: AnyObject {
    var onActivity: (@MainActor (MotionActivitySnapshot) -> Void)? { get set }
    func snapshot(around timestamp: Date) async -> MotionActivitySnapshot?
    func primeHistory()
    func startLiveUpdates()
    func stopLiveUpdates()
}

@MainActor
public protocol DriveIdleWakeProvider: AnyObject {
    var onWake: (@MainActor (Date) -> Void)? { get set }
    var isMonitoring: Bool { get }
    /// Whether a task is currently awaiting geofence events. May be false even
    /// when `isMonitoring` is true if the events stream ended on a lifecycle
    /// change and has not been re-attached.
    var isConsumingEvents: Bool { get }
    /// Idempotent: ensures monitoring is attached at this anchor. Safe to call on
    /// every policy apply / wake.
    func startMonitoring(anchor: LocationSample)
    func stopMonitoring()
    /// Tear down active region/consumer monitoring but PRESERVE the non-secure
    /// beacon, so a cold relaunch can still re-arm the geofence from the last
    /// parked anchor. Use while the parked anchor is still authoritative (a live
    /// candidate, or the high-fidelity window right after a wake), where clearing
    /// the beacon would strand a suspended/terminated app with no wake anchor.
    /// Default: clears, identical to `stopMonitoring()`.
    func suspendMonitoring()
    /// Drop this instance's in-memory consumer state but PRESERVE both the
    /// beacon and the system-side region registration, so another provider
    /// instance (the runtime's, after a protected-data wake keeper hands off)
    /// can adopt the persisted registration without a churning re-register.
    /// Default: `suspendMonitoring()` (safe for providers with no system-side
    /// registration to preserve).
    func detachMonitoring()
    /// Re-attaches the geofence consumer on a cold relaunch (before the encrypted
    /// stores can be opened) or after the events stream ended. Default: no-op
    /// reporting `.notNeeded`.
    @discardableResult
    func restoreMonitoringIfNeeded() -> DriveIdleWakeRestoreOutcome
    /// Foreground-only integrity check: re-registers the expected system
    /// registration if it went missing (returns true), otherwise issues a
    /// single state reconciliation so a force-quit/missed exit is caught while
    /// the location indicator is unobjectionable (returns false). Default: no-op
    /// returning false.
    @discardableResult
    func verifyOrRearmSystemRegistrationOnForeground() -> Bool
}

/// What `restoreMonitoringIfNeeded()` actually did — lets the runtime journal
/// adopted-vs-rearmed distinctly (the 2026-07-07 stuck-arrow investigation had
/// one indistinguishable "restored from beacon" row per relaunch).
public enum DriveIdleWakeRestoreOutcome: Equatable, Sendable {
    /// Anchor already attached in memory (warm bootstrap) or nothing to restore.
    case notNeeded
    /// A matching system-side region registration persisted across the process
    /// death and was adopted with zero Core Location calls.
    case adopted
    /// No (matching) system registration existed: fully re-registered, including
    /// the `requestState` already-outside catch-up.
    case rearmed
    /// A system region existed with no beacon backing it — removed, because a
    /// stale orphan fence can relaunch the app indefinitely.
    case cleanedUpOrphan
}

public extension DriveIdleWakeProvider {
    var isConsumingEvents: Bool { isMonitoring }
    func suspendMonitoring() { stopMonitoring() }
    func detachMonitoring() { suspendMonitoring() }
    @discardableResult
    func restoreMonitoringIfNeeded() -> DriveIdleWakeRestoreOutcome { .notNeeded }
    @discardableResult
    func verifyOrRearmSystemRegistrationOnForeground() -> Bool { false }
}

/// Always-on, low-power Tier-0 relaunch backbone independent of the parked-anchor
/// geofence: significant-location-change + visit monitoring. Both can cold-launch
/// the app (incl. while locked) under the existing `location` background mode +
/// `.always` authorization, so a parked/idle phone still wakes to evaluate a drive
/// even when the geofence-exit wake does not fire.
@MainActor
public protocol DriveBackgroundWakeProvider: AnyObject {
    /// Fired when a significant location change is delivered (≈ moved 500 m / cell
    /// handoff). The date is the time the wake was observed. The sample is the
    /// SLC-delivered fix (nil if none came with the event) — used only to gate the
    /// wake against the parked anchor; it never feeds trip detection.
    var onSignificantChange: (@MainActor (Date, LocationSample?) -> Void)? { get set }
    /// Fired only for visit *departures* (`CLVisit.departureDate != .distantFuture`).
    /// The date is the departure time.
    var onVisitDeparture: (@MainActor (Date) -> Void)? { get set }
    var isMonitoring: Bool { get }
    /// Idempotent: arms SLC + visit monitoring. Safe to call on every wake/bootstrap.
    /// Deliberately re-calls Core Location once per process even though the
    /// registrations persist — per the documented contract, a relaunched process
    /// must call the start methods again or the triggering event is never
    /// delivered to its delegate (skipping this is a missed-drive bug, not an
    /// optimization; see ADR-005).
    func startMonitoring()
    /// Idempotent: must also clear registrations that Core Location may have
    /// persisted across a prior process lifetime.
    func stopMonitoring()
    /// Unconditionally re-asserts the SLC + visit registrations, bypassing the
    /// in-process idempotency guard. Foreground self-heal for registrations the
    /// system silently dropped (Location Services toggle, etc.). Default:
    /// `startMonitoring()`.
    func forceRearm()
}

public extension DriveBackgroundWakeProvider {
    func forceRearm() { startMonitoring() }
}

@MainActor
public protocol DriveBackgroundActivitySessionProvider: AnyObject {
    var isActive: Bool { get }
    func start()
    func stop()
}

/// Snapshot of `CLServiceSession.Diagnostic` — the direct, push-delivered
/// signal that Core Location is (or is not) honoring the held session. Before
/// this was consumed, an unhonored session could only be inferred from
/// `serviceSessionRequired` flags on location updates that may never arrive.
/// Payload for `onTrackingRestorationNeeded`: an unfulfilled session has
/// produced no samples for the notice delay while strong drive evidence is
/// active. Fallback metrics are informational — the notice pipeline works
/// whether or not the classic-manager fallback is present or delivering.
public struct DriveTrackingRestorationAdvice: Equatable, Sendable {
    public var diagnosticSummary: String
    public var phase: DriveCapturePhase
    public var quietForSeconds: Int
    public var fallbackEngaged: Bool
    public var fallbackSampleCount: Int

    public init(
        diagnosticSummary: String,
        phase: DriveCapturePhase,
        quietForSeconds: Int,
        fallbackEngaged: Bool = false,
        fallbackSampleCount: Int = 0
    ) {
        self.diagnosticSummary = diagnosticSummary
        self.phase = phase
        self.quietForSeconds = quietForSeconds
        self.fallbackEngaged = fallbackEngaged
        self.fallbackSampleCount = fallbackSampleCount
    }
}

public struct DriveServiceSessionDiagnostic: Equatable, Sendable {
    public var insufficientlyInUse: Bool
    public var serviceSessionRequired: Bool
    public var authorizationDenied: Bool
    public var authorizationDeniedGlobally: Bool
    public var authorizationRestricted: Bool
    public var fullAccuracyDenied: Bool
    public var alwaysAuthorizationDenied: Bool
    public var authorizationRequestInProgress: Bool

    public init(
        insufficientlyInUse: Bool = false,
        serviceSessionRequired: Bool = false,
        authorizationDenied: Bool = false,
        authorizationDeniedGlobally: Bool = false,
        authorizationRestricted: Bool = false,
        fullAccuracyDenied: Bool = false,
        alwaysAuthorizationDenied: Bool = false,
        authorizationRequestInProgress: Bool = false
    ) {
        self.insufficientlyInUse = insufficientlyInUse
        self.serviceSessionRequired = serviceSessionRequired
        self.authorizationDenied = authorizationDenied
        self.authorizationDeniedGlobally = authorizationDeniedGlobally
        self.authorizationRestricted = authorizationRestricted
        self.fullAccuracyDenied = fullAccuracyDenied
        self.alwaysAuthorizationDenied = alwaysAuthorizationDenied
        self.authorizationRequestInProgress = authorizationRequestInProgress
    }

    /// The session exists but is not authorizing background delivery — the
    /// post-restart "insufficiently in use" state, or an unmet explicit-session
    /// requirement. Authorization-denial states are surfaced separately by the
    /// health checks and excluded here.
    public var isUnfulfilled: Bool {
        insufficientlyInUse || serviceSessionRequired
    }

    public var summary: String {
        [
            insufficientlyInUse ? "insufficientlyInUse" : nil,
            serviceSessionRequired ? "serviceSessionRequired" : nil,
            authorizationDenied ? "authorizationDenied" : nil,
            authorizationDeniedGlobally ? "authorizationDeniedGlobally" : nil,
            authorizationRestricted ? "authorizationRestricted" : nil,
            fullAccuracyDenied ? "fullAccuracyDenied" : nil,
            alwaysAuthorizationDenied ? "alwaysAuthorizationDenied" : nil,
            authorizationRequestInProgress ? "authorizationRequestInProgress" : nil
        ].compactMap { $0 }.joined(separator: ",").ifEmpty("clear")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

@MainActor
public protocol DriveLocationServiceSessionProvider: AnyObject {
    var isActive: Bool { get }
    var onDiagnostic: (@MainActor (DriveServiceSessionDiagnostic) -> Void)? { get set }
    func startAlways(fullAccuracyPurposeKey: String)
    func stop()
}

@MainActor
public protocol DriveCaptureHealthStatusProvider: AnyObject {
    var alwaysLocationAuthorized: Bool { get }
    var preciseLocationEnabled: Bool { get }
    var motionAuthorized: Bool { get }
    var backgroundRefreshAvailable: Bool { get }
}

@MainActor
public final class SystemMotionEvidenceProvider: MotionEvidenceProvider {
    public var onActivity: (@MainActor (MotionActivitySnapshot) -> Void)?

    private let motionManager = CMMotionActivityManager()
    private var recentMotionActivities: [MotionActivitySnapshot] = []
    private var activityUpdatesStarted = false

    public init() {}

    public func primeHistory() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let end = Date()
        motionManager.queryActivityStarting(from: end.addingTimeInterval(-10 * 60), to: end, to: .main) { [weak self] activities, _ in
            Task { @MainActor in
                activities?.map(Self.motionSnapshot(from:)).forEach { self?.append($0) }
            }
        }
    }

    public func startLiveUpdates() {
        primeHistory()
        guard CMMotionActivityManager.isActivityAvailable(),
              !activityUpdatesStarted else { return }
        activityUpdatesStarted = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in
                let snapshot = Self.motionSnapshot(from: activity)
                self?.append(snapshot)
                self?.onActivity?(snapshot)
            }
        }
    }

    public func stopLiveUpdates() {
        motionManager.stopActivityUpdates()
        activityUpdatesStarted = false
    }

    public func snapshot(around timestamp: Date) async -> MotionActivitySnapshot? {
        if let cached = recentMotionActivities
            .filter({ abs($0.startDate.timeIntervalSince(timestamp)) <= 10 * 60 })
            .sorted(by: { abs($0.startDate.timeIntervalSince(timestamp)) < abs($1.startDate.timeIntervalSince(timestamp)) })
            .first {
            return cached
        }

        guard CMMotionActivityManager.isActivityAvailable() else {
            return nil
        }
        let start = timestamp.addingTimeInterval(-90)
        let end = timestamp.addingTimeInterval(5)
        return await withCheckedContinuation { continuation in
            motionManager.queryActivityStarting(from: start, to: end, to: .main) { [weak self] activities, _ in
                let snapshots = activities?.map(Self.motionSnapshot(from:)) ?? []
                Task { @MainActor in
                    snapshots.forEach { self?.append($0) }
                    continuation.resume(returning: snapshots.sorted {
                        abs($0.startDate.timeIntervalSince(timestamp)) < abs($1.startDate.timeIntervalSince(timestamp))
                    }.first)
                }
            }
        }
    }

    private func append(_ snapshot: MotionActivitySnapshot) {
        recentMotionActivities.append(snapshot)
        let cutoff = Date().addingTimeInterval(-10 * 60)
        recentMotionActivities.removeAll { $0.startDate < cutoff }
    }

    private static func motionSnapshot(from activity: CMMotionActivity) -> MotionActivitySnapshot {
        var hints: [MotionHint] = []
        if activity.automotive { hints.append(.automotive) }
        if activity.stationary { hints.append(.stationary) }
        if activity.walking { hints.append(.walking) }
        if activity.running { hints.append(.running) }
        if activity.cycling { hints.append(.cycling) }
        if hints.isEmpty || activity.unknown { hints.append(.unknown) }
        return MotionActivitySnapshot(
            startDate: activity.startDate,
            confidence: motionConfidence(from: activity.confidence),
            hints: hints
        )
    }

    private static func motionConfidence(from confidence: CMMotionActivityConfidence) -> MotionConfidence {
        switch confidence {
        case .low:
            .low
        case .medium:
            .medium
        case .high:
            .high
        @unknown default:
            .unknown
        }
    }
}

/// Shared CLLocation → LocationSample mapping so the primary (`liveUpdates`)
/// and fallback (classic delegate) providers produce identical samples.
enum DriveLocationSampleMapper {
    static func sample(from location: CLLocation, motionActivity: MotionActivitySnapshot?) -> LocationSample {
        LocationSample(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            speedAccuracyMetersPerSecond: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
            courseDegrees: location.course >= 0 ? location.course : nil,
            motionHint: motionActivity.map(primaryMotionHint(from:)) ?? .unknown,
            motionActivity: motionActivity
        )
    }

    static func primaryMotionHint(from snapshot: MotionActivitySnapshot) -> MotionHint {
        for hint in [MotionHint.automotive, .walking, .running, .cycling, .stationary, .unknown] where snapshot.contains(hint) {
            return hint
        }
        return .unknown
    }
}

@MainActor
public final class CoreLocationDriveLocationProvider: DriveLocationProvider {
    public var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)?

    private let motionEvidenceProvider: any MotionEvidenceProvider
    private var updatesTask: Task<Void, Never>?
    private var activeConfiguration: DriveLocationLiveConfiguration?
    /// Bumped on every start/stop so a stream task that ends late — after being
    /// replaced or deliberately stopped — can tell it is stale and stay silent
    /// instead of clobbering the replacement or reporting a spurious death.
    private var streamGeneration = 0

    public var isActive: Bool {
        activeConfiguration != nil
    }

    public init(motionEvidenceProvider: any MotionEvidenceProvider) {
        self.motionEvidenceProvider = motionEvidenceProvider
    }

    public func start(configuration: DriveLocationLiveConfiguration) {
        guard activeConfiguration != configuration else { return }
        stop()
        activeConfiguration = configuration
        streamGeneration += 1
        let generation = streamGeneration
        let startedAt = Date()
        updatesTask = Task { [weak self] in
            var endError: Error?
            var sawServiceSessionRequired = false
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration.liveConfiguration) {
                    guard let self else { return }
                    let receivedAt = Date()
                    let messages = Self.diagnosticMessages(from: update)
                    if update.serviceSessionRequired {
                        sawServiceSessionRequired = true
                    }
                    if let location = update.location {
                        let activity = await motionEvidenceProvider.snapshot(around: location.timestamp)
                        let sample = DriveLocationSampleMapper.sample(from: location, motionActivity: activity)
                        await MainActor.run {
                            self.onUpdate?(DriveLocationUpdate(
                                sample: sample,
                                receivedAt: receivedAt,
                                stationary: update.stationary,
                                diagnosticMessages: messages,
                                serviceSessionRequired: update.serviceSessionRequired
                            ))
                        }
                    } else {
                        await MainActor.run {
                            self.onUpdate?(DriveLocationUpdate(
                                sample: nil,
                                receivedAt: receivedAt,
                                stationary: update.stationary,
                                diagnosticMessages: messages,
                                serviceSessionRequired: update.serviceSessionRequired
                            ))
                        }
                    }
                }
            } catch {
                endError = error
            }
            // The stream ended — normally or by throwing. Report it (once, and
            // only if this task is still the current stream) so the runtime can
            // restart; otherwise `isActive` lies forever and a same-configuration
            // `start()` is a no-op, leaving a dead stream that looks alive.
            guard let self else { return }
            await MainActor.run {
                self.streamDidEnd(
                    generation: generation,
                    startedAt: startedAt,
                    error: endError,
                    sawServiceSessionRequired: sawServiceSessionRequired
                )
            }
        }
    }

    public func stop() {
        streamGeneration += 1
        updatesTask?.cancel()
        updatesTask = nil
        activeConfiguration = nil
    }

    private func streamDidEnd(
        generation: Int,
        startedAt: Date,
        error: Error?,
        sawServiceSessionRequired: Bool
    ) {
        guard generation == streamGeneration else { return }
        activeConfiguration = nil
        updatesTask = nil
        let duration = Int(max(0, Date().timeIntervalSince(startedAt)))
        let message = error.map { "Location live updates failed after \(duration)s: \($0.localizedDescription)" }
            ?? "Location live updates ended after \(duration)s"
        onUpdate?(DriveLocationUpdate(
            sample: nil,
            receivedAt: Date(),
            stationary: false,
            diagnosticMessages: [message],
            serviceSessionRequired: sawServiceSessionRequired,
            streamEnded: true
        ))
    }

    private static func diagnosticMessages(from update: CLLocationUpdate) -> [String] {
        [
            update.authorizationDenied ? "Location authorization denied" : nil,
            update.authorizationDeniedGlobally ? "Location Services disabled" : nil,
            update.authorizationRestricted ? "Location authorization restricted" : nil,
            update.insufficientlyInUse ? "Location updates suspended: app insufficiently in use" : nil,
            update.locationUnavailable ? "Location unavailable" : nil,
            update.accuracyLimited ? "Location accuracy limited" : nil,
            update.serviceSessionRequired ? "Location service session required" : nil,
            update.authorizationRequestInProgress ? "Location authorization request in progress" : nil
        ].compactMap { $0 }
    }
}

/// Classic-delegate continuous-updates fallback for the state where every
/// `CLServiceSession` created from a background context is refused
/// (`insufficientlyInUse`, 2026-07-05 incident) and `liveUpdates` therefore
/// delivers nothing for an entire drive. Classic delivery with Always
/// authorization does not depend on holding an honored service session
/// (CLLocationManager.h: permitted "whenever the application is running …
/// or it has Always authorization") — though the CLRequireExplicitServiceSession
/// Info.plist key can still gate it; see ADR-004 for the on-device verdict.
@MainActor
public final class CoreLocationManagerDriveLocationProvider: NSObject, DriveLocationProvider {
    public var onUpdate: (@MainActor (DriveLocationUpdate) -> Void)?

    private let motionEvidenceProvider: any MotionEvidenceProvider
    private var manager: CLLocationManager?
    private var activeConfiguration: DriveLocationLiveConfiguration?
    /// Bumped on every start/stop so delegate hops that land after a stop (or
    /// after a replacement start) can tell they are stale and stay silent.
    private var generation = 0

    public var isActive: Bool {
        activeConfiguration != nil
    }

    public init(motionEvidenceProvider: any MotionEvidenceProvider) {
        self.motionEvidenceProvider = motionEvidenceProvider
    }

    public func start(configuration: DriveLocationLiveConfiguration) {
        guard activeConfiguration != configuration else { return }
        stop()
        activeConfiguration = configuration
        generation += 1
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = configuration == .automotiveNavigation ? .automotiveNavigation : .other
        manager.pausesLocationUpdatesAutomatically = false
        // Legal because UIBackgroundModes includes "location"; setting it
        // without the background mode is a documented fatal error.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        self.manager = manager
        manager.startUpdatingLocation()
    }

    public func stop() {
        generation += 1
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        activeConfiguration = nil
    }

    private func deliver(locations: [CLLocation], generation: Int) async {
        for location in locations {
            guard generation == self.generation else { return }
            let activity = await motionEvidenceProvider.snapshot(around: location.timestamp)
            guard generation == self.generation else { return }
            let sample = DriveLocationSampleMapper.sample(from: location, motionActivity: activity)
            onUpdate?(DriveLocationUpdate(sample: sample, receivedAt: Date()))
        }
    }
}

extension CoreLocationManagerDriveLocationProvider: CLLocationManagerDelegate {
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.deliver(locations: locations, generation: self.generation)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Transient kCLErrorLocationUnknown means "keep waiting"; report other
        // failures as a no-sample diagnostic update. Never `streamEnded` — that
        // flag drives the PRIMARY stream's restart accounting.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        let message = "Fallback location failed: \(error.localizedDescription)"
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            self.onUpdate?(DriveLocationUpdate(sample: nil, diagnosticMessages: [message]))
        }
    }
}

/// Parked-anchor geofence built on **classic** `CLLocationManager` region monitoring
/// (`startMonitoring(for:)` + `didExitRegion`). This is the default idle-wake provider,
/// superseding an earlier `CLMonitor`-based provider (since removed).
///
/// Why classic over `CLMonitor`: a parked phone is suspended with no active
/// `CLServiceSession` (the capture policy stops it during `.idleAnchored` to save
/// battery). `CLMonitor` needs an active/foreground-restored session to deliver in the
/// background-after-not-in-use case, so its exits never fire on a parked device — this
/// matches `idleWake = 0` across the on-device pulls. Classic region monitoring delivers
/// background exits and relaunches a suspended/system-terminated app under `.always` +
/// the `location` background mode with **no** session, at near-zero idle battery cost, and
/// its registration persists across termination (`monitoredRegions`) so there is no
/// fragile events-stream re-await and no `CLMonitor` "already in use" crash.
///
/// Limits (documented for callers): a deliberate user force-quit does not reliably relaunch;
/// region monitoring is disabled entirely under Reduced Accuracy (gated upstream in
/// `applyCapturePolicy`); and exits carry the system's ~3–5 min average cadence plus the
/// anti-flapping hysteresis (~200 m past the boundary), so the effective trigger distance
/// for a 250 m radius is ~450 m from the parked center.
@MainActor
public final class CoreLocationRegionDriveIdleWakeProvider: NSObject, CLLocationManagerDelegate, DriveIdleWakeProvider {
    public var onWake: (@MainActor (Date) -> Void)?

    private nonisolated static let regionIdentifier = "MileageTrackerParkedAnchor"

    private let radiusMeters: CLLocationDistance
    private let beacon: ParkingAnchorBeaconStoring
    private let manager: CLLocationManager
    private let systemRegionRegistrationEnabled: Bool
    private let reconcileStateOnRegistration: Bool
    private var monitoredAnchor: LocationSample?

    public init(
        radiusMeters: CLLocationDistance = DriveStartPolicy.balanced.parkedAnchorRadiusMeters,
        beacon: ParkingAnchorBeaconStoring = ParkingAnchorBeacon(),
        locationManager: CLLocationManager? = nil,
        systemRegionRegistrationEnabled: Bool = true,
        reconcileStateOnRegistration: Bool = true
    ) {
        self.radiusMeters = radiusMeters
        self.beacon = beacon
        self.manager = locationManager ?? CLLocationManager()
        self.systemRegionRegistrationEnabled = systemRegionRegistrationEnabled
        self.reconcileStateOnRegistration = reconcileStateOnRegistration
        super.init()
        manager.delegate = self
    }

    public var isMonitoring: Bool { monitoredAnchor != nil }

    /// Idempotent. Re-registers the region only when the anchor changes; classic region
    /// registrations persist across lifecycle changes, so (unlike `CLMonitor`) there is no
    /// per-apply consumer to re-attach. Safe to call on every policy apply / wake.
    public func startMonitoring(anchor: LocationSample) {
        let anchorChanged = monitoredAnchor?.matchesIdleWakeAnchor(anchor) != true
        monitoredAnchor = anchor
        guard anchorChanged else { return }
        // Persist a single non-secure copy so the region can be re-registered on a cold
        // relaunch (even while locked) without opening the encrypted stores. Erased in
        // `stopMonitoring`.
        beacon.save(anchor: anchor, radius: radiusMeters)
        registerRegion(latitude: anchor.latitude, longitude: anchor.longitude, radius: radiusMeters)
    }

    /// Adopt-or-register on a cold relaunch (before the encrypted stores can be
    /// opened). Classic region registrations persist system-side across process
    /// death and deliver exits to any fresh manager+delegate WITHOUT being
    /// re-added — so when the persisted region still matches the beacon, adopt
    /// it with zero Core Location calls. Re-registering here on every relaunch
    /// (the pre-ADR-005 behavior) forced a `requestState` location
    /// determination per wake and invited fresh state callbacks, feeding the
    /// 2026-07-07 parked wake-churn loop that kept the location arrow lit.
    /// Every ambiguous case falls through to a full re-register — missing or
    /// changed registrations must always re-arm (ADR-001).
    @discardableResult
    public func restoreMonitoringIfNeeded() -> DriveIdleWakeRestoreOutcome {
        guard monitoredAnchor == nil else { return .notNeeded }
        guard let stored = beacon.load() else {
            // A system region with no beacon behind it is an orphan from a
            // cleared/failed teardown: it can relaunch the app indefinitely
            // while `fireWake` no-ops on the nil anchor. Remove it.
            guard systemRegionRegistrationEnabled, hasRegisteredParkedAnchorRegion else {
                return .notNeeded
            }
            removeRegions()
            return .cleanedUpOrphan
        }
        monitoredAnchor = stored.anchorSample
        if systemRegionRegistrationEnabled,
           persistedRegionMatches(latitude: stored.latitude, longitude: stored.longitude, radius: stored.radius) {
            return .adopted
        }
        registerRegion(latitude: stored.latitude, longitude: stored.longitude, radius: stored.radius)
        return .rearmed
    }

    /// Foreground integrity check: if the expected registration vanished
    /// (Location Services toggled, system reset), re-register it — otherwise
    /// issue one `requestState` so a missed exit (e.g. force-quit while
    /// driving away) is reconciled while the app is open, where a location
    /// determination is unobjectionable. The adopt path deliberately skips
    /// `requestState`; this is where that catch-up lives instead.
    @discardableResult
    public func verifyOrRearmSystemRegistrationOnForeground() -> Bool {
        guard systemRegionRegistrationEnabled, let anchor = monitoredAnchor else { return false }
        guard persistedRegionMatches(
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            radius: radiusMeters
        ) else {
            registerRegion(latitude: anchor.latitude, longitude: anchor.longitude, radius: radiusMeters)
            return true
        }
        if let region = registeredParkedAnchorRegion {
            manager.requestState(for: region)
        }
        return false
    }

    public func stopMonitoring() {
        suspendMonitoring()
        beacon.clear()
    }

    public func suspendMonitoring() {
        monitoredAnchor = nil
        removeRegions()
    }

    /// Keeper handoff: drop in-memory state only. The beacon AND the persisted
    /// system region survive so the successor provider adopts instead of
    /// re-registering (see `restoreMonitoringIfNeeded`).
    public func detachMonitoring() {
        onWake = nil
        monitoredAnchor = nil
    }

    private var registeredParkedAnchorRegion: CLCircularRegion? {
        manager.monitoredRegions
            .compactMap { $0 as? CLCircularRegion }
            .first { $0.identifier == Self.regionIdentifier }
    }

    private var hasRegisteredParkedAnchorRegion: Bool {
        registeredParkedAnchorRegion != nil
    }

    /// ≈0.11 m of latitude — far tighter than GPS accuracy, loose enough to
    /// absorb any float round-trip through locationd.
    private nonisolated static let adoptionCoordinateEpsilonDegrees = 1e-6
    private nonisolated static let adoptionRadiusEpsilonMeters: CLLocationDistance = 1.0

    private func persistedRegionMatches(
        latitude: Double,
        longitude: Double,
        radius: CLLocationDistance
    ) -> Bool {
        guard let region = registeredParkedAnchorRegion else { return false }
        return abs(region.center.latitude - latitude) <= Self.adoptionCoordinateEpsilonDegrees
            && abs(region.center.longitude - longitude) <= Self.adoptionCoordinateEpsilonDegrees
            && abs(region.radius - radius) <= Self.adoptionRadiusEpsilonMeters
    }

    private func registerRegion(latitude: Double, longitude: Double, radius: CLLocationDistance) {
        guard systemRegionRegistrationEnabled else { return }
        // Tear down any prior copy first so we never leak against the per-app 20-region budget.
        removeRegions()
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radius: radius,
            identifier: Self.regionIdentifier
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        // A region fires no exit if we are already inside it at registration. Reconcile the
        // current state so a cold relaunch that lands already-outside the fence still wakes.
        if reconcileStateOnRegistration {
            manager.requestState(for: region)
        }
    }

    private func removeRegions() {
        for region in manager.monitoredRegions where region.identifier == Self.regionIdentifier {
            manager.stopMonitoring(for: region)
        }
    }

    private func fireWake() {
        guard monitoredAnchor != nil else { return }
        onWake?(Date())
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionIdentifier else { return }
        Task { @MainActor [weak self] in self?.fireWake() }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        // Only the registration-time reconciliation: an already-outside state is a missed
        // exit. Real exits arrive via `didExitRegion`, so this never double-fires in steady state.
        guard region.identifier == Self.regionIdentifier, state == .outside else { return }
        Task { @MainActor [weak self] in self?.fireWake() }
    }
}

@MainActor
public final class CoreLocationBackgroundWakeProvider: NSObject, CLLocationManagerDelegate, DriveBackgroundWakeProvider {
    public var onSignificantChange: (@MainActor (Date, LocationSample?) -> Void)?
    public var onVisitDeparture: (@MainActor (Date) -> Void)?

    private let manager: CLLocationManager
    private var monitoring = false

    public init(locationManager: CLLocationManager? = nil) {
        manager = locationManager ?? CLLocationManager()
        super.init()
        manager.delegate = self
        // SLC + visits deliver in the background (incl. terminated/locked) purely
        // under `.always` authorization — they never raise accuracy or keep the
        // location hardware on, so no full-accuracy purpose key or
        // `allowsBackgroundLocationUpdates` (which only affects standard continuous
        // updates) is needed here.
    }

    public var isMonitoring: Bool { monitoring }

    /// Once-per-process by design, NOT once-per-registration: SLC/visit
    /// registrations persist system-side, but per the documented contract a
    /// relaunched process must call the start methods again or the triggering
    /// event is never delivered to this delegate. The immediate stale
    /// redelivery this causes is neutralized upstream (stale-event gate,
    /// parked-anchor gate); skipping the call would be a missed-drive bug on
    /// devices whose only wake source is SLC/visits (ADR-005).
    public func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
    }

    /// Foreground self-heal: bypasses the in-process guard to re-assert
    /// registrations the system may have silently dropped (Location Services
    /// toggle, permission churn). Redundant re-asserts are harmless here — the
    /// app is open, where a redelivery neither wakes anything nor lights an
    /// unexpected indicator.
    public func forceRearm() {
        monitoring = true
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
    }

    public func stopMonitoring() {
        monitoring = false
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
    }

    // CLLocationManagerDelegate methods are nonisolated; hop back to the main actor
    // to fire the callbacks the runtime consumes.
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Carry the delivered fix so the runtime can tell a still-parked wake
        // (fix inside the anchor fence) from a genuine movement wake. A freshly
        // (re)armed SLC subscription delivers the current location immediately,
        // so on relaunch churn this fix is the proof the phone never moved.
        let sample = locations.last.map { DriveLocationSampleMapper.sample(from: $0, motionActivity: nil) }
        let date = locations.last?.timestamp ?? Date()
        Task { @MainActor [weak self] in
            self?.onSignificantChange?(date, sample)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        // A visit with a real departure date means the user just left a place.
        // Arrivals (departureDate == .distantFuture) are ignored here.
        guard visit.departureDate != Date.distantFuture else { return }
        let date = visit.departureDate
        Task { @MainActor [weak self] in
            self?.onVisitDeparture?(date)
        }
    }
}

public final class CoreLocationBackgroundActivitySessionProvider: DriveBackgroundActivitySessionProvider {
    private var session: CLBackgroundActivitySession?

    public var isActive: Bool {
        session != nil
    }

    public init() {}

    public func start() {
        guard session == nil else { return }
        session = CLBackgroundActivitySession()
    }

    public func stop() {
        session?.invalidate()
        session = nil
    }
}

public final class CoreLocationDriveLocationServiceSessionProvider: DriveLocationServiceSessionProvider {
    private var session: CLServiceSession?
    private var diagnosticsTask: Task<Void, Never>?

    public var onDiagnostic: (@MainActor (DriveServiceSessionDiagnostic) -> Void)?

    public var isActive: Bool {
        session != nil
    }

    public init() {}

    public func startAlways(fullAccuracyPurposeKey: String) {
        guard session == nil else { return }
        let session = CLServiceSession(
            authorization: .always,
            fullAccuracyPurposeKey: fullAccuracyPurposeKey
        )
        self.session = session
        // Consume the session's own diagnostics stream: it is the direct,
        // push-delivered "this session is not being honored" signal (e.g.
        // `insufficientlyInUse` after a device restart until the app is
        // foregrounded once). Ends on its own when the session is invalidated.
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard let self else { return }
                    let snapshot = DriveServiceSessionDiagnostic(
                        insufficientlyInUse: diagnostic.insufficientlyInUse,
                        serviceSessionRequired: diagnostic.serviceSessionRequired,
                        authorizationDenied: diagnostic.authorizationDenied,
                        authorizationDeniedGlobally: diagnostic.authorizationDeniedGlobally,
                        authorizationRestricted: diagnostic.authorizationRestricted,
                        fullAccuracyDenied: diagnostic.fullAccuracyDenied,
                        alwaysAuthorizationDenied: diagnostic.alwaysAuthorizationDenied,
                        authorizationRequestInProgress: diagnostic.authorizationRequestInProgress
                    )
                    await MainActor.run {
                        self.onDiagnostic?(snapshot)
                    }
                }
            } catch {
                // Stream ended (session invalidated or CL error) — nothing to
                // surface; a fresh session brings a fresh stream.
            }
        }
    }

    public func stop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        session?.invalidate()
        session = nil
    }
}

public final class SystemDriveCaptureHealthStatusProvider: DriveCaptureHealthStatusProvider {
    private let locationManager = CLLocationManager()

    public init() {}

    public var alwaysLocationAuthorized: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    public var preciseLocationEnabled: Bool {
        locationManager.accuracyAuthorization == .fullAccuracy
    }

    public var motionAuthorized: Bool {
        CMMotionActivityManager.authorizationStatus() == .authorized
    }

    public var backgroundRefreshAvailable: Bool {
        UIApplication.shared.backgroundRefreshStatus == .available
    }
}

private extension DriveLocationLiveConfiguration {
    var liveConfiguration: CLLocationUpdate.LiveConfiguration {
        switch self {
        case .default:
            .default
        case .automotiveNavigation:
            .automotiveNavigation
        }
    }
}

private extension LocationSample {
    func matchesIdleWakeAnchor(_ other: LocationSample) -> Bool {
        abs(latitude - other.latitude) < 0.000001
            && abs(longitude - other.longitude) < 0.000001
            && abs(timestamp.timeIntervalSince(other.timestamp)) < 1
    }
}

public enum DriveCaptureActivityStatus: String, Equatable, Sendable {
    case stopped = "stopped"
    case paused = "paused"
    case idleAnchored = "idle anchored"
    case idlePriming = "idle priming"
    case idleWake = "idle wake"
    case idleDormant = "idle dormant"
    case candidate = "candidate"
    case recording = "recording"
    case parking = "parking"

}

public enum DriveCaptureWakeReason: String, Equatable, Sendable {
    case startMonitoring
    case foregroundLaunch
    case locationWake
    /// Background launch for a non-location reason (App-Intent automation,
    /// background task, silent push). Must bootstrap like a location wake:
    /// a fresh process that skips arming its CoreLocation clients becomes a
    /// suspended zombie that no SLC/visit/geofence event can ever wake.
    case backgroundLaunch
    case protectedDataAvailable

    var startsInBackground: Bool {
        self == .locationWake || self == .backgroundLaunch
    }
}

enum DriveCaptureActivityLevel: Equatable {
    case stopped
    case paused
    case idleAnchored
    case idlePriming
    case idleWake
    case idleDormant
    case candidate
    case recording
    case parking

    var status: DriveCaptureActivityStatus {
        switch self {
        case .stopped:
            .stopped
        case .paused:
            .paused
        case .idleAnchored:
            .idleAnchored
        case .idlePriming:
            .idlePriming
        case .idleWake:
            .idleWake
        case .idleDormant:
            .idleDormant
        case .candidate:
            .candidate
        case .recording:
            .recording
        case .parking:
            .parking
        }
    }
}

public enum DriveCaptureDiagnosticsMode: String, Codable, Equatable, Sendable {
    case standard
    case detailed

    public var sampleRetentionDays: Int {
        switch self {
        case .standard: 1
        case .detailed: DiagnosticLocationSample.retentionDays
        }
    }

    public var recordsCaptureEvents: Bool { self == .detailed }
}

@MainActor
public final class DriveCaptureRuntime {
    private static let powerHintWindow: TimeInterval = 5 * 60
    /// Route-change notifications miss connections that happen while the app
    /// is backgrounded, so the capture pipeline polls the audio route on this
    /// cadence whenever a drive may be in progress.
    static let routeObservationInterval: TimeInterval = 60
    /// Even forced polls (candidate/trip start) keep at least this spacing.
    static let forcedRouteObservationFloor: TimeInterval = 10
    /// Heartbeat floor for the possible-drive recovery analyzer when no
    /// deferral happened on the triggering sample.
    static let possibleDriveJournalInterval: TimeInterval = 60
    /// Wait for the diagnostic burst to go quiet before materializing a
    /// recovered trip so the saved route includes its actual endpoint.
    static let possibleDriveRecoveryQuietPeriod: TimeInterval = 60
    /// Startup replay catches a recent candidate if iOS suspended the process
    /// before the quiet-period task could finish.
    static let possibleDriveRecoveryLookback: TimeInterval = 2 * 24 * 60 * 60
    static let possibleDriveRecoveryScanInterval: TimeInterval = 15 * 60
    /// Floor between journaled background-wake entries.
    static let backgroundWakeJournalInterval: TimeInterval = 30
    static let locationServiceSessionPurposeKey = "MileageTripCapture"
    static let defaultPermissionServiceSessionLease: TimeInterval = 60
    /// After a drive completes, keep the app alive in `.idleWake` (live GPS +
    /// background-activity session) for this window so a quick resumption — a
    /// short errand stop and return — is captured directly. A held service
    /// session dies with the process, so once iOS *terminates* a parked app the
    /// only resumption path is a terminated-app relaunch (parked-anchor geofence
    /// / SLC exit), which is unreliable: on 2026-06-22 evening it never fired for
    /// a return leg ~2 min after a vehicle-disconnect trip end, and the whole leg
    /// was lost. Staying alive briefly catches that case without depending on the
    /// relaunch. The window self-expires to indicator-free `.idleAnchored` (via
    /// the existing idle-capture timeout) if no drive resumes. Trade-off: the
    /// location indicator stays on for this window after each drive. Set to 0 to
    /// disable and fall back to relaunch-only behavior.
    static let postDriveResumptionGrace: TimeInterval = 240
    private static let journaledRecoveryCandidateCap = 64
    /// Floor between attempts to save the same throwing pending completion
    /// draft. Without it a persistently-failing draft (validation error,
    /// store contention) re-ran the full completion pipeline on every capture
    /// event — once per second while GPS is live — forever.
    static let defaultCompletionRetryMinimumInterval: TimeInterval = 30
    /// Floor between full-checkpoint encodes on the 1 Hz location path when
    /// nothing significant changed. The checkpoint encodes the entire sample
    /// array, so per-fix saves cost O(n) per sample — ~3 MB JSON per second by
    /// the end of a three-hour drive, all on the main thread.
    static let defaultCheckpointSaveThrottleInterval: TimeInterval = 15

    private let locationProvider: any DriveLocationProvider
    private let fallbackLocationProvider: any DriveLocationProvider
    private let activeDriveStore: ActiveDriveStore
    private let completionCoordinator: any DriveCompletionCoordinating
    private let diagnostics: DiagnosticsService?
    private let diagnosticSampleStore: (any DiagnosticSamplePersisting)?
    private let captureEventStore: (any DriveCaptureEventPersisting)?
    private let pendingStartSignalStore: (any PendingDriveStartSignalPersisting)?
    private let bluetoothVehicleHintProvider: (() -> Bool)?
    private let routeObservationRequest: (() -> Void)?
    private var automaticTripStartMode: AutomaticTripStartMode
    private let configuration: DriveCaptureConfiguration
    private let motionEvidenceProvider: any MotionEvidenceProvider
    private let idleWakeProvider: any DriveIdleWakeProvider
    private let backgroundWakeProvider: any DriveBackgroundWakeProvider
    private let backgroundActivitySessionProvider: any DriveBackgroundActivitySessionProvider
    private let locationServiceSessionProvider: any DriveLocationServiceSessionProvider
    private let healthStatusProvider: any DriveCaptureHealthStatusProvider
    private let idlePrimingDuration: TimeInterval
    private let permissionServiceSessionLease: TimeInterval
    private let postDriveResumptionGraceDuration: TimeInterval
    private let trackingRestorationNoticeDelay: TimeInterval
    private let possibleDriveRecoveryQuietPeriodDuration: TimeInterval
    private let completionRetryMinimumInterval: TimeInterval
    private let checkpointSaveThrottleInterval: TimeInterval
    private var diagnosticsMode: DriveCaptureDiagnosticsMode

    private var reducer: DriveCaptureReducer
    /// Last attempt to complete a throwing pending draft, keyed by draft ID so
    /// a fresh draft always attempts immediately.
    private var lastCompletionAttempt: (draftID: UUID, at: Date)?
    /// Bookkeeping for the 1 Hz checkpoint-save throttle: what the last saved
    /// checkpoint looked like, when it was written, and whether the live state
    /// has drifted past it (so a warm reload must flush before loading).
    private var lastSavedCheckpointSignature: CheckpointSignature?
    private var lastCheckpointSaveAt: Date?
    private var checkpointDirty = false
    private var stopDeadlineTask: Task<Void, Never>?
    private var idleCaptureTimeoutTask: Task<Void, Never>?
    private var idleCaptureTimeoutLevel: DriveCaptureActivityLevel?
    private var permissionServiceSessionLeaseTask: Task<Void, Never>?
    private var permissionServiceSessionLeaseUntil: Date?
    private var monitoringSessionID = UUID()
    private var powerConnected = false
    private var recentPowerConnectedUntil: Date?
    private var recentPowerDisconnectedUntil: Date?
    private var isMonitoring = false
    private var sceneIsBackgrounded = false
    private var idleWakeHighFidelityUntil: Date?
    /// Why the high-fidelity `.idleWake` window is open. `false` = an ordinary
    /// wake probe (geofence/SLC/motion) that should be abandoned early if the
    /// first samples show no driving, to save battery. `true` = the post-drive
    /// resumption grace, which must ride through the routine parked
    /// "No driving signal" samples a parked car emits and end only at expiry or
    /// a confirmed resumption. Without this split, `ingestIdle`'s stationary
    /// "No driving signal" output would trip `clearIdleHighFidelityAfterRejectedProbe`
    /// and collapse the grace within ~1s of parking.
    private var idleWakeHighFidelityIsResumptionGrace = false
    private var lastMotionActivitySignature: String?
    private var pendingSignalObserver: PendingStartSignalNotificationObserver?
    private var activePendingSignalID: UUID?
    private var activityLevel: DriveCaptureActivityLevel = .stopped
    private var health: TrackingHealth = .unknown
    private var lastRouteObservationRequestAt: Date?
    private var isRequestingRouteObservation = false
    /// Identifies the current `CLServiceSession` instance (bumped each time a new
    /// one is created) and when it was created, so the `serviceSessionRequired`
    /// instrumentation can report how old the session is when CL rejects it.
    private var serviceSessionGeneration = 0
    private var serviceSessionStartedAt: Date?
    /// Live-GPS stream health, so a movement-proving wake (SLC/visit/geofence
    /// exit) can tell a healthy stream from the 2026-06-22 stall where
    /// `liveUpdates` runs but Core Location withholds fixes (a session started
    /// from a non-location background context is never fulfilled).
    private var liveLocationStartedAt: Date?
    private var lastLiveSampleAt: Date?
    private var serviceSessionRequiredSinceLastSample = false
    private var liveLocationRestartTimes: [Date] = []
    private var pauseResumeTask: Task<Void, Never>?
    private var pauseResumeDeadline: Date?
    private var lastServiceSessionDiagnostic: DriveServiceSessionDiagnostic?
    private var lastPossibleDriveJournalAt: Date?
    private var lastPossibleDriveRecoveryScanAt: Date?
    private var journaledRecoveryCandidateIDs: Set<UUID> = []
    private struct PendingPossibleDriveRecovery {
        var startDate: Date
        var lastSampleDate: Date
    }
    private var pendingPossibleDriveRecoveries: [UUID: PendingPossibleDriveRecovery] = [:]
    private var possibleDriveRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var lastBackgroundWakeJournalAt: Date?
    /// Classic-manager fallback bookkeeping (2026-07-05 incident): engaged when
    /// Core Location refuses the service session while drive evidence is
    /// active, so samples keep flowing on the classic delegate path.
    private var fallbackEngagedAt: Date?
    private var lastFallbackSampleAt: Date?
    private var fallbackSampleCount = 0
    /// While the fallback is delivering, the wake-driven session re-honor
    /// attempts are rate-limited to one cycle per window so a working fallback
    /// doesn't sit under a noisy session-cycling loop.
    private var lastFallbackEraSessionCycleAt: Date?
    private var restorationNoticeTask: Task<Void, Never>?
    private var restorationNoticeArmedAt: Date?
    /// Anchor-exit churn gates (2026-07-05): non-persisted per-process floors.
    private var lastParkedAnchorExitSignalAt: Date?
    private var lastParkedExitSuppressionJournalAt: Date?
    /// Last foreground self-heal pass (see `selfHealSystemRegistrationsOnForeground`).
    private var lastForegroundSelfHealAt: Date?
    /// Still-parked SLC wake suppression journal floor (2026-07-06): non-persisted —
    /// each background-relaunch churn cycle is a fresh process, so one journal row
    /// per cycle is exactly the telemetry that proves the loop is dead.
    private var lastSlcAnchorSuppressionJournalAt: Date?
    /// Journal dedup for identical-source candidate arms (2026-07-05: 36
    /// same-stamp rows). Suppressed repeats surface on the next journaled line.
    private var lastCandidateStartedJournal: (source: String?, at: Date)?
    private var suppressedCandidateStartedRepeats = 0
    private static let candidateStartedJournalInterval: TimeInterval = 10

    public var onTripCompleted: ((TripSummary, [LocationSample], [UUID]) -> Void)?
    public var onHealthChanged: ((TrackingHealth) -> Void)?
    /// Core Location reported the held session is not authorizing background
    /// delivery (`insufficientlyInUse`/`serviceSessionRequired`) — fired on
    /// each such diagnostic transition and on `serviceSessionRequired` location
    /// updates. The app layer uses this for the post-restart "open the app
    /// once" notice.
    public var onServiceSessionUnfulfilled: (@MainActor (DriveServiceSessionDiagnostic) -> Void)?
    /// An unfulfilled session has produced NO samples (primary or fallback) for
    /// the notice delay while strong drive evidence is active — the human
    /// backstop for the state the automatic fallback cannot rescue
    /// (2026-07-05 incident: one foreground restored samples within a second).
    public var onTrackingRestorationNeeded: (@MainActor (DriveTrackingRestorationAdvice) -> Void)?
    public var onOutput: ((DriveCaptureOutput) -> Void)?
    public var onActivityStatusChanged: ((DriveCaptureActivityStatus) -> Void)?
    public var onActiveDriveChanged: (@MainActor (CurrentDriveSummary?) -> Void)?
    private var lastEmittedActiveDrive: CurrentDriveSummary?

    public init(
        activeDriveStore: ActiveDriveStore,
        completionCoordinator: any DriveCompletionCoordinating,
        diagnostics: DiagnosticsService? = nil,
        diagnosticSampleStore: (any DiagnosticSamplePersisting)? = nil,
        captureEventStore: (any DriveCaptureEventPersisting)? = nil,
        pendingStartSignalStore: (any PendingDriveStartSignalPersisting)? = nil,
        bluetoothVehicleHintProvider: (() -> Bool)? = nil,
        routeObservationRequest: (() -> Void)? = nil,
        configuration: DriveCaptureConfiguration = .automatic,
        locationProvider: (any DriveLocationProvider)? = nil,
        fallbackLocationProvider: (any DriveLocationProvider)? = nil,
        motionEvidenceProvider: (any MotionEvidenceProvider)? = nil,
        idleWakeProvider: (any DriveIdleWakeProvider)? = nil,
        backgroundWakeProvider: (any DriveBackgroundWakeProvider)? = nil,
        backgroundActivitySessionProvider: (any DriveBackgroundActivitySessionProvider)? = nil,
        locationServiceSessionProvider: (any DriveLocationServiceSessionProvider)? = nil,
        healthStatusProvider: (any DriveCaptureHealthStatusProvider)? = nil,
        diagnosticsMode: DriveCaptureDiagnosticsMode = .standard,
        idlePrimingDuration: TimeInterval? = nil,
        permissionServiceSessionLease: TimeInterval? = nil,
        postDriveResumptionGrace: TimeInterval? = nil,
        trackingRestorationNoticeDelay: TimeInterval? = nil,
        possibleDriveRecoveryQuietPeriod: TimeInterval? = nil,
        completionRetryMinimumInterval: TimeInterval? = nil,
        checkpointSaveThrottleInterval: TimeInterval? = nil,
        automaticTripStartMode: AutomaticTripStartMode = .both
    ) {
        self.activeDriveStore = activeDriveStore
        self.completionCoordinator = completionCoordinator
        self.diagnostics = diagnostics
        self.diagnosticSampleStore = diagnosticSampleStore
        self.captureEventStore = captureEventStore
        self.pendingStartSignalStore = pendingStartSignalStore
        self.bluetoothVehicleHintProvider = bluetoothVehicleHintProvider
        self.routeObservationRequest = routeObservationRequest
        self.automaticTripStartMode = automaticTripStartMode
        self.configuration = configuration
        let resolvedMotionEvidenceProvider = motionEvidenceProvider ?? SystemMotionEvidenceProvider()
        self.motionEvidenceProvider = resolvedMotionEvidenceProvider
        self.locationProvider = locationProvider ?? CoreLocationDriveLocationProvider(motionEvidenceProvider: resolvedMotionEvidenceProvider)
        self.fallbackLocationProvider = fallbackLocationProvider ?? CoreLocationManagerDriveLocationProvider(motionEvidenceProvider: resolvedMotionEvidenceProvider)
        let resolvedIdleWakeProvider = idleWakeProvider ?? CoreLocationRegionDriveIdleWakeProvider(
            radiusMeters: configuration.startPolicy.parkedAnchorRadiusMeters
        )
        self.idleWakeProvider = resolvedIdleWakeProvider
        let resolvedBackgroundWakeProvider = backgroundWakeProvider ?? CoreLocationBackgroundWakeProvider()
        self.backgroundWakeProvider = resolvedBackgroundWakeProvider
        self.backgroundActivitySessionProvider = backgroundActivitySessionProvider ?? CoreLocationBackgroundActivitySessionProvider()
        self.locationServiceSessionProvider = locationServiceSessionProvider ?? CoreLocationDriveLocationServiceSessionProvider()
        self.healthStatusProvider = healthStatusProvider ?? SystemDriveCaptureHealthStatusProvider()
        self.diagnosticsMode = diagnosticsMode
        self.idlePrimingDuration = max(0.001, idlePrimingDuration ?? configuration.startPolicy.idlePrimingWindow)
        self.permissionServiceSessionLease = max(0.001, permissionServiceSessionLease ?? Self.defaultPermissionServiceSessionLease)
        self.postDriveResumptionGraceDuration = max(0, postDriveResumptionGrace ?? Self.postDriveResumptionGrace)
        self.trackingRestorationNoticeDelay = max(0.001, trackingRestorationNoticeDelay ?? Self.defaultTrackingRestorationNoticeDelay)
        self.possibleDriveRecoveryQuietPeriodDuration = max(
            0.001,
            possibleDriveRecoveryQuietPeriod ?? Self.possibleDriveRecoveryQuietPeriod
        )
        self.completionRetryMinimumInterval = max(
            0.001,
            completionRetryMinimumInterval ?? Self.defaultCompletionRetryMinimumInterval
        )
        self.checkpointSaveThrottleInterval = max(
            0.001,
            checkpointSaveThrottleInterval ?? Self.defaultCheckpointSaveThrottleInterval
        )
        reducer = DriveCaptureReducer(state: DriveCaptureState(
            configuration: configuration,
            automaticTripStartMode: automaticTripStartMode
        ))
        resolvedMotionEvidenceProvider.onActivity = { [weak self] snapshot in
            self?.handleMotionActivity(snapshot, receivedAt: Date())
        }
        resolvedIdleWakeProvider.onWake = { [weak self] date in
            self?.handleIdleWake(at: date)
        }
        resolvedBackgroundWakeProvider.onSignificantChange = { [weak self] date, sample in
            self?.handleBackgroundWake(at: date, source: .significantLocationChange, sample: sample)
        }
        resolvedBackgroundWakeProvider.onVisitDeparture = { [weak self] date in
            self?.handleBackgroundWake(at: date, source: .visitDeparture)
        }
        if pendingStartSignalStore != nil {
            pendingSignalObserver = PendingStartSignalNotificationObserver(runtime: self)
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        powerConnected = Self.isDevicePowerConnected()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: UIDevice.current
        )
        self.locationProvider.onUpdate = { [weak self] update in
            self?.processUpdate(update, source: .primary)
        }
        self.fallbackLocationProvider.onUpdate = { [weak self] update in
            self?.processUpdate(update, source: .fallback)
        }
        self.locationServiceSessionProvider.onDiagnostic = { [weak self] diagnostic in
            self?.handleServiceSessionDiagnostic(diagnostic)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public var state: DriveCaptureState {
        reducer.state
    }

    public func setAutomaticTripStartMode(_ mode: AutomaticTripStartMode) {
        automaticTripStartMode = mode
        _ = reducer.setAutomaticTripStartMode(mode)
        refreshAutomaticStartEligibility()
        if mode == .bluetoothOrCarPlay {
            cancelPossibleDriveRecoveryTasks()
            lastPossibleDriveRecoveryScanAt = nil
        }
        if suppressesAutomaticStart(at: Date()) {
            idleWakeHighFidelityUntil = nil
            cancelIdleCaptureTimeout()
        }
        // Before bootstrap the reducer is only a placeholder. The app owns the
        // preference; never overwrite a saved in-flight drive with this state.
        guard isMonitoring else { return }
        persistStateAndHandle([.checkpointChanged(reducer.state)])
        refreshHealth()
    }

    private func suppressesAutomaticStart(at date: Date) -> Bool {
        (reducer.state.phase == .idle || reducer.state.phase == .candidate)
            && !reducer.allowsAutomaticTripStart(at: date)
    }

    private func refreshAutomaticStartEligibility(at date: Date = Date()) {
        _ = reducer.refreshAutomaticStartEligibility(at: date)
    }

    public func setDiagnosticsMode(_ mode: DriveCaptureDiagnosticsMode) {
        diagnosticsMode = mode
    }

    public var activeDriveSummary: CurrentDriveSummary? {
        reducer.state.currentDriveSummary()
    }

    public var activityStatus: DriveCaptureActivityStatus {
        activityLevel.status
    }

    public func requestLocationPermission() {
        startTemporaryPermissionServiceSession()
        refreshHealth()
    }

    public func requestMotionPermission() {
        motionEvidenceProvider.primeHistory()
        refreshHealth()
    }

    public func refreshTrackingHealth() {
        refreshHealth()
    }

    public func startMonitoring(rearmNoAnchorPriming: Bool = false) {
        bootstrapForWake(reason: .startMonitoring, rearmNoAnchorPriming: rearmNoAnchorPriming)
    }

    public func bootstrapForWake(
        reason: DriveCaptureWakeReason,
        rearmNoAnchorPriming: Bool = false
    ) {
        let startedAt = Date()
        recordWakeBootstrapEvent(
            "Wake bootstrap started",
            reason: reason,
            detectionReason: "monitoring=\(isMonitoring)"
        )
        // Re-attach the parked-anchor geofence from the non-secure beacon before
        // loading the encrypted stores, so a geofence-exit relaunch is caught even
        // while the device is locked (incl. before first unlock). Journal by
        // outcome: `.notNeeded` (every warm bootstrap) is silent — pre-ADR-005 it
        // produced one misleading "restored from beacon" row per relaunch.
        switch idleWakeProvider.restoreMonitoringIfNeeded() {
        case .adopted:
            journalCaptureEvent(
                date: startedAt,
                category: "tracking",
                message: "Parked anchor geofence adopted (system registration persisted)",
                wakeReason: reason.rawValue
            )
        case .rearmed:
            journalCaptureEvent(
                date: startedAt,
                category: "tracking",
                message: "Parked anchor geofence restored from beacon",
                wakeReason: reason.rawValue
            )
        case .cleanedUpOrphan:
            journalCaptureEvent(
                date: startedAt,
                category: "tracking",
                message: "Stale parked anchor region removed (no beacon)",
                wakeReason: reason.rawValue
            )
        case .notNeeded:
            break
        }
        // The SLC + visit relaunch backbone is (re)armed by `applyCapturePolicy`
        // (called below for every bootstrap path) as a function of the resulting
        // active level, so it survives a locked relaunch and also re-arms on
        // resume — not just on cold bootstrap.
        if reason.startsInBackground {
            recordBackgroundWake(at: startedAt, wakeReason: reason.rawValue)
        } else {
            sceneIsBackgrounded = false
        }

        guard !isMonitoring else {
            if rearmNoAnchorPriming {
                clearIdlePrimingExhaustion()
            }
            diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Drive capture already active"))
            loadActiveState(wakeReason: reason.rawValue)
            recordWakeBootstrapStateLoaded(reason: reason)
            applyCapturePolicy()
            let consumedCount = consumePendingStartSignals(wakeReason: reason.rawValue)
            recordWakeBootstrapEvent(
                "Wake bootstrap pending signals consumed",
                reason: reason,
                detectionReason: "count=\(consumedCount)"
            )
            settleDueWorkAfterWake(now: Date())
            recoverRecentPossibleDriveCandidates()
            recordWakeBootstrapPolicyApplied(reason: reason)
            refreshHealth()
            recordWakeBootstrapCompleted(reason: reason, startedAt: startedAt)
            return
        }
        isMonitoring = true
        idleWakeHighFidelityUntil = nil
        monitoringSessionID = UUID()
        lastPossibleDriveJournalAt = nil
        lastPossibleDriveRecoveryScanAt = nil
        journaledRecoveryCandidateIDs = []
        cancelPossibleDriveRecoveryTasks()
        lastBackgroundWakeJournalAt = nil
        purgeExpiredDiagnosticSamples()
        purgeExpiredCaptureEvents()
        loadActiveState(wakeReason: reason.rawValue)
        recordWakeBootstrapStateLoaded(reason: reason)
        if rearmNoAnchorPriming {
            clearIdlePrimingExhaustion()
        }
        updatePowerState(recordTransition: false)
        applyCapturePolicy()
        let consumedCount = consumePendingStartSignals(wakeReason: reason.rawValue)
        recordWakeBootstrapEvent(
            "Wake bootstrap pending signals consumed",
            reason: reason,
            detectionReason: "count=\(consumedCount)"
        )
        settleDueWorkAfterWake(now: Date())
        recoverRecentPossibleDriveCandidates()
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Started iOS 26 drive capture"))
        journalCaptureEvent(category: "tracking", message: "Started drive capture")
        recordWakeBootstrapPolicyApplied(reason: reason)
        refreshHealth()
        recordWakeBootstrapCompleted(reason: reason, startedAt: startedAt)
    }

    public func stopMonitoring() {
        let outputs = reducer.apply(.trackingStopped(Date()))
        isMonitoring = false
        persistStateAndHandle(outputs)
        stopDeadlineTask?.cancel()
        stopDeadlineTask = nil
        idleCaptureTimeoutTask?.cancel()
        idleCaptureTimeoutTask = nil
        permissionServiceSessionLeaseTask?.cancel()
        permissionServiceSessionLeaseTask = nil
        permissionServiceSessionLeaseUntil = nil
        cancelPossibleDriveRecoveryTasks()
        cancelPauseResume()
        idleWakeHighFidelityUntil = nil
        setActivityLevel(.stopped)
        locationProvider.stop()
        disengageLocationFallback(now: Date(), reason: "monitoringStopped")
        cancelRestorationNotice(reason: "monitoringStopped")
        motionEvidenceProvider.stopLiveUpdates()
        idleWakeProvider.stopMonitoring()
        backgroundWakeProvider.stopMonitoring()
        backgroundActivitySessionProvider.stop()
        stopLocationServiceSession(reason: "trackingStopped")
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Stopped drive capture"))
        journalCaptureEvent(category: "tracking", message: "Stopped drive capture")
        refreshHealth()
    }

    public func pause(until date: Date) {
        let now = Date()
        let until = date > now ? date : now.addingTimeInterval(60 * 60)
        // Paused = user-suspended tracking: `applyCapturePolicy` (via
        // `persistStateAndHandle`) drops to `.paused`, which releases the service session.
        persistStateAndHandle(reducer.apply(.trackingPaused(until: until)))
        health.trackingPausedUntil = until
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Paused until \(until)"))
        journalCaptureEvent(category: "tracking", message: "Paused until \(until)")
        onHealthChanged?(health)
    }

    public func pause(for interval: TimeInterval) {
        pause(until: Date().addingTimeInterval(interval))
    }

    public func pauseToday(calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 60 * 60)
        pause(until: tomorrow)
    }

    public func resume() {
        refreshAutomaticStartEligibility()
        clearIdlePrimingExhaustion()
        persistStateAndHandle(reducer.apply(.trackingResumed(Date())))
        if isMonitoring {
            applyCapturePolicy()
            consumePendingStartSignals(wakeReason: "sceneActive")
        }
        health.trackingPausedUntil = nil
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Resumed tracking"))
        journalCaptureEvent(category: "tracking", message: "Resumed tracking")
        onHealthChanged?(health)
    }

    public func sceneBecameActive() {
        sceneIsBackgrounded = false
        // Foreground opens were invisible in device pulls (only background
        // launches journaled), which made the 2026-07-07 stuck-arrow and
        // late-start investigations unable to distinguish user-opens from
        // background wakes. One row per activation, with the policy snapshot.
        journalCaptureEvent(
            category: "lifecycle",
            message: "Scene became active",
            trackingPhase: reducer.state.phase.rawValue,
            activityLevel: activityLevel.status.rawValue,
            wakeReason: "sceneActive",
            detectionReason: "monitorActive=\(idleWakeProvider.isMonitoring) monitorConsuming=\(idleWakeProvider.isConsumingEvents) backgroundWakeActive=\(backgroundWakeProvider.isMonitoring)"
        )
        // Foreground restores session honoring directly (2026-07-05: samples
        // within one second) — the notice would be stale the moment it fired.
        cancelRestorationNotice(reason: "sceneBecameActive")
        loadActiveState(wakeReason: "sceneActive")
        if isMonitoring {
            applyCapturePolicy()
        }
        selfHealSystemRegistrationsOnForeground(now: Date())
        persistStateAndHandle(reducer.apply(.sceneBecameActive(Date())))
        completePendingDraftIfNeeded()
        scheduleStopDeadlineIfNeeded()
        refreshHealth()
    }

    /// Minimum spacing between foreground self-heal passes. Each pass re-asserts
    /// the SLC/visit registrations (redelivering one fix, absorbed by the stale
    /// and parked-anchor gates) and reconciles the parked-anchor region state —
    /// cheap, but not worth repeating for rapid app-switch bounces.
    private static let foregroundSelfHealInterval: TimeInterval = 300

    /// Foreground is the safe moment to repair registrations the system may
    /// have silently dropped (Location Services toggled, permission churn,
    /// post-reboot edge cases): the adopt path skips `requestState` while
    /// parked, so this is also where the missed-exit catch-up lives (ADR-005).
    private func selfHealSystemRegistrationsOnForeground(now: Date) {
        guard isMonitoring else { return }
        if let last = lastForegroundSelfHealAt, now.timeIntervalSince(last) < Self.foregroundSelfHealInterval {
            return
        }
        lastForegroundSelfHealAt = now
        backgroundWakeProvider.forceRearm()
        if idleWakeProvider.verifyOrRearmSystemRegistrationOnForeground() {
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Parked anchor geofence self-healed on foreground",
                wakeReason: "sceneActive"
            )
        }
    }

    public func sceneBecameInactive() {
        persistStateAndHandle(reducer.apply(.sceneBecameInactive(Date())))
    }

    public func sceneEnteredBackground() {
        sceneIsBackgrounded = true
        finalizeCaptureIfDue(now: Date())
        completePendingDraftIfNeeded()
        scheduleStopDeadlineIfNeeded()
        applyCapturePolicy()
    }

    /// Settle work that came due while the app was suspended — a candidate past its expiry
    /// or a recording past its stop deadline — and reschedule the deadline timer. A no-op
    /// unless something is genuinely due (during active driving `stopDueAt` is nil), so it is
    /// safe on every wake and can never end a live recording early. Single source of truth for
    /// the settle step shared by both `bootstrapForWake` branches.
    private func settleDueWorkAfterWake(now: Date) {
        finalizeCaptureIfDue(now: now)
        if reducer.state.pausedUntil == nil, health.trackingPausedUntil != nil {
            // The reducer just settled an expired pause — the health mirror
            // must stop advertising it or the UI keeps showing "paused".
            health.trackingPausedUntil = nil
            onHealthChanged?(health)
        }
        completePendingDraftIfNeeded()
        scheduleStopDeadlineIfNeeded()
    }

    /// Every timer/lifecycle expiry uses the bounded automation permission;
    /// incidental confidence signals cannot keep a start window alive.
    private func finalizeCaptureIfDue(now: Date) {
        refreshAutomaticStartEligibility(at: now)
        persistStateAndHandle(reducer.finalizeIfDue(now: now))
    }

    /// In-process expiry path for a pause: if the app stays alive (or merely
    /// suspended — the sleep resumes on the next wake), the timer ends the
    /// pause at its deadline; background wakes and foreground passes cover the
    /// terminated-app case via `settleDueWorkAfterWake`.
    private func schedulePauseResume() {
        guard let until = reducer.state.pausedUntil else {
            cancelPauseResume()
            return
        }
        if pauseResumeDeadline == until, pauseResumeTask != nil { return }
        pauseResumeTask?.cancel()
        pauseResumeDeadline = until
        let delay = max(0, until.timeIntervalSinceNow) + 1
        pauseResumeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.pauseResumeTask = nil
                self.pauseResumeDeadline = nil
                guard self.isMonitoring, !self.isPauseInEffect(now: Date()) else { return }
                self.journalCaptureEvent(
                    category: "tracking",
                    message: "Pause expired — resuming tracking",
                    wakeReason: "pauseExpiry"
                )
                self.settleDueWorkAfterWake(now: Date())
                self.refreshHealth()
            }
        }
    }

    private func cancelPauseResume() {
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        pauseResumeDeadline = nil
    }

    public func armDriveStart(trigger: DriveStartExternalTrigger, at date: Date = Date()) {
        guard isMonitoring else { return }
        let signal = DriveStartEngine.signal(
            forExternalTrigger: trigger,
            at: date,
            policy: configuration.startPolicy
        )
        journalCaptureEvent(
            date: date,
            category: "startSignal",
            message: "External drive start trigger \(trigger.rawValue)",
            wakeReason: trigger.rawValue,
            detectionReason: "expiresAt=\(signal.expiresAt)"
        )
        applyStartSignal(signal, receivedAt: date, wakeReason: trigger.rawValue)
    }

    public func flush() {
        do {
            try activeDriveStore.save(reducer.state)
            emitActiveDriveIfChanged()
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Failed to flush active drive: \(error.localizedDescription)"))
        }
    }

    /// Save before publishing; unlike capture's best-effort checkpoints, an
    /// interactive review must tell its caller when persistence fails.
    @discardableResult
    public func commitCurrentDriveEdit(_ edit: CurrentDriveEdit, expectedID: UUID) throws -> CurrentDriveSummary {
        let updated = try reducer.commitCurrentDriveEdit(edit, expectedID: expectedID) { state in
            try activeDriveStore.save(state)
        }
        lastSavedCheckpointSignature = currentCheckpointSignature()
        lastCheckpointSaveAt = Date()
        checkpointDirty = false
        emitActiveDriveIfChanged()
        return updated
    }

    public func setCurrentDriveClassification(_ classification: TripClassification?) {
        persistStateAndHandle(reducer.setCurrentDriveClassification(classification))
    }

    public func setCurrentDriveBusinessPurpose(_ purpose: String?) {
        persistStateAndHandle(reducer.setCurrentDriveBusinessPurpose(purpose))
    }

    public func setCurrentDriveNote(_ note: String?) {
        persistStateAndHandle(reducer.setCurrentDriveNote(note))
    }

    public func addCurrentDriveFee(_ fee: TripFee) {
        persistStateAndHandle(reducer.appendCurrentDriveFee(fee))
    }

    /// Mid-drive vehicle choice from the live bar; nil reverts to automatic
    /// attribution at completion.
    public func setCurrentDriveVehicle(_ vehicleID: UUID?) {
        persistStateAndHandle(reducer.setCurrentDriveVehicle(vehicleID))
    }

    /// Feeds a confidently mapped local CarPlay/Bluetooth connection into the
    /// capture latch. nil represents disconnect and is deliberately ignored.
    public func observeMappedVehicleConnection(_ vehicleID: UUID?) {
        let outputs = reducer.observeMappedVehicleConnection(vehicleID)
        guard !outputs.isEmpty else { return }
        persistStateAndHandle(outputs)
    }

    /// Reserved: no UI caller as of 2.0 (the live bar ends drives automatically).
    public func endCurrentDriveNow(at date: Date = Date()) {
        persistStateAndHandle(reducer.completeCurrentRecording(at: date))
    }

    /// Finalizes the current recording as a completed trip and keeps recording a
    /// new leg from the same moment, without dropping GPS fidelity in between.
    public func splitCurrentDriveNow(at date: Date = Date()) {
        let outputs = reducer.splitCurrentRecording(at: date)
        guard !outputs.isEmpty else { return }
        diagnostics?.record(DiagnosticEvent(category: "detection", message: "Drive split into new leg"))
        journalCaptureEvent(date: date, category: "detection", message: "Drive split into new leg")
        persistStateAndHandle(outputs)
    }

    /// Reserved: no UI caller as of 2.0 (the live bar ends drives automatically).
    @discardableResult
    public func discardCurrentDrive() -> DriveCaptureState? {
        let previous = reducer.state.currentDriveSummary() == nil ? nil : reducer.state
        persistStateAndHandle(reducer.discardCurrentDrive())
        return previous
    }

    public func vehicleConnectionChanged(
        active: Bool,
        source: VehicleConnectionSource,
        at date: Date = Date()
    ) {
        guard isMonitoring else { return }
        refreshAutomaticStartEligibility(at: date)
        if active, reducer.allowsAutomaticTripStart(at: date),
           (reducer.state.phase == .idle || reducer.state.phase == .candidate) {
            clearIdlePrimingExhaustion()
            let signal = DriveStartEngine.signal(
                forVehicleConnection: source,
                at: date,
                policy: configuration.startPolicy
            )
            extendHighFidelityWindow(until: signal.expiresAt)
            journalStartSignal(signal, receivedAt: date, wakeReason: source.rawValue)
        }
        journalCaptureEvent(
            date: date,
            category: "vehicleConnection",
            message: active ? "Vehicle connection active: \(source.rawValue)" : "Vehicle connection inactive: \(source.rawValue)",
            wakeReason: source.rawValue
        )
        persistStateAndHandle(reducer.apply(.vehicleConnectionChanged(active: active, source: source, at: date)))
        refreshHealth()
    }

    public func vehicleRouteObserved(
        source: VehicleConnectionSource,
        at date: Date = Date()
    ) {
        guard isMonitoring else { return }
        let signal = DriveStartEngine.signal(
            source: .weakBluetoothName,
            startedAt: date,
            policy: configuration.startPolicy
        )
        journalCaptureEvent(
            date: date,
            category: "vehicleConnection",
            message: "Seeded vehicle route observed before trust: \(source.rawValue)",
            wakeReason: source.rawValue
        )
        applyStartSignal(signal, receivedAt: date, wakeReason: source.rawValue)
    }

    /// Belt-and-suspenders floor under the reducer's anchor-exit cooldown: no
    /// provider pathology may apply the same-source signal more than ~4×/min.
    private static let parkedAnchorExitMinimumInterval: TimeInterval = 15


    private func handleIdleWake(at date: Date) {
        guard isMonitoring else { return }
        if reducer.state.phase == .idle,
           let last = lastParkedAnchorExitSignalAt,
           date.timeIntervalSince(last) < Self.parkedAnchorExitMinimumInterval {
            return
        }
        lastParkedAnchorExitSignalAt = date
        let signal = DriveStartEngine.signal(
            source: .parkedAnchorExit,
            startedAt: date,
            policy: configuration.startPolicy
        )
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Idle wake monitor exited parked anchor"))
        journalCaptureEvent(date: date, category: "tracking", message: "Idle wake monitor exited parked anchor", wakeReason: "idleWake")
        recoverStalledLiveLocationIfNeeded(now: date, wakeReason: "idleWake")
        applyStartSignal(signal, receivedAt: date, wakeReason: "idleWake")
    }

    /// Oldest significant-change event that may still arm a start signal. An
    /// SLC generated while actually driving is delivered within seconds to a
    /// few minutes; ten minutes is far past any live-delivery latency while
    /// still catching the hours-old spooled leftovers a relaunch flushes.
    private static let maxSignificantChangeEventAgeSeconds: TimeInterval = 600

    /// Tier-0 wake from significant-location-change or visit departure — the
    /// locked-capable relaunch backbone independent of the parked-anchor geofence.
    /// Opens the bounded high-fidelity probe via an `.assist` start signal; commit
    /// still requires real movement evidence from the confirmation policy.
    private func handleBackgroundWake(
        at eventDate: Date,
        source: DriveStartSignalSource,
        sample: LocationSample? = nil
    ) {
        guard isMonitoring else { return }
        let now = Date()
        let wakeReason = source == .visitDeparture ? "visitDeparture" : "significantLocationChange"
        let message = source == .visitDeparture ? "Visit departure wake" : "Significant location change wake"
        // Stale-event gate: a relaunch can flush an SLC event spooled hours
        // earlier (2026-07-07: the 12 mini received one 18.5 h old while
        // parked at home). Ironically the very staleness that proves the
        // event says nothing about current movement also fails the anchor
        // gate's freshness check below, so without this gate the most useless
        // events are the ones that fall through and arm a GPS probe. Applies
        // ONLY to `.significantLocationChange`: a late-delivered visit
        // departure is still a real departure — a 284 s-old visit was the
        // only drive-start wake the 12 mini got that morning.
        if source == .significantLocationChange,
           now.timeIntervalSince(eventDate) > Self.maxSignificantChangeEventAgeSeconds {
            journalCaptureEvent(
                date: now,
                category: "startSignal",
                message: "Stale significant change wake dropped",
                trackingPhase: reducer.state.phase.rawValue,
                wakeReason: wakeReason,
                detectionReason: "eventAge=\(Int(max(0, now.timeIntervalSince(eventDate))))s"
            )
            return
        }
        // Still-parked SLC gate (2026-07-06 stationary-at-home churn): a freshly
        // (re)armed SLC subscription delivers the current location immediately, so
        // every background relaunch manufactures an "SLC wake" even when the phone
        // never moved — each one cost a candidate + full-accuracy service session
        // that died within a second, keeping the location indicator lit all day.
        // When the delivered fix is fresh, accurate, and inside the very fence the
        // parked anchor arms, the wake carries zero drive-start information:
        // suppress it before any signal/journal/GPS work. Applies ONLY to
        // `.significantLocationChange` — a visit departure's coordinate is the
        // place being LEFT, so proximity would suppress genuine departures. Every
        // failed condition falls through to the previous behavior (fail-open).
        if source == .significantLocationChange,
           reducer.state.phase == .idle,
           let anchor = reducer.state.parkedStartAnchor,
           let sample,
           sample.horizontalAccuracy >= 0,
           sample.horizontalAccuracy <= configuration.maxHorizontalAccuracyMeters,
           now.timeIntervalSince(sample.timestamp) <= configuration.maxLocationAgeSeconds {
            let anchorDistance = DistanceCalculator.distanceMeters(
                from: Coordinate(latitude: anchor.latitude, longitude: anchor.longitude),
                to: Coordinate(latitude: sample.latitude, longitude: sample.longitude)
            )
            if anchorDistance.isFinite, anchorDistance <= configuration.startPolicy.parkedAnchorRadiusMeters {
                journalSignificantChangeSuppressedAtAnchor(
                    receivedAt: now,
                    sample: sample,
                    anchorDistanceMeters: anchorDistance
                )
                return
            }
        }
        // Stamp the signal at delivery time, not the event time. A CLVisit
        // departure (and, less often, an SLC fix) can be delivered minutes after
        // the fact; a signal stamped in the past would either be born expired
        // (rejected in `handleStartSignal`) or arm a candidate whose
        // `candidateStartedAt` is already past the unconfirmed-candidate timeout,
        // so the probe gets killed on the first non-moving sample before it can
        // observe the drive. The true start is backfilled later (motion history /
        // parked-anchor inference). `eventDate` is kept only for diagnostics.
        let signal = DriveStartEngine.signal(
            source: source,
            startedAt: now,
            policy: configuration.startPolicy
        )
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: message))
        journalCaptureEvent(
            date: now,
            category: "tracking",
            message: message,
            wakeReason: wakeReason,
            detectionReason: "eventAge=\(Int(max(0, now.timeIntervalSince(eventDate))))s"
        )
        recoverStalledLiveLocationIfNeeded(now: now, wakeReason: wakeReason)
        applyStartSignal(signal, receivedAt: now, wakeReason: wakeReason)
    }

    private enum LocationUpdateSource {
        case primary
        case fallback
    }

    private func processUpdate(_ update: DriveLocationUpdate, source: LocationUpdateSource) {
        // In-flight updates can land after stopMonitoring()/teardown (the
        // provider loop resumes from a suspension point cancellation can't
        // abort); they must not mutate state or write checkpoints.
        guard isMonitoring else { return }
        refreshAutomaticStartEligibility(at: update.receivedAt)
        for message in update.diagnosticMessages {
            diagnostics?.record(DiagnosticEvent(category: "location", message: message))
        }
        if update.streamEnded {
            // Stream-death restart accounting belongs to the primary
            // `liveUpdates` stream; the classic fallback never sets this flag
            // by construction, so ignore it defensively.
            if source == .primary {
                handleLiveLocationStreamEnded(update)
            }
            return
        }

        guard let sample = update.sample else {
            if update.stationary {
                finalizeCaptureIfDue(now: update.receivedAt)
                completePendingDraftIfNeeded()
            }
            if update.serviceSessionRequired {
                serviceSessionRequiredSinceLastSample = true
                onServiceSessionUnfulfilled?(DriveServiceSessionDiagnostic(serviceSessionRequired: true))
                engageLocationFallback(now: update.receivedAt, trigger: "serviceSessionRequiredUpdate")
                armRestorationNoticeIfNeeded(now: update.receivedAt, diagnosticSummary: "serviceSessionRequired")
            }
            // Core Location says it needs a service session while we believe GPS is
            // running (`liveGPSActive`) at a level that requires one — the 2026-06-22
            // stall. Journal rich telemetry (session generation/age) so the next drive
            // measures whether the long-lived foreground session cleared it.
            if update.serviceSessionRequired,
               locationProvider.isActive,
               locationServiceSessionRequired(for: activityLevel) {
                let now = update.receivedAt
                journalCaptureEvent(
                    date: now,
                    category: "location",
                    message: "Location service session required",
                    trackingPhase: reducer.state.phase.rawValue,
                    activityLevel: activityLevel.status.rawValue,
                    detectionReason: "gen=\(serviceSessionGeneration) age=\(serviceSessionAgeString(now: now)) liveGPS=true level=\(activityLevel.status.rawValue) phase=\(reducer.state.phase.rawValue)"
                )
            } else {
                journalCaptureEvent(
                    date: update.receivedAt,
                    category: "location",
                    message: update.diagnosticMessages.first ?? "Location update without sample",
                    trackingPhase: reducer.state.phase.rawValue
                )
            }
            refreshHealth()
            return
        }

        switch source {
        case .primary:
            // A primary sample means the service session is honored again —
            // hand the drive back and stand the fallback down. Overlap is
            // bounded to the fallback's in-flight batch, which the ordering
            // guard below absorbs.
            lastLiveSampleAt = update.receivedAt
            serviceSessionRequiredSinceLastSample = false
            disengageLocationFallback(now: update.receivedAt, reason: "primaryResumed")
        case .fallback:
            lastFallbackSampleAt = update.receivedAt
            fallbackSampleCount += 1
        }
        cancelRestorationNotice(reason: "sampleReceived")

        // Cross-source monotonicity: during (or just after) a fallback
        // handover, drop samples that would rewind the reducer's clock. The
        // reducer stamps `lastProcessedLocationTimestamp` before its own
        // rejection paths, so this runtime check is the only ordering gate.
        // Scoped to the handover window so single-source behavior (including
        // stale-wake ingestion) is untouched.
        if let lastProcessed = reducer.state.lastProcessedLocationTimestamp,
           sample.timestamp <= lastProcessed,
           isInFallbackHandoverWindow(now: update.receivedAt) {
            diagnostics?.record(DiagnosticEvent(
                category: "location",
                message: "Dropped out-of-order \(source == .fallback ? "fallback" : "primary") sample (\(Int(lastProcessed.timeIntervalSince(sample.timestamp)))s behind)"
            ))
            return
        }

        let context = detectionContext(now: update.receivedAt)
        let options: DriveCaptureLocationOptions = update.receivedAt.timeIntervalSince(sample.timestamp) > configuration.maxLocationAgeSeconds
            ? .staleWake
            : .normal
        diagnostics?.record(DiagnosticEvent(category: "location", message: "Location update", sample: sample))
        let phaseBefore = reducer.state.phase
        let startSuppressed = suppressesAutomaticStart(at: update.receivedAt)
        let outputs = reducer.apply(.location(
            sample,
            receivedAt: update.receivedAt,
            context: context,
            options: options
        ))
        persistDiagnosticSample(
            sample,
            receivedAt: update.receivedAt,
            phase: phaseBefore,
            context: context,
            acceptedForDetection: !options.isStaleWake && !startSuppressed,
            outputs: outputs
        )
        journalPossibleDriveCandidatesIfNeeded(around: sample.timestamp, receivedAt: update.receivedAt, outputs: outputs)
        // The only high-frequency call site (1 Hz while recording): the
        // checkpoint encode may be throttled here; every other event keeps an
        // unconditional save.
        persistStateAndHandle(outputs, throttlesCheckpointSave: true)
        let driveBeganHere = outputs.contains { output in
            switch output {
            case .candidateStarted, .tripStarted:
                return true
            default:
                return false
            }
        }
        requestRouteObservationIfNeeded(now: update.receivedAt, force: driveBeganHere)
        refreshHealth()
    }

    private func handleMotionActivity(_ snapshot: MotionActivitySnapshot, receivedAt: Date) {
        guard isMonitoring else { return }
        refreshAutomaticStartEligibility(at: receivedAt)
        let hintNames = snapshot.hints.map(\.rawValue).joined(separator: ",")
        let signature = "\(hintNames)|\(snapshot.confidence.rawValue)"
        if signature != lastMotionActivitySignature {
            lastMotionActivitySignature = signature
            journalCaptureEvent(
                date: receivedAt,
                category: "motion",
                message: "Motion activity \(hintNames) confidence=\(snapshot.confidence.rawValue)",
                wakeReason: "motion",
                sampleTimestamp: snapshot.startDate
            )
        }
        if reducer.allowsAutomaticTripStart(at: receivedAt),
           reducer.state.phase == .idle || reducer.state.phase == .candidate,
           let signal = DriveStartEngine.signal(forMotion: snapshot, policy: configuration.startPolicy) {
            clearIdlePrimingExhaustion()
            extendHighFidelityWindow(until: signal.expiresAt)
            journalStartSignal(signal, receivedAt: receivedAt, wakeReason: "motion")
        }
        persistStateAndHandle(reducer.apply(.motionActivity(snapshot, receivedAt: receivedAt)))
        refreshHealth()
    }

    private func applyStartSignal(
        _ signal: DriveStartSignal,
        receivedAt: Date,
        wakeReason: String
    ) {
        refreshAutomaticStartEligibility(at: receivedAt)
        // Post-kill cooldown (2026-07-05 walk-away churn; extended 2026-07-06
        // to the SLC/visit/coarse relaunch backbone after stationary-at-home
        // wake churn): after a never-moved candidate dies to a
        // pedestrian/stationary contradiction, another passive location wake
        // must not immediately re-arm a probe — returning BEFORE the
        // high-fidelity window opens is what keeps the GPS stack and service
        // session down. Motion, Bluetooth, power, and all strong sources still
        // arm instantly.
        if DriveCaptureReducer.postKillCooldownGatedSources.contains(signal.source),
           reducer.state.phase == .idle,
           reducer.isParkedExitRearmSuppressed(at: receivedAt) {
            journalParkedExitSuppressed(receivedAt: receivedAt, wakeReason: wakeReason)
            return
        }
        if let pendingSignalID = signal.pendingSignalID {
            activatePendingSignal(id: pendingSignalID)
        }
        guard reducer.state.phase == .idle || reducer.state.phase == .candidate else {
            persistStateAndHandle(reducer.apply(.startSignal(signal, receivedAt: receivedAt)))
            refreshHealth()
            return
        }
        let outputs = reducer.apply(.startSignal(signal, receivedAt: receivedAt))
        if reducer.state.phase == .candidate, reducer.allowsAutomaticTripStart(at: receivedAt) {
            clearIdlePrimingExhaustion()
            extendHighFidelityWindow(until: reducer.state.startSignal?.expiresAt ?? signal.expiresAt)
            journalStartSignal(signal, receivedAt: receivedAt, wakeReason: wakeReason)
        }
        persistStateAndHandle(outputs)
        if reducer.state.phase == .candidate { requestRouteObservationIfNeeded(now: receivedAt, force: true) }
        refreshHealth()
    }

    /// Journal at most one suppression line per cooldown so the loop's death is
    /// visible without re-creating the noise it prevents.
    private func journalParkedExitSuppressed(receivedAt: Date, wakeReason: String) {
        if let last = lastParkedExitSuppressionJournalAt,
           receivedAt.timeIntervalSince(last) < configuration.startPolicy.candidateResilience.postKillParkedExitCooldownSeconds {
            return
        }
        lastParkedExitSuppressionJournalAt = receivedAt
        let remaining: Int
        if let killedAt = reducer.state.recentCandidate?.killedAt {
            remaining = max(0, Int(configuration.startPolicy.candidateResilience.postKillParkedExitCooldownSeconds - receivedAt.timeIntervalSince(killedAt)))
        } else {
            remaining = 0
        }
        journalCaptureEvent(
            date: receivedAt,
            category: "startSignal",
            message: "Parked anchor exit suppressed",
            trackingPhase: reducer.state.phase.rawValue,
            activityLevel: activityLevel.status.rawValue,
            wakeReason: wakeReason,
            detectionReason: "recent pedestrian kill, cooldown \(remaining)s remaining"
        )
    }

    /// Journal at most one still-parked SLC suppression line per high-fidelity
    /// window so a device-data pull shows the wake churn dying without
    /// re-creating the journal noise the suppression exists to prevent.
    private func journalSignificantChangeSuppressedAtAnchor(
        receivedAt: Date,
        sample: LocationSample,
        anchorDistanceMeters: Double
    ) {
        if let last = lastSlcAnchorSuppressionJournalAt,
           receivedAt.timeIntervalSince(last) < configuration.startPolicy.signalHighFidelityWindow {
            return
        }
        lastSlcAnchorSuppressionJournalAt = receivedAt
        let age = Int(max(0, receivedAt.timeIntervalSince(sample.timestamp)))
        journalCaptureEvent(
            date: receivedAt,
            category: "startSignal",
            message: "Significant change wake suppressed at parked anchor",
            trackingPhase: reducer.state.phase.rawValue,
            activityLevel: activityLevel.status.rawValue,
            wakeReason: "significantLocationChange",
            detectionReason: "dist=\(Int(anchorDistanceMeters))m acc=\(Int(sample.horizontalAccuracy))m age=\(age)s"
        )
    }

    /// Most pending rows applied on a single wake. Far above any legitimate
    /// signal fan-in (one per trigger source after the collapse); a hard stop
    /// against replay pathologies.
    private static let pendingSignalApplyCapPerWake = 6

    @discardableResult
    fileprivate func consumePendingStartSignals(wakeReason: String) -> Int {
        guard isMonitoring, let pendingStartSignalStore else { return 0 }
        let now = Date()
        var consumedCount = 0
        let pendingSignals: [PendingDriveStartSignal]
        do {
            let expiredCount = try pendingStartSignalStore.markExpired(now: now)
            if expiredCount > 0 {
                journalCaptureEvent(
                    date: now,
                    category: "startSignal",
                    message: "Expired \(expiredCount) pending drive start signal(s)",
                    wakeReason: wakeReason
                )
            }
            pendingSignals = try pendingStartSignalStore.fetchPending(at: now)
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "startSignal", message: "Failed to fetch pending drive start signals: \(error.localizedDescription)"))
            return 0
        }

        // Collapse to the newest unexpired row per trigger before touching
        // anything: N same-source rows merged into one candidate add nothing
        // beyond the newest, and replaying them all is where the 2026-07-05
        // 36-arm journal burst came from.
        var newestByTrigger: [DriveStartExternalTrigger: PendingDriveStartSignal] = [:]
        for pending in pendingSignals {
            if let existing = newestByTrigger[pending.trigger], existing.createdAt >= pending.createdAt {
                continue
            }
            newestByTrigger[pending.trigger] = pending
        }
        var superseded = 0
        for pending in pendingSignals where newestByTrigger[pending.trigger]?.id != pending.id {
            do {
                try pendingStartSignalStore.markConsumed(id: pending.id, consumedAt: now, captureID: nil)
                try pendingStartSignalStore.markResult(id: pending.id, result: "superseded", tripID: nil)
                superseded += 1
            } catch {
                diagnostics?.record(DiagnosticEvent(category: "startSignal", message: "Failed to supersede pending drive start signal: \(error.localizedDescription)"))
            }
        }
        if superseded > 0 {
            journalCaptureEvent(
                date: now,
                category: "startSignal",
                message: "Superseded \(superseded) duplicate pending drive start signal(s)",
                wakeReason: wakeReason
            )
        }

        let toApply = newestByTrigger.values.sorted { $0.createdAt < $1.createdAt }
        for pending in toApply.prefix(Self.pendingSignalApplyCapPerWake) {
            // Consume-then-apply, per row: `applyStartSignal` synchronously
            // re-enters the app layer (route observation) and bootstrap can run
            // more than once per wake — a row must be burned before it can act,
            // or a crash/throw replays every row on the next wake (the worse
            // bug). The narrow cost: a crash in the instant between mark and
            // apply drops one signal per source; motion/BT/SLC/geofence re-fire
            // within moments, so detection is delayed, not lost.
            do {
                try pendingStartSignalStore.markConsumed(
                    id: pending.id,
                    consumedAt: now,
                    captureID: reducer.state.captureID
                )
            } catch {
                diagnostics?.record(DiagnosticEvent(category: "startSignal", message: "Failed to consume pending drive start signal: \(error.localizedDescription)"))
                continue
            }
            var signal = pending.driveStartSignal
            signal.pendingSignalID = pending.id
            journalCaptureEvent(
                date: now,
                category: "startSignal",
                message: "Consumed pending drive start signal \(pending.trigger.rawValue)",
                wakeReason: wakeReason,
                sampleTimestamp: pending.createdAt,
                detectionReason: "expiresAt=\(pending.expiresAt)"
            )
            applyStartSignal(signal, receivedAt: now, wakeReason: wakeReason)
            // The row was burned pre-apply with the pre-arm captureID; refresh
            // it so diagnostics link the signal to the capture it actually fed.
            try? pendingStartSignalStore.markConsumed(
                id: pending.id,
                consumedAt: now,
                captureID: reducer.state.captureID
            )
            consumedCount += 1
        }
        let dropped = toApply.count - min(toApply.count, Self.pendingSignalApplyCapPerWake)
        if dropped > 0 {
            journalCaptureEvent(
                date: now,
                category: "startSignal",
                message: "Deferred \(dropped) pending drive start signal(s) past per-wake cap",
                wakeReason: wakeReason
            )
        }
        return consumedCount
    }

    private func markPendingSignalResult(_ result: String, tripID: UUID? = nil, clearsActiveSignal: Bool = false) {
        guard let activePendingSignalID, let pendingStartSignalStore else { return }
        do {
            try pendingStartSignalStore.markResult(id: activePendingSignalID, result: result, tripID: tripID)
            if clearsActiveSignal {
                self.activePendingSignalID = nil
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "startSignal", message: "Failed to mark pending signal result: \(error.localizedDescription)"))
        }
    }

    private func activatePendingSignal(id: UUID) {
        guard activePendingSignalID != id else { return }
        if let previousID = activePendingSignalID, let pendingStartSignalStore {
            do {
                try pendingStartSignalStore.markResult(id: previousID, result: "superseded", tripID: nil)
            } catch {
                diagnostics?.record(DiagnosticEvent(
                    category: "startSignal",
                    message: "Failed to supersede active pending signal: \(error.localizedDescription)"
                ))
            }
        }
        activePendingSignalID = id
    }

    private func requestRouteObservationIfNeeded(now: Date, force: Bool = false) {
        guard let routeObservationRequest, isMonitoring, !isRequestingRouteObservation else { return }
        if !force {
            guard reducer.state.phase == .candidate || reducer.state.phase == .recording else { return }
        }
        let minimumInterval = force ? Self.forcedRouteObservationFloor : Self.routeObservationInterval
        if let last = lastRouteObservationRequestAt, now.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastRouteObservationRequestAt = now
        // The request synchronously re-enters the runtime when the route
        // carries a seeded vehicle name (vehicleRouteObserved → start signal).
        isRequestingRouteObservation = true
        defer { isRequestingRouteObservation = false }
        routeObservationRequest()
    }

    /// Journals app-layer route observations so the next device data pull can
    /// verify the polling pathway end-to-end.
    public func journalVehicleRouteObservations(_ observations: [BluetoothDriveObservation]) {
        for observation in observations {
            let name = observation.displayName ?? "unknown device"
            diagnostics?.record(DiagnosticEvent(
                category: "bluetooth",
                message: "Recorded vehicle route observation \(name) (\(observation.source.rawValue))"
            ))
            journalCaptureEvent(
                date: observation.observedAt,
                category: "bluetooth",
                message: "Recorded vehicle route observation \(name)",
                wakeReason: observation.source.rawValue,
                detectionReason: "hash=\(observation.identifierHash.prefix(8))"
            )
        }
    }

    /// Opens/extends an ordinary wake-probe window (geofence/SLC/motion). A
    /// fresh probe is clearable on a rejected probe; extending an already-open
    /// window preserves its kind so a probe arriving mid-grace can't downgrade
    /// the grace to a clearable probe.
    private func extendHighFidelityWindow(until expiresAt: Date) {
        if let current = idleWakeHighFidelityUntil {
            idleWakeHighFidelityUntil = max(current, expiresAt)
        } else {
            idleWakeHighFidelityUntil = expiresAt
            idleWakeHighFidelityIsResumptionGrace = false
        }
    }

    /// Opens/extends the post-drive resumption grace. Unlike a wake probe this
    /// window survives the parked car's routine "No driving signal" samples so a
    /// quick return leg is captured directly rather than depending on an
    /// unreliable iOS terminated-app relaunch; it ends only at the idle-capture
    /// timeout or when a real resumption confirms.
    private func openResumptionGrace(until expiresAt: Date) {
        idleWakeHighFidelityUntil = max(idleWakeHighFidelityUntil ?? expiresAt, expiresAt)
        idleWakeHighFidelityIsResumptionGrace = true
    }

    private func journalStartSignal(
        _ signal: DriveStartSignal,
        receivedAt: Date,
        wakeReason: String
    ) {
        journalCaptureEvent(
            date: receivedAt,
            category: "startSignal",
            message: "Drive start signal \(signal.source.rawValue) confidence=\(signal.confidence.rawValue)",
            wakeReason: wakeReason,
            sampleTimestamp: signal.startedAt,
            detectionReason: "expiresAt=\(signal.expiresAt)"
        )
    }

    /// The cheap fields whose change means the checkpoint MUST be written now.
    /// User-entered pending review fields are deliberately absent: every user
    /// action reaches persistence through an unthrottled `persistStateAndHandle`
    /// call site, so the throttled 1 Hz location path is never the sole writer
    /// of a user decision.
    private struct CheckpointSignature: Equatable {
        var phase: DriveCapturePhase
        var stopDueAt: Date?
        var pausedUntil: Date?
        var pendingCompletionDraftID: UUID?
        var pendingTripID: UUID?
        var captureID: UUID
    }

    private func currentCheckpointSignature() -> CheckpointSignature {
        CheckpointSignature(
            phase: reducer.state.phase,
            stopDueAt: reducer.state.stopDueAt,
            pausedUntil: reducer.state.pausedUntil,
            pendingCompletionDraftID: reducer.state.pendingCompletionDraft?.id,
            pendingTripID: reducer.state.pendingTripID,
            captureID: reducer.state.captureID
        )
    }

    /// Writes the checkpoint. The throttled variant (1 Hz location path only)
    /// skips the write when nothing significant changed and the last write is
    /// recent: the checkpoint encodes the entire sample array, so per-fix
    /// saves cost O(n) per sample and saturated the main thread on long
    /// drives. A skipped write marks the checkpoint dirty so a warm reload
    /// flushes first; a hard kill loses at most the throttle window's tail
    /// samples, each independently persisted as a diagnostic sample and
    /// re-mined by `recoverRecentPossibleDriveCandidates` on wake.
    private func saveCheckpoint(throttled: Bool) {
        let signature = currentCheckpointSignature()
        if throttled,
           signature == lastSavedCheckpointSignature,
           let lastSave = lastCheckpointSaveAt,
           Date().timeIntervalSince(lastSave) < checkpointSaveThrottleInterval {
            checkpointDirty = true
            return
        }
        do {
            try activeDriveStore.save(reducer.state)
            lastSavedCheckpointSignature = signature
            lastCheckpointSaveAt = Date()
            checkpointDirty = false
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Failed to save active drive checkpoint: \(error.localizedDescription)"))
        }
    }

    private func persistStateAndHandle(
        _ outputs: [DriveCaptureOutput],
        throttlesCheckpointSave: Bool = false
    ) {
        saveCheckpoint(throttled: throttlesCheckpointSave)

        for output in outputs {
            record(output)
            onOutput?(output)
        }
        clearIdleHighFidelityAfterRejectedProbe(outputs)
        completePendingDraftIfNeeded()
        scheduleStopDeadlineIfNeeded()
        applyCapturePolicy()
        emitActiveDriveIfChanged()
    }

    private func clearIdleHighFidelityAfterRejectedProbe(_ outputs: [DriveCaptureOutput]) {
        guard idleWakeHighFidelityUntil != nil, reducer.state.phase == .idle else { return }
        // The post-drive resumption grace deliberately rides through the parked
        // car's "No driving signal" samples; only an ordinary wake probe is
        // abandoned early when the wake turns out not to be a drive.
        guard !idleWakeHighFidelityIsResumptionGrace else { return }
        let rejectedProbe = outputs.contains { output in
            guard case .ignored(let reason) = output else { return false }
            return reason.localizedCaseInsensitiveContains("no driving signal")
                || reason.localizedCaseInsensitiveContains("unconfirmed candidate timed out")
        }
        guard rejectedProbe else { return }
        idleWakeHighFidelityUntil = nil
        cancelIdleCaptureTimeout()
    }

    private func completePendingDraftIfNeeded() {
        guard let draft = reducer.state.pendingCompletionDraft else { return }
        // A draft whose save keeps throwing must not re-run the full
        // completion pipeline on every capture event; one attempt per interval
        // bounds the cost while the draft — and any user-entered
        // classification, purpose, fees, or notes it carries — stays
        // checkpointed until an attempt succeeds. A fresh draft ID always
        // attempts immediately.
        if let last = lastCompletionAttempt,
           last.draftID == draft.id,
           Date().timeIntervalSince(last.at) < completionRetryMinimumInterval {
            return
        }
        lastCompletionAttempt = (draftID: draft.id, at: Date())
        do {
            // No extra checkpoint save here: every call site is inside — or
            // immediately follows — a `persistStateAndHandle` that just saved
            // this exact state (a newly materialized draft always changes the
            // checkpoint signature, so even the throttled path force-saves it).
            let outcome = try completionCoordinator.complete(draft, monitoringSessionID: monitoringSessionID)
            switch outcome {
            case .saved:
                _ = reducer.apply(.completionSaved(draft.id))
            case .discardedAutomaticCapture:
                _ = reducer.apply(.completionDiscarded(draft.id))
            }
            try completionCoordinator.clearActiveStateIfIdle(reducer.state)
            emitActiveDriveIfChanged()
            switch outcome {
            case .discardedAutomaticCapture(let source, let reason):
                let kind: String
                switch source {
                case .autoShortTrip: kind = "confined post-parking capture"
                case .autoTransit: kind = "transit capture"
                case .autoAircraft: kind = "aircraft capture"
                case .autoCycling: kind = "cycling capture"
                case .autoWater: kind = "water capture"
                }
                diagnostics?.record(DiagnosticEvent(
                    category: "detection",
                    message: "Discarded automatic \(kind): \(reason)"
                ))
                journalCaptureEvent(
                    category: "detection",
                    message: "Discarded automatic \(kind)",
                    detectionReason: reason
                )
                markPendingSignalResult("\(kind) discarded", clearsActiveSignal: true)
            case .saved(let result):
                health.lastCapturedTrip = draft.endDate
                diagnostics?.record(DiagnosticEvent(
                    category: "detection",
                    message: "Saved automatic trip \(result.trip.id) ending \(draft.endDate)"
                ))
                if let activePendingSignalID {
                    try? pendingStartSignalStore?.markResult(
                        id: activePendingSignalID,
                        result: "trip saved",
                        tripID: result.trip.id
                    )
                    self.activePendingSignalID = nil
                }
                onTripCompleted?(result.trip, result.samples, result.conflictingVehicleIDs)
            }
            applyCapturePolicy()
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "detection", message: "Automatic trip completion failed: \(error.localizedDescription)"))
        }
    }

    private func scheduleStopDeadlineIfNeeded() {
        stopDeadlineTask?.cancel()
        stopDeadlineTask = nil
        guard isMonitoring else {
            return
        }
        let candidateDeadline = reducer.state.phase == .candidate
            ? reducer.state.startSignal?.expiresAt
            : nil
        // Phase-gate the stop deadline exactly like the candidate deadline:
        // `finalizeIfDue` can only complete a due deadline while `.recording`,
        // so arming one in any other phase (a legacy checkpoint that paused
        // with a deadline still set) fires a timer whose reducer pass makes no
        // progress and re-arms at zero delay — a main-actor spin loop.
        let stopDeadline = reducer.state.phase == .recording ? reducer.state.stopDueAt : nil
        let deadlines = [stopDeadline, candidateDeadline].compactMap { $0 }
        guard let deadline = deadlines.min() else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        stopDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await MainActor.run {
                // A cancelled sleep throws immediately; without these guards the
                // timer fires anyway and persistStateAndHandle reschedules it,
                // producing a perpetual fire/cancel/save loop. Cancellation only
                // happens on the main actor, so checking here is race-free even
                // when it lands between sleep-end and this continuation running.
                guard let self, !Task.isCancelled else { return }
                self.stopDeadlineTask = nil
                self.finalizeCaptureIfDue(now: Date())
            }
        }
    }

    private func loadActiveState(wakeReason: String? = nil) {
        // A warm reload replaces the reducer state wholesale from disk. When
        // the throttle has skipped recent 1 Hz saves, disk is behind the live
        // reducer — flush first or the reload silently rolls the in-flight
        // drive back by up to the throttle window.
        if checkpointDirty {
            saveCheckpoint(throttled: false)
        }
        do {
            if var state = try activeDriveStore.load() {
                state.configuration = configuration
                // The setting is authoritative even if a prior process saved a
                // checkpoint before the preference changed.
                state.automaticTripStartMode = automaticTripStartMode
                reducer.replaceState(state)
                emitActiveDriveIfChanged()
                diagnostics?.record(DiagnosticEvent(category: "tracking", message: try activeDriveStore.describeForDiagnostics()))
            } else {
                journalCaptureEvent(
                    category: "tracking",
                    message: "Active drive checkpoint load returned no row",
                    wakeReason: wakeReason
                )
            }
        } catch {
            let description = error.localizedDescription
            diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Failed to load active drive checkpoint: \(description)"))
            journalCaptureEvent(
                category: "tracking",
                message: "Failed to load active drive checkpoint",
                wakeReason: wakeReason,
                detectionReason: description
            )
        }
        refreshAutomaticStartEligibility()
    }

    private func emitActiveDriveIfChanged() {
        let summary = reducer.state.currentDriveSummary()
        guard summary != lastEmittedActiveDrive else { return }
        lastEmittedActiveDrive = summary
        onActiveDriveChanged?(summary)
    }

    private func recordBackgroundWake(at date: Date, wakeReason: String) {
        sceneIsBackgrounded = true
        health.lastBackgroundWake = date
        // Background wakes arrive several times per second while driving;
        // journal at most one per interval (state updates stay unconditional).
        if lastBackgroundWakeJournalAt.map({ date.timeIntervalSince($0) >= Self.backgroundWakeJournalInterval }) ?? true {
            lastBackgroundWakeJournalAt = date
            diagnostics?.record(DiagnosticEvent(category: "lifecycle", message: "Location background wake"))
            journalCaptureEvent(date: date, category: "lifecycle", message: "Location background wake", wakeReason: wakeReason)
        }
    }

    private func recordWakeBootstrapPolicyApplied(reason: DriveCaptureWakeReason) {
        recordWakeBootstrapEvent(
            "Wake bootstrap capture policy applied",
            reason: reason,
            detectionReason: [
                "activity=\(activityLevel.status.rawValue)",
                "phase=\(reducer.state.phase.rawValue)",
                "serviceSessionActive=\(locationServiceSessionProvider.isActive)",
                "serviceSessionGen=\(serviceSessionGeneration) serviceSessionAge=\(serviceSessionAgeString(now: Date()))",
                "liveGPSActive=\(locationProvider.isActive)",
                "backgroundActivityActive=\(backgroundActivitySessionProvider.isActive)",
                "backgroundWakeActive=\(backgroundWakeProvider.isMonitoring)",
                "monitorActive=\(idleWakeProvider.isMonitoring) monitorConsuming=\(idleWakeProvider.isConsumingEvents)"
            ].joined(separator: " ")
        )
    }

    private func recordWakeBootstrapStateLoaded(reason: DriveCaptureWakeReason) {
        recordWakeBootstrapEvent(
            "Wake bootstrap state loaded",
            reason: reason,
            detectionReason: [
                "phase=\(reducer.state.phase.rawValue)",
                "parkedAnchor=\(reducer.state.parkedStartAnchor != nil)",
                "paused=\(reducer.state.pausedUntil != nil)"
            ].joined(separator: " ")
        )
    }

    private func recordWakeBootstrapCompleted(
        reason: DriveCaptureWakeReason,
        startedAt: Date
    ) {
        let duration = Date().timeIntervalSince(startedAt)
        recordWakeBootstrapEvent(
            "Wake bootstrap completed",
            reason: reason,
            detectionReason: String(format: "duration=%.3f", duration)
        )
    }

    private func recordWakeBootstrapEvent(
        _ message: String,
        reason: DriveCaptureWakeReason,
        detectionReason: String? = nil
    ) {
        diagnostics?.record(DiagnosticEvent(category: "wakeBootstrap", message: message))
        journalCaptureEvent(
            category: "wakeBootstrap",
            message: message,
            wakeReason: reason.rawValue,
            detectionReason: detectionReason
        )
    }

    private func startTemporaryPermissionServiceSession() {
        let now = Date()
        permissionServiceSessionLeaseUntil = now.addingTimeInterval(permissionServiceSessionLease)
        startLocationServiceSession(reason: "permissionRequest")
        permissionServiceSessionLeaseTask?.cancel()
        permissionServiceSessionLeaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.permissionServiceSessionLease ?? Self.defaultPermissionServiceSessionLease))
            } catch {
                return
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.permissionServiceSessionLeaseTask = nil
                self.permissionServiceSessionLeaseUntil = nil
                self.updateLocationServiceSession(for: self.activityLevel, reason: "permissionLeaseExpired")
            }
        }
    }

    private func locationServiceSessionRequired(for level: DriveCaptureActivityLevel) -> Bool {
        switch level {
        case .idlePriming, .idleWake, .candidate, .recording, .parking:
            true
        case .stopped, .paused, .idleAnchored, .idleDormant:
            false
        }
    }

    private func hasActivePermissionServiceSessionLease(now: Date = Date()) -> Bool {
        guard let permissionServiceSessionLeaseUntil else { return false }
        if permissionServiceSessionLeaseUntil > now {
            return true
        }
        self.permissionServiceSessionLeaseUntil = nil
        return false
    }

    /// Holds the `.always` `CLServiceSession` only for the levels that actually
    /// need it — the drive-active and idle-wake levels (`locationServiceSession
    /// Required`), plus the brief permission-request lease — and releases it once
    /// the level drops to `.idleAnchored`/`.idleDormant`. The session is a
    /// full-accuracy always assertion that lights the location indicator on its own
    /// (independent of live GPS), so holding it while parked kept the indicator lit
    /// for the whole idle period. The post-drive resumption grace runs at
    /// `.idleWake`, so the session still stays warm for that window to cover quick
    /// inter-leg errand stops; a real drive-away wake re-establishes it synchronously
    /// (`handleIdleWake`/`handleBackgroundWake` → `.idleWake`) before GPS is consumed.
    private func updateLocationServiceSession(for level: DriveCaptureActivityLevel, reason: String) {
        if locationServiceSessionRequired(for: level) || hasActivePermissionServiceSessionLease() {
            startLocationServiceSession(reason: reason)
        } else {
            stopLocationServiceSession(reason: reason)
        }
    }

    private func startLocationServiceSession(reason: String) {
        let wasActive = locationServiceSessionProvider.isActive
        locationServiceSessionProvider.startAlways(fullAccuracyPurposeKey: Self.locationServiceSessionPurposeKey)
        guard !wasActive, locationServiceSessionProvider.isActive else { return }
        serviceSessionGeneration += 1
        serviceSessionStartedAt = Date()
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Location service session started"))
        journalCaptureEvent(
            category: "tracking",
            message: "Location service session started",
            activityLevel: activityLevel.status.rawValue,
            wakeReason: reason,
            detectionReason: "gen=\(serviceSessionGeneration)"
        )
    }

    private func stopLocationServiceSession(reason: String) {
        guard locationServiceSessionProvider.isActive else { return }
        locationServiceSessionProvider.stop()
        serviceSessionStartedAt = nil
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Location service session stopped"))
        journalCaptureEvent(
            category: "tracking",
            message: "Location service session stopped",
            activityLevel: activityLevel.status.rawValue,
            wakeReason: reason
        )
    }

    /// Age of the live `CLServiceSession` in whole seconds, or "n/a" if none.
    private func serviceSessionAgeString(now: Date) -> String {
        guard let startedAt = serviceSessionStartedAt else { return "n/a" }
        return "\(Int(max(0, now.timeIntervalSince(startedAt))))s"
    }

    /// Live-GPS configuration for each capture activity level. Single source of
    /// truth so the service-session recovery path restarts the stream with the
    /// same configuration `applyCapturePolicy` uses. `nil` = no live GPS here.
    private func liveConfiguration(for level: DriveCaptureActivityLevel) -> DriveLocationLiveConfiguration? {
        switch level {
        case .idlePriming:
            return .default
        case .idleWake, .candidate, .recording, .parking:
            return .automotiveNavigation
        case .stopped, .paused, .idleAnchored, .idleDormant:
            return nil
        }
    }

    private func startLiveLocation(for level: DriveCaptureActivityLevel) {
        guard let configuration = liveConfiguration(for: level) else { return }
        if !locationProvider.isActive {
            liveLocationStartedAt = Date()
            serviceSessionRequiredSinceLastSample = false
        }
        locationProvider.start(configuration: configuration)
    }

    /// Session diagnostics are push-delivered by Core Location per held
    /// session. Journal transitions (not repeats), feed the stall recovery,
    /// and surface unfulfilled states to the app layer for the post-restart
    /// notice.
    private func handleServiceSessionDiagnostic(_ diagnostic: DriveServiceSessionDiagnostic) {
        guard isMonitoring else { return }
        guard diagnostic != lastServiceSessionDiagnostic else { return }
        lastServiceSessionDiagnostic = diagnostic
        journalCaptureEvent(
            category: "tracking",
            message: "Service session diagnostic",
            activityLevel: activityLevel.status.rawValue,
            wakeReason: "sessionDiagnostics",
            detectionReason: "\(diagnostic.summary) gen=\(serviceSessionGeneration) backgrounded=\(sceneIsBackgrounded)"
        )
        if diagnostic.isUnfulfilled {
            serviceSessionRequiredSinceLastSample = true
            onServiceSessionUnfulfilled?(diagnostic)
            engageLocationFallback(now: Date(), trigger: "sessionDiagnostic:\(diagnostic.summary)")
            armRestorationNoticeIfNeeded(now: Date(), diagnosticSummary: diagnostic.summary)
        } else {
            cancelRestorationNotice(reason: "diagnosticCleared")
        }
    }

    // MARK: - Classic-manager GPS fallback + restoration notice (2026-07-05 incident)

    /// Strong evidence that a real drive is underway right now. Gates both the
    /// classic-manager fallback and the restoration notice, so neither can spin
    /// up from an idle unfulfilled diagnostic.
    private func trackingRestorationEvidenceActive() -> Bool {
        guard liveConfiguration(for: activityLevel) != nil else { return false }
        switch reducer.state.phase {
        case .recording:
            return true
        case .candidate:
            return reducer.state.startSignal?.confidence == .strong
                || (bluetoothVehicleHintProvider?() ?? false)
                || powerConnected
        case .idle, .paused:
            return false
        }
    }

    private func engageLocationFallback(now: Date, trigger: String) {
        guard isMonitoring,
              !fallbackLocationProvider.isActive,
              trackingRestorationEvidenceActive(),
              let configuration = liveConfiguration(for: activityLevel) else { return }
        fallbackEngagedAt = now
        lastFallbackSampleAt = nil
        fallbackSampleCount = 0
        fallbackLocationProvider.start(configuration: configuration)
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "GPS fallback engaged"))
        journalCaptureEvent(
            date: now,
            category: "tracking",
            message: "GPS fallback engaged",
            trackingPhase: reducer.state.phase.rawValue,
            activityLevel: activityLevel.status.rawValue,
            detectionReason: "trigger=\(trigger) confidence=\(reducer.state.startSignal?.confidence.rawValue ?? "none") bt=\(bluetoothVehicleHintProvider?() ?? false) power=\(powerConnected) gen=\(serviceSessionGeneration) sessionAge=\(serviceSessionAgeString(now: now))"
        )
    }

    private func disengageLocationFallback(now: Date, reason: String) {
        guard fallbackLocationProvider.isActive else { return }
        let duration = Int(max(0, now.timeIntervalSince(fallbackEngagedAt ?? now)))
        fallbackLocationProvider.stop()
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "GPS fallback disengaged (\(reason))"))
        journalCaptureEvent(
            date: now,
            category: "tracking",
            message: "GPS fallback disengaged",
            activityLevel: activityLevel.status.rawValue,
            detectionReason: "reason=\(reason) samples=\(fallbackSampleCount) duration=\(duration)s"
        )
        fallbackEngagedAt = nil
        lastFallbackEraSessionCycleAt = nil
    }

    /// The window in which primary and fallback samples can interleave: the
    /// fallback is running, or delivered within the last few seconds.
    private func isInFallbackHandoverWindow(now: Date) -> Bool {
        if fallbackLocationProvider.isActive { return true }
        guard let lastFallbackSampleAt else { return false }
        return now.timeIntervalSince(lastFallbackSampleAt) <= 10
    }

    /// While the fallback is actively delivering, wake-driven session re-honor
    /// attempts stay bounded to one cycle per this window.
    private static let fallbackEraSessionCycleInterval: TimeInterval = 300

    static let defaultTrackingRestorationNoticeDelay: TimeInterval = 180

    private func armRestorationNoticeIfNeeded(now: Date, diagnosticSummary: String) {
        guard restorationNoticeTask == nil,
              trackingRestorationEvidenceActive() else { return }
        restorationNoticeArmedAt = now
        let delay = trackingRestorationNoticeDelay
        restorationNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.restorationNoticeTask = nil
            let armedAt = self.restorationNoticeArmedAt ?? Date()
            self.restorationNoticeArmedAt = nil
            guard self.isMonitoring,
                  self.serviceSessionRequiredSinceLastSample,
                  self.trackingRestorationEvidenceActive() else { return }
            let newestSample = max(self.lastLiveSampleAt ?? .distantPast, self.lastFallbackSampleAt ?? .distantPast)
            guard newestSample < armedAt else { return }
            let advice = DriveTrackingRestorationAdvice(
                diagnosticSummary: diagnosticSummary,
                phase: self.reducer.state.phase,
                quietForSeconds: Int(max(0, Date().timeIntervalSince(armedAt))),
                fallbackEngaged: self.fallbackLocationProvider.isActive,
                fallbackSampleCount: self.fallbackSampleCount
            )
            self.journalCaptureEvent(
                category: "tracking",
                message: "Tracking restoration notice requested",
                trackingPhase: self.reducer.state.phase.rawValue,
                activityLevel: self.activityLevel.status.rawValue,
                detectionReason: "\(diagnosticSummary) fallbackEngaged=\(advice.fallbackEngaged) fallbackSamples=\(advice.fallbackSampleCount) quiet=\(advice.quietForSeconds)s"
            )
            self.onTrackingRestorationNeeded?(advice)
        }
    }

    private func cancelRestorationNotice(reason: String) {
        guard restorationNoticeTask != nil else { return }
        restorationNoticeTask?.cancel()
        restorationNoticeTask = nil
        restorationNoticeArmedAt = nil
    }

    /// How long the live stream may stay silent past a movement-proving wake
    /// before it is treated as stalled rather than stationary-paused.
    private static let liveLocationStallThreshold: TimeInterval = 60

    /// At most this many immediate stream restarts per window; beyond that the
    /// wake-path stall recovery owns revival, so a stream Core Location kills
    /// instantly can't turn into a restart spin.
    private static let liveLocationRestartLimit = 2
    private static let liveLocationRestartWindow: TimeInterval = 30

    /// The `liveUpdates` stream died (ended or threw). Restart it immediately
    /// while the level still wants live GPS — a dead stream otherwise costs the
    /// rest of the drive segment until the next SLC/visit/geofence wake.
    private func handleLiveLocationStreamEnded(_ update: DriveLocationUpdate) {
        if update.serviceSessionRequired {
            serviceSessionRequiredSinceLastSample = true
        }
        let now = update.receivedAt
        let detail = update.diagnosticMessages.first ?? "no detail"
        guard liveConfiguration(for: activityLevel) != nil else {
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Live GPS stream ended",
                activityLevel: activityLevel.status.rawValue,
                detectionReason: "restart=notNeeded \(detail)"
            )
            return
        }
        liveLocationRestartTimes.removeAll { now.timeIntervalSince($0) > Self.liveLocationRestartWindow }
        guard liveLocationRestartTimes.count < Self.liveLocationRestartLimit else {
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Live GPS restart suppressed",
                activityLevel: activityLevel.status.rawValue,
                detectionReason: "restarts=\(liveLocationRestartTimes.count)/\(Int(Self.liveLocationRestartWindow))s — awaiting wake recovery; \(detail)"
            )
            return
        }
        liveLocationRestartTimes.append(now)
        journalCaptureEvent(
            date: now,
            category: "tracking",
            message: "Live GPS stream ended",
            activityLevel: activityLevel.status.rawValue,
            detectionReason: "restart=attempted \(detail)"
        )
        startLiveLocation(for: activityLevel)
    }

    /// A wake that proves the device moved (SLC, visit departure, or parked-
    /// anchor exit) while live GPS is nominally running but silent means the
    /// stream is stalled: either Core Location already reported
    /// `serviceSessionRequired` (2026-06-22/07-01 — a `CLServiceSession` started
    /// from a non-location background context is never fulfilled) or nothing has
    /// arrived through a stretch of real movement. The wake itself restores
    /// location eligibility, so cycle the session and the `liveUpdates` stream
    /// now instead of letting the candidate time out at samples=0 and losing the
    /// first minutes of the drive to an idle rebuild.
    private func recoverStalledLiveLocationIfNeeded(now: Date, wakeReason: String) {
        guard isMonitoring else { return }
        // A dead stream (ended and past its immediate-restart budget) is
        // revived here: the movement-proving wake is the designated owner of
        // that case, with a fresh budget for the new stream.
        if !locationProvider.isActive {
            guard liveConfiguration(for: activityLevel) != nil else { return }
            liveLocationRestartTimes.removeAll()
            startLiveLocation(for: activityLevel)
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Restarted stalled live GPS",
                activityLevel: activityLevel.status.rawValue,
                wakeReason: wakeReason,
                detectionReason: "reason=deadStream gen=\(serviceSessionGeneration)"
            )
            return
        }
        let lastProgress = max(liveLocationStartedAt ?? .distantPast, lastLiveSampleAt ?? .distantPast)
        let quietFor = now.timeIntervalSince(lastProgress)
        let sessionRejected = serviceSessionRequiredSinceLastSample
        guard sessionRejected || quietFor > Self.liveLocationStallThreshold else { return }
        // While the fallback is carrying the drive, keep re-attempting to
        // re-honor the session on wakes but bounded to one cycle per window —
        // a working fallback must not sit under a noisy cycling loop.
        let fallbackDelivering = lastFallbackSampleAt.map { now.timeIntervalSince($0) <= 60 } ?? false
        if fallbackDelivering,
           let lastCycle = lastFallbackEraSessionCycleAt,
           now.timeIntervalSince(lastCycle) < Self.fallbackEraSessionCycleInterval {
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Stall recovery skipped",
                activityLevel: activityLevel.status.rawValue,
                wakeReason: wakeReason,
                detectionReason: "reason=fallbackDelivering nextCycleIn=\(Int(Self.fallbackEraSessionCycleInterval - now.timeIntervalSince(lastCycle)))s"
            )
            return
        }
        if fallbackDelivering {
            lastFallbackEraSessionCycleAt = now
        }
        if locationServiceSessionRequired(for: activityLevel) {
            stopLocationServiceSession(reason: "liveGPSStallRecovery")
            startLocationServiceSession(reason: "liveGPSStallRecovery")
        }
        // Never invalidate the background-activity session from the background:
        // per CLBackgroundActivitySession.h a NEW session only becomes active
        // while the app is foregrounded and in direct use, but an ACTIVE one
        // (taken earlier while in use) keeps the app in-use — cycling here
        // could destroy that and replace it with one that can never activate.
        // Start-if-nil is the only safe move (2026-07-05 incident).
        if !backgroundActivitySessionProvider.isActive {
            updateBackgroundActivity(for: activityLevel)
        } else {
            journalCaptureEvent(
                date: now,
                category: "tracking",
                message: "Background activity session preserved",
                activityLevel: activityLevel.status.rawValue,
                wakeReason: wakeReason,
                detectionReason: "reason=noBackgroundInvalidation"
            )
        }
        locationProvider.stop()
        startLiveLocation(for: activityLevel)
        journalCaptureEvent(
            date: now,
            category: "tracking",
            message: "Restarted stalled live GPS",
            activityLevel: activityLevel.status.rawValue,
            wakeReason: wakeReason,
            detectionReason: "sessionRequired=\(sessionRejected) quietFor=\(Int(max(0, quietFor)))s gen=\(serviceSessionGeneration)"
        )
        if sessionRejected {
            engageLocationFallback(now: now, trigger: "stallRecovery:\(wakeReason)")
        }
    }

    private func applyCapturePolicy() {
        let desiredLevel = desiredActivityLevel(now: Date())
        guard desiredLevel != activityLevel else {
            // Idempotently re-assert parked-anchor monitoring even when the level
            // is unchanged: a warm wake must re-attach a `monitor.events` consumer
            // that ended on a lifecycle change, otherwise future exits are missed.
            if desiredLevel == .idleAnchored {
                armParkedAnchorGeofence(journal: false)
            }
            updateBackgroundWakeMonitoring(for: desiredLevel)
            if desiredLevel == .paused {
                schedulePauseResume()
            }
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
            updateBackgroundActivity(for: desiredLevel)
            scheduleIdleCaptureTimeoutIfNeeded(for: desiredLevel)
            return
        }

        setActivityLevel(desiredLevel)
        // The SLC + visit relaunch backbone is a pure function of the activity
        // level (armed for every active level incl. paused, stopped only when
        // stopped), so it is re-armed on resume/auto-resume — not just on cold
        // bootstrap.
        updateBackgroundWakeMonitoring(for: desiredLevel)
        if desiredLevel == .paused {
            schedulePauseResume()
        } else {
            cancelPauseResume()
        }
        switch desiredLevel {
        case .stopped:
            locationProvider.stop()
            disengageLocationFallback(now: Date(), reason: "levelDropped:stopped")
            cancelRestorationNotice(reason: "levelDropped")
            motionEvidenceProvider.stopLiveUpdates()
            idleWakeProvider.stopMonitoring()
            backgroundActivitySessionProvider.stop()
            cancelIdleCaptureTimeout()
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
        case .paused:
            locationProvider.stop()
            disengageLocationFallback(now: Date(), reason: "levelDropped:paused")
            cancelRestorationNotice(reason: "levelDropped")
            motionEvidenceProvider.stopLiveUpdates()
            // Suspend (not stop) so the parked-anchor beacon survives the pause
            // and the geofence re-arms on resume; a hard stop would clear it.
            disarmIdleWakeMonitoring()
            backgroundActivitySessionProvider.stop()
            cancelIdleCaptureTimeout()
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
        case .idleDormant:
            locationProvider.stop()
            disengageLocationFallback(now: Date(), reason: "levelDropped:idleDormant")
            cancelRestorationNotice(reason: "levelDropped")
            motionEvidenceProvider.startLiveUpdates()
            disarmIdleWakeMonitoring()
            backgroundActivitySessionProvider.stop()
            cancelIdleCaptureTimeout()
            journalGeofenceSkipped(reason: "noAnchor")
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
        case .idleAnchored:
            locationProvider.stop()
            disengageLocationFallback(now: Date(), reason: "levelDropped:idleAnchored")
            cancelRestorationNotice(reason: "levelDropped")
            motionEvidenceProvider.startLiveUpdates()
            backgroundActivitySessionProvider.stop()
            cancelIdleCaptureTimeout()
            armParkedAnchorGeofence(journal: true)
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
        case .idlePriming:
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
            disarmIdleWakeMonitoring()
            motionEvidenceProvider.startLiveUpdates()
            startLiveLocation(for: desiredLevel)
            updateBackgroundActivity(for: desiredLevel)
            scheduleIdleCaptureTimeoutIfNeeded(for: desiredLevel)
        case .idleWake:
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
            disarmIdleWakeMonitoring()
            startLiveLocation(for: desiredLevel)
            motionEvidenceProvider.startLiveUpdates()
            updateBackgroundActivity(for: desiredLevel)
            scheduleIdleCaptureTimeoutIfNeeded(for: desiredLevel)
        case .candidate, .recording, .parking:
            updateLocationServiceSession(for: desiredLevel, reason: "capturePolicy")
            cancelIdleCaptureTimeout()
            disarmIdleWakeMonitoring()
            startLiveLocation(for: desiredLevel)
            motionEvidenceProvider.startLiveUpdates()
            backgroundActivitySessionProvider.start()
        }
    }

    private func desiredActivityLevel(now: Date) -> DriveCaptureActivityLevel {
        guard isMonitoring else { return .stopped }
        if isPauseInEffect(now: now) {
            return .paused
        }

        switch reducer.state.phase {
        case .candidate:
            return .candidate
        case .recording:
            if reducer.state.parkingEvidence != nil || reducer.state.stopDueAt != nil {
                return .parking
            }
            return .recording
        case .idle:
            if !reducer.allowsAutomaticTripStart(at: now) {
                idleWakeHighFidelityUntil = nil
                return reducer.state.parkedStartAnchor != nil ? .idleAnchored : .idleDormant
            }
            if let until = idleWakeHighFidelityUntil, until > now {
                return .idleWake
            }
            idleWakeHighFidelityUntil = nil
            if reducer.state.parkedStartAnchor != nil {
                return .idleAnchored
            }
            return reducer.state.idlePrimingExhaustedAt == nil ? .idlePriming : .idleDormant
        case .paused:
            // Expired pause the reducer hasn't settled yet (finalizeIfDue runs
            // right after policy in a wake bootstrap): hold a wake-capable idle
            // posture instead of the `.paused` teardown, which clears the
            // beacon and disarms every channel.
            return reducer.state.parkedStartAnchor != nil ? .idleAnchored : .idleDormant
        }
    }

    /// A pause counts only until its deadline. Comparing against `now` here is
    /// what lets any wake, foreground pass, or timer end an expired pause; the
    /// stored `pausedUntil` itself is cleared by `finalizeIfDue`. A `.paused`
    /// phase with no deadline (only reachable via a damaged checkpoint) is
    /// treated as expired — better a spurious resume than an unwakeable app.
    private func isPauseInEffect(now: Date) -> Bool {
        guard let pausedUntil = reducer.state.pausedUntil else { return false }
        return pausedUntil > now
    }

    private func updateBackgroundActivity(for level: DriveCaptureActivityLevel) {
        let wasActive = backgroundActivitySessionProvider.isActive
        switch level {
        case .candidate, .recording, .parking, .idleWake:
            backgroundActivitySessionProvider.start()
        case .idlePriming where sceneIsBackgrounded:
            backgroundActivitySessionProvider.start()
        case .stopped, .paused, .idleAnchored, .idlePriming, .idleDormant:
            backgroundActivitySessionProvider.stop()
        }
        // Journal transitions only — this session's lifetime was previously
        // invisible in device pulls, which hid the 06-22 "suspended despite
        // backgroundActivityActive=true" failure until it was inferred.
        let isActive = backgroundActivitySessionProvider.isActive
        if wasActive != isActive {
            journalCaptureEvent(
                category: "tracking",
                message: isActive ? "Background activity session started" : "Background activity session stopped",
                activityLevel: level.status.rawValue,
                wakeReason: "capturePolicy"
            )
        }
    }

    private func scheduleIdleCaptureTimeoutIfNeeded(for level: DriveCaptureActivityLevel) {
        guard level == .idlePriming || level == .idleWake else {
            cancelIdleCaptureTimeout()
            return
        }
        if idleCaptureTimeoutTask != nil {
            // A timer scheduled for the other idle level must not satisfy this
            // guard — a stale priming timer would otherwise leave .idleWake
            // running high-fidelity GPS with no timeout at all.
            guard idleCaptureTimeoutLevel != level else { return }
            cancelIdleCaptureTimeout()
        }
        let duration: TimeInterval
        if level == .idleWake, let until = idleWakeHighFidelityUntil {
            duration = max(0, until.timeIntervalSinceNow)
        } else {
            duration = idlePrimingDuration
        }
        idleCaptureTimeoutLevel = level
        idleCaptureTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            await MainActor.run {
                // If cancelled, the canceller owns the handle — don't touch it.
                guard let self, !Task.isCancelled else { return }
                self.idleCaptureTimeoutTask = nil
                self.idleCaptureTimeoutLevel = nil
                guard self.activityLevel == level else {
                    // Fired after the level moved on; re-evaluate so the
                    // current level gets its own timeout scheduled.
                    self.applyCapturePolicy()
                    return
                }
                if level == .idlePriming {
                    self.markIdlePrimingExhausted(at: Date())
                }
                if level == .idleWake {
                    self.idleWakeHighFidelityUntil = nil
                }
                self.applyCapturePolicy()
            }
        }
    }

    private func cancelIdleCaptureTimeout() {
        idleCaptureTimeoutTask?.cancel()
        idleCaptureTimeoutTask = nil
        idleCaptureTimeoutLevel = nil
    }

    private func clearIdlePrimingExhaustion() {
        guard reducer.state.idlePrimingExhaustedAt != nil else { return }
        var state = reducer.state
        state.idlePrimingExhaustedAt = nil
        reducer.replaceState(state)
    }

    private func markIdlePrimingExhausted(at date: Date) {
        var state = reducer.state
        state.idlePrimingExhaustedAt = date
        reducer.replaceState(state)
        diagnostics?.record(DiagnosticEvent(
            category: "tracking",
            message: "Waiting for parked anchor; vehicle, motion, and external triggers remain active"
        ))
        journalCaptureEvent(
            date: date,
            category: "tracking",
            message: "Waiting for parked anchor after priming",
            activityLevel: activityLevel.status.rawValue
        )
        do {
            try activeDriveStore.save(state)
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Failed to save idle priming checkpoint: \(error.localizedDescription)"))
        }
    }

    private func setActivityLevel(_ level: DriveCaptureActivityLevel) {
        guard activityLevel != level else { return }
        activityLevel = level
        onActivityStatusChanged?(level.status)
        diagnostics?.record(DiagnosticEvent(category: "tracking", message: "Capture activity \(level.status.rawValue)"))
        journalCaptureEvent(category: "tracking", message: "Capture activity \(level.status.rawValue)", activityLevel: level.status.rawValue)
    }

    private func record(_ output: DriveCaptureOutput) {
        switch output {
        case .candidateStarted(let date):
            let signal = reducer.state.startSignal
            let suffix = signal.map { " via \($0.source.rawValue) confidence=\($0.confidence.rawValue)" } ?? ""
            diagnostics?.record(DiagnosticEvent(category: "detection", message: "Drive candidate started at \(date)\(suffix)"))
            markPendingSignalResult("candidate armed")
            // Journal at the wall clock, not the (possibly inherited/backdated)
            // candidate start — the 2026-07-05 log stamped 36 arms into one
            // second because churn re-arms all carried the original wake's
            // startedAt. `sampleTimestamp` keeps the armed-at instant.
            // Identical-source repeats inside the window are counted, not
            // journaled.
            let now = Date()
            if let last = lastCandidateStartedJournal,
               last.source == signal?.source.rawValue,
               now.timeIntervalSince(last.at) < Self.candidateStartedJournalInterval {
                suppressedCandidateStartedRepeats += 1
            } else {
                let suppressedSuffix = suppressedCandidateStartedRepeats > 0
                    ? " suppressedRepeats=\(suppressedCandidateStartedRepeats)"
                    : ""
                suppressedCandidateStartedRepeats = 0
                lastCandidateStartedJournal = (signal?.source.rawValue, now)
                journalCaptureEvent(
                    date: now,
                    category: "detection",
                    message: "Drive candidate started\(suffix)",
                    wakeReason: signal?.source.rawValue,
                    sampleTimestamp: date,
                    detectionOutput: output.diagnosticOutput,
                    detectionReason: "armedAt=\(date)\(suppressedSuffix)"
                )
            }
        case .tripStarted(let date):
            diagnostics?.record(DiagnosticEvent(category: "detection", message: "Drive recording started at \(date)"))
            markPendingSignalResult("recording started")
            // Location journal rows aggregate every output a sample produced,
            // so a row can read "tripStarted, tripUpdated" without this start
            // date; the explicit timestamps disambiguate analysis later.
            journalCaptureEvent(
                date: date,
                category: "detection",
                message: "Drive recording started",
                sampleTimestamp: date,
                detectionOutput: output.diagnosticOutput,
                detectionReason: "startedAt=\(date)"
            )
        case .tripCompleted(let draft):
            diagnostics?.record(DiagnosticEvent(
                category: "detection",
                message: "Drive ended at \(draft.endDate) with \(draft.samples.count) samples, \(draft.distanceMeters) m"
            ))
            journalCaptureEvent(
                date: draft.endDate,
                category: "detection",
                message: "Drive ended with \(draft.samples.count) samples",
                tripID: draft.id,
                detectionOutput: output.diagnosticOutput
            )
            // Hold the app alive briefly so a quick resumption (errand stop +
            // return) is captured directly instead of relying on an iOS
            // terminated-app relaunch. Anchored to now (when the stop deadline
            // finalizes), not draft.endDate, which is the earlier inferred stop
            // moment; the window must outlast the disconnect→complete delay to
            // cover a return that starts a couple minutes later.
            if postDriveResumptionGraceDuration > 0 {
                openResumptionGrace(until: Date().addingTimeInterval(postDriveResumptionGraceDuration))
            }
        case .ignored(let reason):
            diagnostics?.record(DiagnosticEvent(category: "detection", message: reason))
            if activePendingSignalID != nil,
               reason.localizedCaseInsensitiveContains("timed out")
                    || reason.localizedCaseInsensitiveContains("no driving signal") {
                markPendingSignalResult(reason, clearsActiveSignal: true)
            }
            journalCaptureEvent(category: "detection", message: reason, detectionOutput: output.diagnosticOutput, detectionReason: reason)
        case .stopDeadlineChanged(let date):
            if let date {
                diagnostics?.record(DiagnosticEvent(category: "detection", message: "Drive stop deadline set to \(date)"))
                journalCaptureEvent(date: date, category: "detection", message: "Drive stop deadline set", detectionOutput: output.diagnosticOutput)
            } else {
                diagnostics?.record(DiagnosticEvent(category: "detection", message: "Drive stop deadline cleared"))
                journalCaptureEvent(category: "detection", message: "Drive stop deadline cleared", detectionOutput: output.diagnosticOutput)
            }
        case .parkingCandidateChanged(let evidence):
            if let evidence {
                diagnostics?.record(DiagnosticEvent(
                    category: "detection",
                    message: "Parking candidate \(evidence.signal.rawValue) source=\(evidence.source?.rawValue ?? "none") inferredEndAt=\(evidence.inferredEndAt) cancel=\(evidence.cancelReason ?? "none")"
                ))
                journalCaptureEvent(
                    date: evidence.signalAt,
                    category: "detection",
                    message: "Parking candidate \(evidence.signal.rawValue)",
                    detectionOutput: output.diagnosticOutput
                )
            } else {
                diagnostics?.record(DiagnosticEvent(category: "detection", message: "Parking candidate cleared"))
                journalCaptureEvent(category: "detection", message: "Parking candidate cleared", detectionOutput: output.diagnosticOutput)
            }
        case .tripUpdated, .paused, .checkpointChanged:
            break
        }
    }

    private func detectionContext(now: Date = Date()) -> TripDetectionContext {
        TripDetectionContext(
            trustedBluetoothVehicleHint: bluetoothVehicleHintProvider?() ?? false,
            powerConnected: powerConnected,
            recentPowerConnected: isRecentlyConnected(now: now),
            recentPowerDisconnected: isRecentlyDisconnected(now: now)
        )
    }

    private func persistDiagnosticSample(
        _ sample: LocationSample,
        receivedAt: Date,
        phase: DriveCapturePhase,
        context: TripDetectionContext,
        acceptedForDetection: Bool,
        outputs: [DriveCaptureOutput]
    ) {
        guard let diagnosticSampleStore else { return }
        let expiresAt = Calendar.current.date(
            byAdding: .day,
            value: diagnosticsMode.sampleRetentionDays,
            to: receivedAt
        ) ?? receivedAt.addingTimeInterval(Double(diagnosticsMode.sampleRetentionDays) * 24 * 60 * 60)
        let diagnosticSample = DiagnosticLocationSample(
            monitoringSessionID: monitoringSessionID,
            receivedAt: receivedAt,
            sample: sample,
            trackingPhase: phase.rawValue,
            powerConnected: context.powerConnected,
            recentPowerConnected: context.recentPowerConnected,
            recentPowerDisconnected: context.recentPowerDisconnected,
            trustedBluetoothVehicleHint: context.trustedBluetoothVehicleHint,
            acceptedForDetection: acceptedForDetection,
            detectionOutput: outputs.map(\.diagnosticOutput).joined(separator: ", "),
            detectionReason: outputs.compactMap { output in
                if case .ignored(let reason) = output {
                    return reason
                }
                return nil
            }.joined(separator: " | "),
            expiresAt: expiresAt
        )
        do {
            try diagnosticSampleStore.save(diagnosticSample)
            journalCaptureEvent(
                date: receivedAt,
                category: "location",
                message: acceptedForDetection ? "Accepted location sample" : "Stale location sample",
                context: context,
                trackingPhase: phase.rawValue,
                sampleTimestamp: sample.timestamp,
                staleDelaySeconds: max(0, receivedAt.timeIntervalSince(sample.timestamp)),
                detectionOutput: diagnosticSample.detectionOutput,
                detectionReason: diagnosticSample.detectionReason
            )
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Failed to save diagnostic sample: \(error.localizedDescription)"))
        }
    }

    private func purgeExpiredDiagnosticSamples() {
        guard let diagnosticSampleStore else { return }
        do {
            let count = try diagnosticSampleStore.purgeExpiredSamples(now: Date())
            if count > 0 {
                diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Purged \(count) expired diagnostic samples"))
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Failed to purge diagnostic samples: \(error.localizedDescription)"))
        }
    }

    private func purgeExpiredCaptureEvents() {
        do {
            if let count = try captureEventStore?.purgeExpiredEvents(now: Date()), count > 0 {
                diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Purged \(count) expired capture events"))
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Failed to purge capture events: \(error.localizedDescription)"))
        }
    }

    private func journalPossibleDriveCandidatesIfNeeded(
        around sampleDate: Date,
        receivedAt: Date,
        outputs: [DriveCaptureOutput]
    ) {
        guard let diagnosticSampleStore else { return }
        extendPendingPossibleDriveRecoveries(with: sampleDate)
        // A full analyzer pass plus sample refetch on EVERY location sample
        // produced 26.5k journal events in 4 days. Run it only when this
        // sample actually deferred or timed out a candidate — the moments a
        // recovery candidate can appear — or on a 60 s heartbeat.
        let deferredOrTimedOut = outputs.contains { output in
            if case .ignored(let reason) = output {
                return reason.contains(DriveCandidateDeferralReason.diagnosticPrefix)
                    || reason.contains("Unconfirmed candidate timed out")
            }
            return false
        }
        if !deferredOrTimedOut,
           let last = lastPossibleDriveJournalAt,
           receivedAt.timeIntervalSince(last) < Self.possibleDriveJournalInterval {
            return
        }
        lastPossibleDriveJournalAt = receivedAt
        let lowerBound = sampleDate.addingTimeInterval(-DiagnosticDriveAnalyzer.burstGap)
        let upperBound = sampleDate.addingTimeInterval(DiagnosticDriveAnalyzer.burstGap)
        do {
            let samples = try diagnosticSampleStore.fetchSamples(since: lowerBound, until: upperBound)
            let candidates = DiagnosticDriveAnalyzer.possibleDriveCandidates(from: samples)
            for candidate in candidates {
                // Candidate IDs are deterministic per burst, so each one is
                // journaled once per monitoring session, not once per sample.
                guard !journaledRecoveryCandidateIDs.contains(candidate.id) else { continue }
                if journaledRecoveryCandidateIDs.count >= Self.journaledRecoveryCandidateCap {
                    journaledRecoveryCandidateIDs.removeAll()
                }
                journaledRecoveryCandidateIDs.insert(candidate.id)
                diagnostics?.record(DiagnosticEvent(
                    category: "recovery",
                    message: "Retained possible drive candidate \(candidate.id) from diagnostic samples"
                ))
                journalCaptureEvent(
                    date: receivedAt,
                    category: "recovery",
                    message: "Retained possible drive candidate from diagnostic samples",
                    detectionReason: candidate.reasons.joined(separator: " | ")
                )
            }
            for draft in DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples) {
                schedulePossibleDriveRecovery(draft)
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "recovery", message: "Possible drive diagnostics failed: \(error.localizedDescription)"))
        }
    }

    private func recoverRecentPossibleDriveCandidates(now: Date = Date()) {
        guard automaticTripStartMode != .bluetoothOrCarPlay else { return }
        guard let diagnosticSampleStore else { return }
        if let lastPossibleDriveRecoveryScanAt,
           now.timeIntervalSince(lastPossibleDriveRecoveryScanAt) < Self.possibleDriveRecoveryScanInterval {
            return
        }
        lastPossibleDriveRecoveryScanAt = now
        do {
            let samples = try diagnosticSampleStore.fetchSamples(
                since: now.addingTimeInterval(-Self.possibleDriveRecoveryLookback),
                until: now
            )
            for draft in DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples) {
                if now.timeIntervalSince(draft.draft.endDate) >= possibleDriveRecoveryQuietPeriodDuration {
                    materializePossibleDriveRecovery(draft)
                } else {
                    schedulePossibleDriveRecovery(draft)
                }
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(
                category: "recovery",
                message: "Recent possible-drive recovery failed: \(error.localizedDescription)"
            ))
        }
    }

    private func schedulePossibleDriveRecovery(_ recovery: PossibleDriveTripDraft) {
        guard automaticTripStartMode != .bluetoothOrCarPlay else { return }
        let id = recovery.candidate.id
        let existing = pendingPossibleDriveRecoveries[id]
        pendingPossibleDriveRecoveries[id] = PendingPossibleDriveRecovery(
            startDate: min(existing?.startDate ?? recovery.draft.startDate, recovery.draft.startDate),
            lastSampleDate: max(existing?.lastSampleDate ?? recovery.draft.endDate, recovery.draft.endDate)
        )
        reschedulePossibleDriveRecoveryTask(id: id)
    }

    private func extendPendingPossibleDriveRecoveries(with sampleDate: Date) {
        for (id, pending) in pendingPossibleDriveRecoveries {
            guard sampleDate >= pending.startDate,
                  sampleDate.timeIntervalSince(pending.lastSampleDate) <= DiagnosticDriveAnalyzer.burstGap else {
                continue
            }
            pendingPossibleDriveRecoveries[id]?.lastSampleDate = max(pending.lastSampleDate, sampleDate)
            reschedulePossibleDriveRecoveryTask(id: id)
        }
    }

    private func reschedulePossibleDriveRecoveryTask(id: UUID) {
        possibleDriveRecoveryTasks[id]?.cancel()
        let delay = possibleDriveRecoveryQuietPeriodDuration
        possibleDriveRecoveryTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.finalizePossibleDriveRecovery(id: id)
        }
    }

    private func finalizePossibleDriveRecovery(id: UUID) {
        possibleDriveRecoveryTasks[id] = nil
        guard let pending = pendingPossibleDriveRecoveries.removeValue(forKey: id),
              let diagnosticSampleStore else {
            return
        }
        do {
            let samples = try diagnosticSampleStore.fetchSamples(
                since: pending.startDate.addingTimeInterval(-1),
                until: pending.lastSampleDate.addingTimeInterval(1)
            )
            guard let recovery = DiagnosticDriveAnalyzer.strictRecoveryDrafts(from: samples)
                .first(where: { $0.candidate.id == id }) else {
                diagnostics?.record(DiagnosticEvent(
                    category: "recovery",
                    message: "Strict possible-drive recovery no longer qualified \(id)"
                ))
                return
            }
            materializePossibleDriveRecovery(recovery)
        } catch {
            diagnostics?.record(DiagnosticEvent(
                category: "recovery",
                message: "Possible-drive finalization failed: \(error.localizedDescription)"
            ))
        }
    }

    private func materializePossibleDriveRecovery(_ recovery: PossibleDriveTripDraft) {
        guard automaticTripStartMode != .bluetoothOrCarPlay else { return }
        let id = recovery.candidate.id
        possibleDriveRecoveryTasks[id]?.cancel()
        possibleDriveRecoveryTasks[id] = nil
        pendingPossibleDriveRecoveries[id] = nil
        do {
            // Backstop for the one duplicate source recovery can create: a
            // deferral burst separated from its confirmed trip by a >5-minute
            // GPS gap analyzes as its own untagged candidate. Trip
            // de-duplication was removed as a product decision, so never
            // materialize a recovery that overlaps a trip that already
            // exists. Excluding the draft's own ID keeps re-materialization
            // of the same recovered candidate an upsert.
            if try completionCoordinator.hasTripOverlapping(
                start: recovery.draft.startDate,
                end: recovery.draft.endDate,
                excluding: recovery.draft.id
            ) {
                diagnostics?.record(DiagnosticEvent(
                    category: "recovery",
                    message: "Strict possible drive skipped: overlaps an existing trip"
                ))
                return
            }
            let outcome = try completionCoordinator.complete(
                recovery.draft,
                monitoringSessionID: recovery.monitoringSessionID
            )
            switch outcome {
            case .saved(let result):
                health.lastCapturedTrip = recovery.draft.endDate
                diagnostics?.record(DiagnosticEvent(
                    category: "recovery",
                    message: "Recovered strict possible drive \(result.trip.id) for review"
                ))
                journalCaptureEvent(
                    category: "recovery",
                    message: "Recovered strict possible drive for review",
                    tripID: result.trip.id,
                    detectionReason: recovery.candidate.reasons.joined(separator: " | ")
                )
                onTripCompleted?(result.trip, result.samples, result.conflictingVehicleIDs)
            case .discardedAutomaticCapture(let source, let reason):
                diagnostics?.record(DiagnosticEvent(
                    category: "recovery",
                    message: "Strict possible drive discarded by \(source.rawValue): \(reason)"
                ))
            }
        } catch {
            diagnostics?.record(DiagnosticEvent(
                category: "recovery",
                message: "Strict possible-drive save failed: \(error.localizedDescription)"
            ))
        }
    }

    private func cancelPossibleDriveRecoveryTasks() {
        possibleDriveRecoveryTasks.values.forEach { $0.cancel() }
        possibleDriveRecoveryTasks.removeAll()
        pendingPossibleDriveRecoveries.removeAll()
    }

    /// Journaled when the parked-anchor geofence is installed on a level
    /// transition. Paired with the geofence-exit journal, this lets a device-data
    /// pull distinguish "geofence never installed" from "installed but iOS did not
    /// deliver the exit".
    /// Keeps the SLC + visit relaunch backbone armed for every active capture
    /// level, including idle-anchored. The parked-anchor region is still the
    /// precise first wake source, but SLC/visits provide the low-power fallback
    /// if the region/beacon is lost while the process is suspended. This accepts
    /// the parked background-location indicator in exchange for relaunch
    /// redundancy; live GPS and background activity remain off while parked.
    private func updateBackgroundWakeMonitoring(for level: DriveCaptureActivityLevel) {
        switch level {
        case .stopped:
            let wasArmed = backgroundWakeProvider.isMonitoring
            backgroundWakeProvider.stopMonitoring()
            guard wasArmed else { return }
            journalCaptureEvent(
                category: "tracking",
                message: "Background wake monitoring stopped (SLC + visits)",
                activityLevel: level.status.rawValue,
                wakeReason: "capturePolicy"
            )
        // `.paused` keeps SLC + visits armed (cheap, no indicator): the pause
        // must END somehow, and for a suspended/terminated app a background
        // wake reaching `finalizeIfDue` is the only path to the expiry check.
        case .paused, .idleAnchored, .idleDormant, .idlePriming, .idleWake, .candidate, .recording, .parking:
            let wasArmed = backgroundWakeProvider.isMonitoring
            backgroundWakeProvider.startMonitoring()
            guard !wasArmed else { return }
            journalCaptureEvent(
                category: "tracking",
                message: "Background wake monitoring armed (SLC + visits)",
                activityLevel: level.status.rawValue,
                wakeReason: "capturePolicy"
            )
        }
    }

    /// Arms (or skips) the parked-anchor geofence with the guards classic region monitoring
    /// requires: a parked anchor must exist, and Full/Precise accuracy must be granted —
    /// region monitoring is disabled entirely under Reduced Accuracy, a plausible second
    /// cause of `idleWake = 0` the API swap alone would not surface. `journal` is true only
    /// on a level transition so idempotent re-asserts stay quiet.
    /// Tear down parked-anchor region monitoring. Preserves the non-secure beacon
    /// while the reducer's `parkedStartAnchor` is still authoritative (a live
    /// candidate, or the high-fidelity window after a wake) so an iOS
    /// suspend/terminate during that window cannot strip the cold-relaunch re-arm
    /// cache (P2b); clears it only when the anchor is genuinely gone. This keeps the
    /// on-disk beacon a faithful mirror of `parkedStartAnchor`. The reducer already
    /// clears `parkedStartAnchor` exactly when a drive truly begins
    /// (candidate→recording) and on stop, so the decision needs no extra state.
    private func disarmIdleWakeMonitoring() {
        if reducer.state.parkedStartAnchor != nil {
            idleWakeProvider.suspendMonitoring()
        } else {
            idleWakeProvider.stopMonitoring()
        }
    }

    private func armParkedAnchorGeofence(journal: Bool) {
        guard let anchor = reducer.state.parkedStartAnchor else {
            idleWakeProvider.stopMonitoring()
            if journal { journalGeofenceSkipped(reason: "noAnchor") }
            return
        }
        guard healthStatusProvider.preciseLocationEnabled else {
            if journal { journalGeofenceSkipped(reason: "reducedAccuracy") }
            return
        }
        idleWakeProvider.startMonitoring(anchor: anchor)
        if journal { journalGeofenceArmed(anchor: anchor) }
    }

    private func journalGeofenceArmed(anchor: LocationSample) {
        journalCaptureEvent(
            category: "tracking",
            message: "Parked anchor geofence armed",
            detectionReason: "radius=\(Int(configuration.startPolicy.parkedAnchorRadiusMeters)) accuracy=\(Int(anchor.horizontalAccuracy))"
        )
    }

    private func journalGeofenceSkipped(reason: String) {
        let detail = reason == "reducedAccuracy" ? "reduced accuracy" : "no parked anchor"
        journalCaptureEvent(
            category: "tracking",
            message: "Parked anchor geofence skipped — \(detail)",
            detectionReason: reason
        )
    }

    private func journalCaptureEvent(
        date: Date = Date(),
        category: String,
        message: String,
        context: TripDetectionContext? = nil,
        trackingPhase: String? = nil,
        activityLevel: String? = nil,
        wakeReason: String? = nil,
        sampleTimestamp: Date? = nil,
        staleDelaySeconds: Double? = nil,
        tripID: UUID? = nil,
        detectionOutput: String? = nil,
        detectionReason: String? = nil
    ) {
        guard diagnosticsMode.recordsCaptureEvents, let captureEventStore else { return }
        let expiresAt = Calendar.current.date(
            byAdding: .day,
            value: DriveCaptureJournalEntry.retentionDays,
            to: date
        ) ?? date.addingTimeInterval(Double(DriveCaptureJournalEntry.retentionDays) * 24 * 60 * 60)
        let context = context ?? detectionContext(now: date)
        let entry = DriveCaptureJournalEntry(
            date: date,
            category: category,
            message: message,
            monitoringSessionID: monitoringSessionID,
            captureID: reducer.state.captureID,
            tripID: tripID ?? reducer.state.pendingTripID,
            trackingPhase: trackingPhase ?? reducer.state.phase.rawValue,
            activityLevel: activityLevel ?? self.activityLevel.status.rawValue,
            wakeReason: wakeReason,
            sampleTimestamp: sampleTimestamp,
            staleDelaySeconds: staleDelaySeconds,
            powerConnected: context.powerConnected,
            recentPowerConnected: context.recentPowerConnected,
            recentPowerDisconnected: context.recentPowerDisconnected,
            trustedBluetoothVehicleHint: context.trustedBluetoothVehicleHint,
            detectionOutput: detectionOutput,
            detectionReason: detectionReason,
            expiresAt: expiresAt
        )
        do {
            try captureEventStore.save(entry)
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "diagnostics", message: "Failed to save capture event: \(error.localizedDescription)"))
        }
    }

    private func refreshHealth(additionalIssue: String? = nil) {
        var issues: [String] = []
        if !healthStatusProvider.alwaysLocationAuthorized {
            issues.append("Allow Always location access for automatic trip capture.")
        }
        if !healthStatusProvider.preciseLocationEnabled {
            issues.append("Enable Precise Location for reliable mileage.")
        }
        if !healthStatusProvider.motionAuthorized {
            issues.append("Enable Motion & Fitness for better start and stop detection.")
        }
        if !healthStatusProvider.backgroundRefreshAvailable {
            issues.append("Enable Background App Refresh so location wakes can relaunch the app.")
        }
        if let additionalIssue {
            issues.append(additionalIssue)
        }
        health.alwaysLocationAuthorized = healthStatusProvider.alwaysLocationAuthorized
        health.preciseLocationEnabled = healthStatusProvider.preciseLocationEnabled
        health.motionAuthorized = healthStatusProvider.motionAuthorized
        health.backgroundRefreshAvailable = healthStatusProvider.backgroundRefreshAvailable
        health.issues = issues
        health.trackingPausedUntil = reducer.state.pausedUntil
        onHealthChanged?(health)
    }

    @objc private func powerStateChanged() {
        updatePowerState(recordTransition: true)
    }

    private func updatePowerState(recordTransition: Bool) {
        let wasConnected = powerConnected
        powerConnected = Self.isDevicePowerConnected()
        guard recordTransition, wasConnected != powerConnected else { return }

        let now = Date()
        let until = now.addingTimeInterval(Self.powerHintWindow)
        if powerConnected {
            recentPowerConnectedUntil = until
            diagnostics?.record(DiagnosticEvent(category: "power", message: "Power connected"))
            journalCaptureEvent(date: now, category: "power", message: "Power connected", wakeReason: "usbPower")
            vehicleConnectionChanged(active: true, source: .usbPower, at: now)
        } else {
            recentPowerDisconnectedUntil = until
            diagnostics?.record(DiagnosticEvent(category: "power", message: "Power disconnected"))
            journalCaptureEvent(date: now, category: "power", message: "Power disconnected", wakeReason: "usbPower")
            vehicleConnectionChanged(active: false, source: .usbPower, at: now)
        }
    }

    private func isRecentlyConnected(now: Date = Date()) -> Bool {
        recentPowerConnectedUntil.map { $0 >= now } ?? false
    }

    private func isRecentlyDisconnected(now: Date = Date()) -> Bool {
        recentPowerDisconnectedUntil.map { $0 >= now } ?? false
    }

    private static func isDevicePowerConnected() -> Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            true
        case .unplugged, .unknown:
            false
        @unknown default:
            false
        }
    }
}

private final class PendingStartSignalNotificationObserver: NSObject, @unchecked Sendable {
    weak var runtime: DriveCaptureRuntime?

    @MainActor
    init(runtime: DriveCaptureRuntime) {
        self.runtime = runtime
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pendingDriveStartSignalCreated),
            name: .pendingDriveStartSignalCreated,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func pendingDriveStartSignalCreated() {
        Task { @MainActor [weak self] in
            self?.runtime?.consumePendingStartSignals(wakeReason: "appIntentNotification")
        }
    }
}
#endif
