import AppCore
import Network
import SwiftUI
import UIKit

struct DriveMapMailboxContext: Equatable, Sendable {
    var scope: DriveListScope
    var sort: DriveSortOption
    var filter: TripClassificationFilter
    var vehicleFilter: TripVehicleFilter
    var primaryVehicleID: UUID?
    var searchText: String

    func order(in trips: [TripSummary]) -> [UUID] {
        DriveListDerivation(trips: trips, scope: scope, sortOption: sort, tripFilter: filter,
            vehicleFilter: vehicleFilter, primaryVehicleID: primaryVehicleID, searchText: searchText).visibleOrder
    }
}

/// One model-owned worker survives list/detail navigation. Scene registrations
/// supply real layout dimensions; no offscreen SwiftUI maps are instantiated.
@MainActor
final class DriveMapWarmingCoordinator {
    struct Context: Equatable, Sendable {
        var mailboxIDs: [UUID]
        var mailbox: DriveMapMailboxContext? = nil
        var selectedID: UUID?
        var thumbnailSize: CGFloat
        var heroWidth: CGFloat
        var displayScale: CGFloat
        var colorScheme: ColorScheme
        var isEligible: Bool
    }

    typealias Warm = (DriveCardMapSnapshotRequest, Set<String>) async throws -> Bool
    private var trips: [TripSummary] = []
    private var scenes: [UUID: Context] = [:]
    private var sceneOrder: [UUID] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failures: [String: Date] = [:]
    private let warm: Warm
    private let monitorsConnectivity: Bool
    private let delay: Duration
    private let now: () -> Date
    private var monitor: NWPathMonitor?
    private var hadNetwork = false
    private(set) var completedCount = 0

    init(delay: Duration = .milliseconds(200), monitorsConnectivity: Bool = true, now: @escaping () -> Date = Date.init,
         warm: @escaping Warm = { request, protectedKeys in
             try await DriveCardMapSnapshotRenderer.warm(request: request, protecting: protectedKeys)
         }) {
        self.monitorsConnectivity = monitorsConnectivity
        self.delay = delay
        self.now = now
        self.warm = warm
    }

    func updateTrips(_ newTrips: [TripSummary]) {
        guard trips != newTrips else { return }
        trips = newTrips
        restart()
    }

    func update(sceneID: UUID, context: Context) {
        guard scenes[sceneID] != context else { return }
        if scenes[sceneID] == nil { sceneOrder.append(sceneID) }
        scenes[sceneID] = context
        #if DEBUG
        if DriveMapWarmingDiagnostics.enabled {
            DriveMapWarmingDiagnostics.shared.context = "eligible=\(context.isEligible);trips=\(trips.count);width=\(context.heroWidth)"
        }
        #endif
        restart()
    }

    func remove(sceneID: UUID) {
        scenes[sceneID] = nil
        sceneOrder.removeAll { $0 == sceneID }
        restart()
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        trips = []
        failures = [:]
        completedCount = 0
    }

    func retryAfterConnectivityRecovery() { restart() }

