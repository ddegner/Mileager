import AppCoreModels
import AppCorePersistence
import DriveCaptureEngine
import Foundation

@MainActor
public protocol AutomaticTripEnrichmentStoring: AnyObject {
    func fetchAddressEnrichmentCandidates(limit: Int, now: Date) throws -> [TripEnrichmentCandidate]
    func fetchRouteEnrichmentCandidates(limit: Int, now: Date) throws -> [TripEnrichmentCandidate]
    func fetchRawSamples(tripID: UUID) throws -> [LocationSample]

    @discardableResult
    func applyAutomaticClassificationIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        rawSamples: [LocationSample],
        classification: TripClassification,
        source: TripClassificationSource
    ) throws -> TripSummary?

    @discardableResult
    func updateAutomaticEndpointIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        address: String,
        components: TripEndpointAddressComponents?
    ) throws -> TripSummary?

    @discardableResult
    func updateAutomaticRouteIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        routePolyline: String,
        distanceMeters: Double?,
        attentionReason: String?
    ) throws -> TripSummary?

    @discardableResult
    func appendAutomaticRouteAttentionReasonIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        attentionReason: String
    ) throws -> TripSummary?

    @discardableResult
    func recordEnrichmentFailure(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        category: TripEnrichmentFailureCategory,
        at: Date
    ) throws -> TripEnrichmentAttempt?

    @discardableResult
    func markEnrichmentUnavailable(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent
    ) throws -> TripSummary?
}

extension TripStore: AutomaticTripEnrichmentStoring {}

/// Runs address and route enrichment as independent serialized workers.
/// Scheduling the coordinator repeatedly is safe: an already-running worker is
/// reused, while its sibling may start immediately and make progress on its own.
@MainActor
public final class AutomaticTripEnrichmentCoordinator {
    public static let addressBatchLimit = 10
    public static let routeBatchLimit = 2

    private let store: any AutomaticTripEnrichmentStoring
    private let geocoder: any EndpointGeocoding
    private let routeResolver: any DrivingRouteResolving
    private let addressRequestTimeoutSeconds: TimeInterval
    private let routeRequestTimeoutSeconds: TimeInterval
    private let routeTotalTimeoutSeconds: TimeInterval
    private let now: @MainActor @Sendable () -> Date
    private let didApply: @MainActor @Sendable (UUID) -> Void

    private var addressWorkerTask: Task<Void, Never>?
    private var routeWorkerTask: Task<Void, Never>?
    private var addressRerunRequested = false
    private var routeRerunRequested = false
    private var addressWorkerGeneration = 0
    private var routeWorkerGeneration = 0
    private var addressSessionBudgetRemaining = AutomaticTripEnrichmentCoordinator.addressBatchLimit
    private var routeSessionBudgetRemaining = AutomaticTripEnrichmentCoordinator.routeBatchLimit

    public init(
        store: any AutomaticTripEnrichmentStoring,
        geocoder: any EndpointGeocoding = EndpointGeocoder(),
        routeResolver: any DrivingRouteResolving,
        addressRequestTimeoutSeconds: TimeInterval = 15,
        routeRequestTimeoutSeconds: TimeInterval = 15,
        routeTotalTimeoutSeconds: TimeInterval = 60,
        now: @escaping @MainActor @Sendable () -> Date = { Date() },
        didApply: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
    ) {
        self.store = store
        self.geocoder = geocoder
        self.routeResolver = routeResolver
        self.addressRequestTimeoutSeconds = addressRequestTimeoutSeconds
        self.routeRequestTimeoutSeconds = routeRequestTimeoutSeconds
        self.routeTotalTimeoutSeconds = routeTotalTimeoutSeconds
        self.now = now
        self.didApply = didApply
    }

    public var isRunning: Bool {
        addressWorkerTask != nil || routeWorkerTask != nil
    }

