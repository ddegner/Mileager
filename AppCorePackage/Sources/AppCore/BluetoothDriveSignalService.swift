#if os(iOS)
import AVFoundation
import CoreBluetooth
import Foundation
import UIKit

public enum VehicleBluetoothAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
    case restricted
    case unknown

    public static var current: Self {
        Self(CBManager.authorization)
    }

    fileprivate init(_ authorization: CBManagerAuthorization) {
        switch authorization {
        case .notDetermined:
            self = .notDetermined
        case .allowedAlways:
            self = .allowed
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .unknown
        }
    }
}

public protocol VehicleBluetoothAuthorizationRequesting: AnyObject {
    var onAuthorizationChanged: ((VehicleBluetoothAuthorizationStatus) -> Void)? { get set }
    func currentAuthorizationStatus() -> VehicleBluetoothAuthorizationStatus
    func requestAuthorization()
}

@MainActor
public final class BluetoothDriveSignalService: NSObject {
    private let store: BluetoothDriveHintStore
    private let diagnostics: DiagnosticsService?

    public private(set) var enabled: Bool
    public private(set) var authorizationStatus: VehicleBluetoothAuthorizationStatus = .notDetermined
    public private(set) var learnedHints: [BluetoothDriveHint] = []
    public private(set) var connectedHints: [BluetoothDriveHint] = []
    public var onAuthorizationChanged: ((VehicleBluetoothAuthorizationStatus) -> Void)?
    public var onHintsChanged: (([BluetoothDriveHint]) -> Void)?
    public var onConnectedHintsChanged: (([BluetoothDriveHint]) -> Void)?
    public var onVehicleRouteObserved: ((VehicleConnectionSource, Date) -> Void)?
    public var onVehicleConnectionChanged: ((Bool, VehicleConnectionSource, Date) -> Void)?
    public var onObservationsRecorded: (([BluetoothDriveObservation]) -> Void)?

    /// Minimum interval between persisted observations per device. Route
    /// refreshes between writes reuse the cached hash so `connectedHints`
    /// stays correct without Core Data churn.
    public static let observationWriteInterval: TimeInterval = 60

    private var trustedRouteActive = false
    private var trustedRouteSource: VehicleConnectionSource = .unknownTrustedRoute
    private var observationWriteCache: [String: (identifierHash: String, lastWrittenAt: Date)] = [:]
    private let bluetoothAuthorizationRequester: any VehicleBluetoothAuthorizationRequesting

    public init(
        store: BluetoothDriveHintStore,
        diagnostics: DiagnosticsService? = nil,
        enabled: Bool = false,
        authorizationRequester: (any VehicleBluetoothAuthorizationRequesting)? = nil
    ) {
        self.store = store
        self.diagnostics = diagnostics
        self.enabled = enabled
        self.bluetoothAuthorizationRequester = authorizationRequester ?? CoreBluetoothAuthorizationRequester()
        super.init()
        self.bluetoothAuthorizationRequester.onAuthorizationChanged = { [weak self] status in
            Task { @MainActor in
                self?.updateAuthorizationStatus(status)
            }
        }
        refreshHints()
        if enabled {
            startObserving()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            startObserving()
        } else {
            stopObserving()
            connectedHints = []
            onConnectedHintsChanged?(connectedHints)
            // A Settings toggle is not parking evidence. Reset bookkeeping
            // without synthesizing a hard vehicle disconnect into capture.
            resetTrustedRouteStateSilently(reason: "Vehicle Bluetooth hints disabled")
        }
    }

    private func resetTrustedRouteStateSilently(reason: String) {
        guard trustedRouteActive else { return }
        trustedRouteActive = false
        trustedRouteSource = .unknownTrustedRoute
        diagnostics?.record(DiagnosticEvent(category: "bluetooth", message: reason))
    }

    public func requestBluetoothAuthorization() {
        let currentStatus = bluetoothAuthorizationRequester.currentAuthorizationStatus()
        guard currentStatus != .denied, currentStatus != .restricted else {
            updateAuthorizationStatus(currentStatus)
            return
        }
        bluetoothAuthorizationRequester.requestAuthorization()
    }