    private func restart() {
        generation += 1
        task?.cancel()
        #if DEBUG
        if DriveMapWarmingDiagnostics.enabled { DriveMapWarmingDiagnostics.shared.ready = false }
        #endif
        var contexts = sceneOrder.compactMap { scenes[$0] }.filter(\.isEligible)
        for index in contexts.indices {
            if let mailbox = contexts[index].mailbox { contexts[index].mailboxIDs = mailbox.order(in: trips) }
        }
        guard !contexts.isEmpty, !trips.isEmpty else { task = nil; return }
        if monitorsConnectivity, monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let recovered = available && !self.hadNetwork
                    self.hadNetwork = available
                    if recovered { self.retryAfterConnectivityRecovery() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.daviddegner.MileageTracker.mapNetwork"))
            self.monitor = monitor
        }
        let epoch = generation
        let trips = trips
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                #if DEBUG
                if epoch == generation, DriveMapWarmingDiagnostics.enabled {
                    DriveMapWarmingDiagnostics.shared.ready = true
                }
                #endif
            }
            do {
                try await Task.sleep(for: delay)
                let lookup = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let recent = trips.sorted {
                    if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                    return $0.id.uuidString < $1.id.uuidString
                }.prefix(50).map(\.id)
                var protectedKeys = Set<String>()
                // Complete the thumbnail pass across every scene before heroes.
                for presentation in [DriveCardMapPresentation.thumbnail, .hero] {
                    for context in contexts {
                        for id in Self.candidates(context: context, recent: recent) {
                            try Task.checkCancellation()
                            guard epoch == generation else { return }
                            guard let trip = lookup[id] else { continue }
                            let request = await Task.detached(priority: .utility) {
                                Self.request(trip: trip, context: context, presentation: presentation)
                            }.value
                            try Task.checkCancellation()
                            guard let request else { continue }
                            guard !protectedKeys.contains(request.key) else { continue }
                            if let failedAt = failures[request.key], now().timeIntervalSince(failedAt) < 30 { continue }
                            do {
                                let admitted = try await warm(request, protectedKeys)
                                try Task.checkCancellation()
                                guard epoch == generation else { return }
                                if admitted {
                                    protectedKeys.insert(request.key)
                                    failures[request.key] = nil
                                    completedCount += 1
                                    #if DEBUG
                                    if presentation == .hero, DriveMapWarmingDiagnostics.enabled {
                                        DriveMapWarmingDiagnostics.shared.heroesPrepared += 1
                                    }
                                    #endif
                                } else {
                                    // Cache full: never churn higher-priority warmed maps.
                                    return
                                }
                            } catch is CancellationError { throw CancellationError() }
                            catch { failures[request.key] = now() }
                        }
                    }
                }
            } catch { /* Lifecycle cancellation is expected. */ }
        }
    }

    static func candidates(context: Context, recent: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        let selected = context.selectedID.map { [$0] } ?? []
        let neighbors = context.selectedID.map { DriveMapPrefetchPolicy.neighbors(of: $0, in: context.mailboxIDs) } ?? []
        return (selected + neighbors + context.mailboxIDs + recent).filter { seen.insert($0).inserted }
    }

    nonisolated static func request(trip: TripSummary, context: Context,
                        presentation: DriveCardMapPresentation) -> DriveCardMapSnapshotRequest? {
        if presentation == .thumbnail {
            return DriveCardMapSnapshotRenderer.request(
                for: trip, pointSize: CGSize(width: context.thumbnailSize, height: context.thumbnailSize),
                displayScale: context.displayScale, colorScheme: context.colorScheme)
        }
        guard presentation == .hero, let content = RouteMapContent(trip: trip) else { return nil }
        return DriveCardMapSnapshotRenderer.request(
            for: content, identityToken: TripHeroMapLayout.identityToken,
            pointSize: CGSize(width: context.heroWidth, height: TripHeroMapLayout.imageHeight),
            displayScale: context.displayScale, colorScheme: context.colorScheme, presentation: .hero)
    }

    /// Used by deterministic tests to await a complete pass without timing guesses.
    func waitForCurrentPass() async { await task?.value }

    deinit { task?.cancel(); monitor?.cancel() }
}

/// Kept outside ContentView's large modifier chain to bound type-checking and
/// observe only inputs relevant to map work. ScaledMetric matches DriveRow.
struct DriveMapWarmingModifier: ViewModifier {
    var mailboxIDs: [UUID]
    var mailbox: DriveMapMailboxContext?
    var selectedID: UUID?
    var compactRows: Bool
    var heroWidth: CGFloat
    @Environment(MileageAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var regularSize = DriveMapThumbnailLayout.regularSize
    @ScaledMetric(relativeTo: .subheadline) private var compactSize = DriveMapThumbnailLayout.compactSize
    @State private var sceneID = UUID()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    private var context: DriveMapWarmingCoordinator.Context {
        .init(mailboxIDs: mailboxIDs, mailbox: mailbox, selectedID: selectedID,
              thumbnailSize: dynamicTypeSize < .accessibility3 ? (compactRows ? compactSize : regularSize) : 0,
              heroWidth: heroWidth, displayScale: displayScale, colorScheme: colorScheme,
              isEligible: scenePhase == .active && model.hasLoadedInitialTrips
                && !model.isAwaitingProtectedData && !model.resetInProgress
                && model.appLock.lockState == .unlocked && !lowPower
                && thermalState != .serious && thermalState != .critical)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                #if DEBUG
                if DriveMapWarmingDiagnostics.enabled {
                    Text(DriveMapWarmingDiagnostics.shared.status)
                        .font(.system(size: 1)).frame(width: 1, height: 1)
                        .allowsHitTesting(false).accessibilityIdentifier("mapWarmingStatus")
                }
                #endif
            }
            .onChange(of: context, initial: true) { _, value in
                model.mapWarming.update(sceneID: sceneID, context: value)
            }
            .onDisappear { model.mapWarming.remove(sceneID: sceneID) }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermalState = ProcessInfo.processInfo.thermalState
            }
    }
}

enum DriveMapThumbnailLayout {
    static let regularSize: CGFloat = 70
    static let compactSize: CGFloat = 48
}

#if DEBUG
/// Opt-in UI-test evidence only; never exposed in ordinary app launches.
@MainActor @Observable
final class DriveMapWarmingDiagnostics {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--uitesting")
        && ProcessInfo.processInfo.arguments.contains("--uitesting-map-warming-probe")
    static let shared = DriveMapWarmingDiagnostics()
    var ready = false
    var context = ""
    var heroesPrepared = 0
    var heroRenders = 0
    var heroHits = 0
    var navigationHits = 0
    var status: String { "ready=\(ready);prepared=\(heroesPrepared);renders=\(heroRenders);hits=\(heroHits);navigationHits=\(navigationHits);\(context)" }
}
#endif