    /// Starts a new trigger session with fresh cumulative batch budgets.
    /// Additional schedule requests during the same session may pick up work
    /// that arrived mid-run, but can never exceed 10 address trips or two route
    /// trips in total.
    public func beginEnrichmentSession() {
        addressSessionBudgetRemaining = Self.addressBatchLimit
        routeSessionBudgetRemaining = Self.routeBatchLimit
        schedulePendingEnrichment()
    }

    public func schedulePendingEnrichment() {
        scheduleAddressEnrichment()
        scheduleRouteEnrichment()
    }

    public func scheduleAddressEnrichment() {
        if let task = addressWorkerTask, !task.isCancelled {
            addressRerunRequested = true
            return
        }
        startAddressWorker()
    }

    public func scheduleRouteEnrichment() {
        if let task = routeWorkerTask, !task.isCancelled {
            routeRerunRequested = true
            return
        }
        startRouteWorker()
    }

    public func cancel() {
        addressWorkerTask?.cancel()
        routeWorkerTask?.cancel()
    }

    /// Primarily useful to deterministic callers and tests that need to await
    /// the work started by `schedulePendingEnrichment()`.
    public func waitUntilIdle() async {
        while addressWorkerTask != nil || routeWorkerTask != nil {
            let addressTask = addressWorkerTask
            let routeTask = routeWorkerTask
            await addressTask?.value
            await routeTask?.value
        }
    }

    private func startAddressWorker() {
        addressWorkerGeneration &+= 1
        let generation = addressWorkerGeneration
        addressRerunRequested = false
        addressWorkerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                addressRerunRequested = false
                await runAddressWorker()
            } while !Task.isCancelled && addressRerunRequested