    public func refreshBluetoothAuthorizationStatus() {
        updateAuthorizationStatus(bluetoothAuthorizationRequester.currentAuthorizationStatus())
    }

    public func trustedVehicleHintActive(now: Date = Date()) -> Bool {
        (try? store.trustedVehicleHint(now: now)) ?? false
    }

    public func refreshHints() {
        learnedHints = (try? store.fetchHints()) ?? []
        onHintsChanged?(learnedHints)
    }

    public func refreshConnectedHints(forceNotify: Bool = false) {
        guard enabled else {
            connectedHints = []
            onConnectedHintsChanged?(connectedHints)
            resetTrustedRouteStateSilently(reason: "Vehicle Bluetooth hints inactive")
            return
        }
        let currentRoute = recordCurrentAudioRoutes()
        connectedHints = currentRoute.hints
        onConnectedHintsChanged?(connectedHints)
        let now = Date()
        if currentRoute.seededVehicleName {
            diagnostics?.record(DiagnosticEvent(
                category: "bluetooth",
                message: "Seeded vehicle Bluetooth route observed"
            ))
            onVehicleRouteObserved?(currentRoute.source, now)
        }
        let trustedHints = connectedHints.filter { $0.trusted && $0.contributesDriveDetection }
        let active = !trustedHints.isEmpty
        let source = active ? currentRoute.source : trustedRouteSource
        publishTrustedRouteState(active: active, source: source, force: forceNotify)
    }

    private func updateAuthorizationStatus(_ status: VehicleBluetoothAuthorizationStatus) {
        guard authorizationStatus != status else { return }
        authorizationStatus = status
        onAuthorizationChanged?(status)
    }

    private func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        refreshConnectedHints()
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// AVAudioSession posts route changes on a secondary thread. Objective-C
    /// selector delivery does not hop to this type's MainActor automatically,
    /// so keep the thunk nonisolated and cross the actor boundary explicitly.
    @objc nonisolated private func audioRouteChanged() {
        Task { @MainActor [weak self] in
            guard let self, self.enabled else { return }
            self.refreshConnectedHints()
        }
    }

    @objc private func appDidBecomeActive() {
        guard enabled else { return }
        refreshConnectedHints()
    }

    private func publishTrustedRouteState(
        active: Bool,
        source: VehicleConnectionSource,
        force: Bool = false
    ) {
        guard force || trustedRouteActive != active || trustedRouteSource != source else { return }
        trustedRouteActive = active
        trustedRouteSource = source
        onVehicleConnectionChanged?(active, source, Date())
        diagnostics?.record(DiagnosticEvent(
            category: "bluetooth",
            message: active ? "Trusted vehicle route connected: \(source.rawValue)" : "Trusted vehicle route disconnected: \(source.rawValue)"
        ))
    }

    private func recordCurrentAudioRoutes() -> (hints: [BluetoothDriveHint], source: VehicleConnectionSource, seededVehicleName: Bool) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let now = Date()
        var observedHashes = Set<String>()
        var observedSources: [String: VehicleConnectionSource] = [:]
        var vehicleNamedHashes = Set<String>()
        var recordedObservations: [BluetoothDriveObservation] = []
        for output in outputs where output.isBluetoothLikeVehicleCandidate {
            let rawIdentifier = output.uid.isEmpty ? "\(output.portType.rawValue):\(output.portName)" : output.uid
            let connectionKind = output.vehicleConnectionKind
            let identityQuality: VehicleConnectionIdentityQuality = output.uid.isEmpty
                ? .fallbackPortName
                : .stablePortIdentifier
            // A route may expose the same UID first as Bluetooth and later as
            // CarPlay. Including kind in the write cache preserves that change
            // immediately while retaining the legacy local hash namespace.
            let cacheKey = "\(connectionKind.rawValue):\(rawIdentifier)"

            var identifierHash: String?
            if let cached = observationWriteCache[cacheKey],
               now.timeIntervalSince(cached.lastWrittenAt) < Self.observationWriteInterval {
                identifierHash = cached.identifierHash
            } else if let observation = recordObservation(
                identifier: rawIdentifier,
                displayName: output.portName,
                source: .audioRoute,
                connectionKind: connectionKind,
                identityQuality: identityQuality
            ) {
                observationWriteCache[cacheKey] = (observation.identifierHash, now)
                recordedObservations.append(observation)
                identifierHash = observation.identifierHash
            }

            if let identifierHash {
                observedHashes.insert(identifierHash)
                observedSources[identifierHash] = output.vehicleConnectionSource
                if BluetoothVehicleNameMatcher.matches(output.portName) {
                    vehicleNamedHashes.insert(identifierHash)
                }
            }
        }
        if !recordedObservations.isEmpty {
            onObservationsRecorded?(recordedObservations)
        }