            guard addressWorkerGeneration == generation else { return }
            addressWorkerTask = nil
        }
    }

    private func startRouteWorker() {
        routeWorkerGeneration &+= 1
        let generation = routeWorkerGeneration
        routeRerunRequested = false
        routeWorkerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                routeRerunRequested = false
                await runRouteWorker()
            } while !Task.isCancelled && routeRerunRequested

            guard routeWorkerGeneration == generation else { return }
            routeWorkerTask = nil
        }
    }

    private func runAddressWorker() async {
        let limit = addressSessionBudgetRemaining
        guard !Task.isCancelled, limit > 0,
              let fetchedCandidates = try? store.fetchAddressEnrichmentCandidates(
                limit: limit,
                now: now()
              ) else { return }
        let candidates = Array(fetchedCandidates.prefix(limit))
        addressSessionBudgetRemaining = max(0, addressSessionBudgetRemaining - candidates.count)

        for candidate in candidates {
            guard !Task.isCancelled else { return }
            await enrichAddresses(for: candidate)
        }
    }

    private func enrichAddresses(for candidate: TripEnrichmentCandidate) async {
        let basis = TripAutomaticEnrichmentBasis(trip: candidate.trip)
        await attemptWaterClassification(for: candidate.trip, basis: basis)
        guard !Task.isCancelled else { return }

        let requestedEndpoints: [(TripEnrichmentComponent, Coordinate?)] = [
            (.startAddress, candidate.trip.startCoordinate),
            (.endAddress, candidate.trip.endCoordinate)
        ]

        await withTaskGroup(of: AddressResolutionOutcome.self) { group in
            for (component, coordinate) in requestedEndpoints where candidate.components.contains(component) {
                guard let coordinate else {
                    if (try? store.markEnrichmentUnavailable(
                        basis: basis,
                        component: component
                    )) != nil {
                        didApply(candidate.trip.id)
                    }
                    continue
                }

                let geocoder = self.geocoder
                let timeout = addressRequestTimeoutSeconds
                group.addTask {
                    do {
                        let endpoint = try await withTripEnrichmentTimeout(seconds: timeout) {
                            try await geocoder.endpoint(for: coordinate)
                        }
                        return .resolved(component: component, endpoint: endpoint)
                    } catch {
                        return .failed(
                            component: component,
                            category: TripEnrichmentFailureClassifier.category(for: error)
                        )
                    }
                }
            }

            // Stream results so one endpoint is committed even if its sibling
            // is still waiting on Maps or eventually times out.
            for await outcome in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                applyAddressOutcome(outcome, tripID: candidate.trip.id, basis: basis)
            }
        }
    }

    /// Water classification is opportunistic enrichment. Missing samples,
    /// ambiguous evidence, and Maps failures all abstain without changing the
    /// independent address-enrichment retry state.
    private func attemptWaterClassification(
        for trip: TripSummary,
        basis: TripAutomaticEnrichmentBasis
    ) async {
        guard Self.isUntouchedWaterClassificationCandidate(trip),
              let samples = try? store.fetchRawSamples(tripID: trip.id),
              let plan = WaterTripClassifier().probePlan(for: trip, samples: samples),
              let waterFlags = await resolveWaterFlags(for: plan.probeSamples),
              WaterTripClassifier().isWaterTrip(resolvedWaterFlags: waterFlags),
              !Task.isCancelled else {
            return
        }

        do {
            if try store.applyAutomaticClassificationIfUnchanged(
                basis: basis,
                rawSamples: samples,
                classification: .notADrive,
                source: .autoWater
            ) != nil {
                didApply(trip.id)
            }
        } catch {
            // A stale basis or persistence failure must never block endpoint
            // enrichment. The trip remains visible in Needs Review.
        }
    }

    private func resolveWaterFlags(for samples: [LocationSample]) async -> [Bool]? {
        guard samples.count == WaterTripClassifier.probeFractions.count else { return nil }
        let geocoder = self.geocoder
        let timeout = addressRequestTimeoutSeconds

        do {
            return try await withThrowingTaskGroup(of: IndexedWaterProbe.self) { group in
                for (index, sample) in samples.enumerated() {
                    let coordinate = Coordinate(
                        latitude: sample.latitude,
                        longitude: sample.longitude
                    )
                    group.addTask {
                        let endpoint = try await withTripEnrichmentTimeout(seconds: timeout) {
                            try await geocoder.endpoint(for: coordinate)
                        }
                        return IndexedWaterProbe(index: index, isWater: endpoint.isWater)
                    }
                }

                var indexedFlags = [Bool?](repeating: nil, count: samples.count)
                for try await result in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return nil
                    }
                    indexedFlags[result.index] = result.isWater
                }
                guard indexedFlags.allSatisfy({ $0 != nil }) else { return nil }
                return indexedFlags.map { $0 ?? false }
            }
        } catch {
            return nil
        }
    }

    private static func isUntouchedWaterClassificationCandidate(_ trip: TripSummary) -> Bool {
        trip.captureSource == "automatic"
            && trip.classification == nil
            && trip.classificationSource == nil
            && trip.manualDistanceOverrideMeters == nil
            && trip.vehicleAssignmentSource != .manual
            && trip.startAddressEnrichmentState != .userManaged
            && trip.endAddressEnrichmentState != .userManaged
            && trip.routeEnrichmentState != .userManaged
            && trip.businessPurpose == nil
            && trip.notes == nil
            && trip.tollsAmount == 0
            && trip.parkingAmount == 0
    }

    private func applyAddressOutcome(
        _ outcome: AddressResolutionOutcome,
        tripID: UUID,
        basis: TripAutomaticEnrichmentBasis
    ) {
        switch outcome {
        case .resolved(let component, let endpoint):
            do {
                if try store.updateAutomaticEndpointIfUnchanged(
                    basis: basis,
                    component: component,
                    address: endpoint.label,
                    components: endpoint.components
                ) != nil {
                    didApply(tripID)
                }
            } catch {
                let category = TripEnrichmentFailureClassifier.category(for: error)
                guard category != .cancelled else { return }
                _ = try? store.recordEnrichmentFailure(
                    basis: basis,
                    component: component,
                    category: category,
                    at: now()
                )
            }
        case .failed(let component, let category):
            guard category != .cancelled else { return }
            if TripEnrichmentFailureClassifier.isTerminal(category) {
                if (try? store.markEnrichmentUnavailable(basis: basis, component: component)) != nil {
                    didApply(tripID)
                }
            } else {
                _ = try? store.recordEnrichmentFailure(
                    basis: basis,
                    component: component,
                    category: category,
                    at: now()
                )
            }
        }
    }

    private func runRouteWorker() async {
        let limit = routeSessionBudgetRemaining
        guard !Task.isCancelled, limit > 0,
              let fetchedCandidates = try? store.fetchRouteEnrichmentCandidates(
                limit: limit,
                now: now()
              ) else { return }
        let candidates = Array(fetchedCandidates.prefix(limit))
        routeSessionBudgetRemaining = max(0, routeSessionBudgetRemaining - candidates.count)

        for candidate in candidates where candidate.components.contains(.route) {
            guard !Task.isCancelled else { return }
            await enrichRoute(for: candidate)
        }
    }

    private func enrichRoute(for candidate: TripEnrichmentCandidate) async {
        let basis = TripAutomaticEnrichmentBasis(trip: candidate.trip)
        guard let samples = try? store.fetchRawSamples(tripID: candidate.trip.id) else {
            return
        }
        guard samples.count >= 2 else {
            if (try? store.markEnrichmentUnavailable(
                basis: basis,
                component: .route
            )) != nil {
                didApply(candidate.trip.id)
            }
            return
        }

        let decision = await AutomaticRouteFiller(
            resolver: routeResolver,
            requestTimeoutSeconds: routeRequestTimeoutSeconds,
            totalTimeoutSeconds: routeTotalTimeoutSeconds
        ).fill(
            trip: candidate.trip,
            samples: samples.sorted { $0.timestamp < $1.timestamp }
        )
        guard !Task.isCancelled else { return }

        switch decision {
        case .filled(let result):
            do {
                let updated: TripSummary?
                if result.useFilledDistance,
                   let routePolyline = result.route.routePolyline {
                    updated = try store.updateAutomaticRouteIfUnchanged(
                        basis: basis,
                        routePolyline: routePolyline,
                        distanceMeters: result.route.distanceMeters,
                        attentionReason: nil
                    )
                } else {
                    updated = try store.appendAutomaticRouteAttentionReasonIfUnchanged(
                        basis: basis,
                        attentionReason: result.attentionReason ?? AutomaticRouteFiller.lowConfidenceAttentionReason
                    )
                }
                if updated != nil {
                    didApply(candidate.trip.id)
                }
            } catch {
                let category = TripEnrichmentFailureClassifier.category(for: error)
                guard category != .cancelled else { return }
                _ = try? store.recordEnrichmentFailure(
                    basis: basis,
                    component: .route,
                    category: category,
                    at: now()
                )
            }
        case .retryableFailure(let category, _):
            guard category != .cancelled else { return }
            _ = try? store.recordEnrichmentFailure(
                basis: basis,
                component: .route,
                category: category,
                at: now()
            )
        case .terminalSkip:
            if (try? store.markEnrichmentUnavailable(
                basis: basis,
                component: .route
            )) != nil {
                didApply(candidate.trip.id)
            }
        case .cancelled:
            break
        }
    }
}

private struct IndexedWaterProbe: Sendable {
    var index: Int
    var isWater: Bool
}

private enum AddressResolutionOutcome: Sendable {
    case resolved(
        component: TripEnrichmentComponent,
        endpoint: EndpointGeocoder.ResolvedEndpoint
    )
    case failed(
        component: TripEnrichmentComponent,
        category: TripEnrichmentFailureCategory
    )
}