        let hints = (try? store.fetchHints(matching: observedHashes)) ?? []
        // A device the user has repeatedly rejected via "Not a Drive" stops
        // seeding weak start signals, even when its name looks like a car.
        let suppressedHashes = Set(hints
            .filter { !$0.contributesDriveDetection }
            .map(\.identifierHash))
        let seededVehicleName = !vehicleNamedHashes.subtracting(suppressedHashes).isEmpty
        let trustedSource = hints
            .filter { $0.trusted && $0.contributesDriveDetection }
            .compactMap { observedSources[$0.identifierHash] }
            .sortedByParkingPriority()
            .first
        return (
            hints,
            trustedSource ?? observedSources.values.sortedByParkingPriority().first ?? .unknownTrustedRoute,
            seededVehicleName
        )
    }

    private func recordObservation(
        identifier: String,
        displayName: String?,
        source: BluetoothSignalSource,
        connectionKind: VehicleConnectionKind,
        identityQuality: VehicleConnectionIdentityQuality
    ) -> BluetoothDriveObservation? {
        do {
            let observation = try store.recordObservation(
                identifier: identifier,
                displayName: displayName,
                source: source,
                connectionKind: connectionKind,
                identityQuality: identityQuality
            )
            refreshHints()
            return observation
        } catch {
            diagnostics?.record(DiagnosticEvent(category: "bluetooth", message: error.localizedDescription))
            return nil
        }
    }
}

private extension AVAudioSessionPortDescription {
    var isBluetoothLikeVehicleCandidate: Bool {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio:
            return true
        default:
            return false
        }
    }

    var vehicleConnectionSource: VehicleConnectionSource {
        switch portType {
        case .carAudio:
            .carPlayAudio
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            .bluetoothAudio
        default:
            .unknownTrustedRoute
        }
    }

    var vehicleConnectionKind: VehicleConnectionKind {
        switch portType {
        case .carAudio:
            .carPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            .bluetooth
        default:
            .unknown
        }
    }
}

private extension Sequence where Element == VehicleConnectionSource {
    func sortedByParkingPriority() -> [VehicleConnectionSource] {
        sorted { lhs, rhs in
            lhs.parkingPriority < rhs.parkingPriority
        }
    }
}

private extension VehicleConnectionSource {
    var parkingPriority: Int {
        switch self {
        case .carPlayAudio:
            0
        case .bluetoothAudio:
            1
        case .usbPower:
            2
        case .unknownTrustedRoute:
            3
        }
    }
}

private final class CoreBluetoothAuthorizationRequester: NSObject, CBCentralManagerDelegate, VehicleBluetoothAuthorizationRequesting {
    var onAuthorizationChanged: ((VehicleBluetoothAuthorizationStatus) -> Void)?
    private var centralManager: CBCentralManager?

    func currentAuthorizationStatus() -> VehicleBluetoothAuthorizationStatus {
        .current
    }

    func requestAuthorization() {
        let authorizationStatus = VehicleBluetoothAuthorizationStatus.current
        guard authorizationStatus != .denied, authorizationStatus != .restricted else {
            onAuthorizationChanged?(authorizationStatus)
            return
        }
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onAuthorizationChanged?(.current)
    }
}
#endif
