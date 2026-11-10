import XCTest
@testable import AppCore

@MainActor
final class AutomaticTripEnrichmentCoordinatorTests: XCTestCase {
    private var nextTripOffset = 0

    func testAddressResultsAreAppliedAsTheyArriveAndPartialFailureIsRetried() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        let endGate = AsyncGate()
        let geocoder = EndpointGeocoderStub { coordinate in
            if coordinate == trip.startCoordinate {
                return .init(label: "Start label", components: nil)
            }
            await endGate.wait()
            throw EndpointGeocodingError.noResult
        }
        var appliedTripIDs: [UUID] = []
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: geocoder,
            routeResolver: RouteResolverStub.successful,
            didApply: { appliedTripIDs.append($0) }
        )

        coordinator.scheduleAddressEnrichment()
        await waitUntil { store.appliedEndpoints.count == 1 }

        XCTAssertEqual(store.appliedEndpoints.map(\.component), [.startAddress])
        XCTAssertEqual(appliedTripIDs, [trip.id])
        XCTAssertTrue(store.failures.isEmpty)

        await endGate.open()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.failures.map(\.component), [.endAddress])
        XCTAssertEqual(store.failures.map(\.category), [.serviceUnavailable])
    }

    func testCancellationDoesNotPersistFailureOrUnavailableState() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        let geocoder = EndpointGeocoderStub { _ in
            try await Task.sleep(for: .seconds(5))
            return .init(label: "Too late", components: nil)
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: geocoder,
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleAddressEnrichment()
        await Task.yield()
        coordinator.cancel()
        await coordinator.waitUntilIdle()

        XCTAssertTrue(store.appliedEndpoints.isEmpty)
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertTrue(store.unavailable.isEmpty)
    }

    func testScheduleDuringAddressRunUsesRemainingSessionBudget() async {
        let firstTrip = makeTrip()
        let secondTrip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [
            [TripEnrichmentCandidate(trip: firstTrip, components: [.startAddress])],
            [TripEnrichmentCandidate(trip: secondTrip, components: [.startAddress])]
        ]
        let firstGate = AsyncGate()
        let started = AsyncCounter()
        let geocoder = EndpointGeocoderStub { coordinate in
            await started.increment()
            if coordinate == firstTrip.startCoordinate {
                await firstGate.wait()
            }
            return .init(label: "Resolved", components: nil)
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: geocoder,
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleAddressEnrichment()
        while await started.value == 0 {
            await Task.yield()
        }
        coordinator.scheduleAddressEnrichment()
        await firstGate.open()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.addressFetchLimits, [10, 9])
        XCTAssertEqual(Set(store.appliedEndpoints.map(\.tripID)), Set([firstTrip.id, secondTrip.id]))
    }

    func testScheduleAfterCancellationStartsReplacementWithoutOldTaskClearingIt() async {
        let cancelledTrip = makeTrip()
        let replacementTrip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [
            [TripEnrichmentCandidate(trip: cancelledTrip, components: [.startAddress])],
            [TripEnrichmentCandidate(trip: replacementTrip, components: [.startAddress])]
        ]
        let started = AsyncCounter()
        let geocoder = EndpointGeocoderStub { coordinate in
            if coordinate == cancelledTrip.startCoordinate {
                await started.increment()
                try await Task.sleep(for: .seconds(5))
            }
            return .init(label: "Replacement resolved", components: nil)
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: geocoder,
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleAddressEnrichment()
        while await started.value == 0 {
            await Task.yield()
        }
        coordinator.cancel()
        coordinator.beginEnrichmentSession()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.addressFetchLimits, [10, 10])
        XCTAssertEqual(store.appliedEndpoints.map(\.tripID), [replacementTrip.id])
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testScheduleDuringRouteRunUsesRemainingSessionBudget() async {
        let firstTrip = makeTrip()
        let secondTrip = makeTrip()
        let store = CoordinatorStoreStub()
        store.routeBatches = [
            [TripEnrichmentCandidate(trip: firstTrip, components: [.route])],
            [TripEnrichmentCandidate(trip: secondTrip, components: [.route])]
        ]
        store.samplesByTripID[firstTrip.id] = routeSamples()
        store.samplesByTripID[secondTrip.id] = routeSamples()
        let firstGate = AsyncGate()
        let started = AsyncCounter()
        let resolver = RouteResolverStub { start, end in
            await started.increment()
            await firstGate.wait()
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, end]),
                distanceMeters: distance * 1.05
            )
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Unused", components: nil)
            },
            routeResolver: resolver
        )

        coordinator.scheduleRouteEnrichment()
        while await started.value == 0 {
            await Task.yield()
        }
        coordinator.scheduleRouteEnrichment()
        await firstGate.open()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.routeFetchLimits, [2, 1])
        XCTAssertEqual(Set(store.routeCompletionTripIDs), Set([firstTrip.id, secondTrip.id]))
    }

    func testAddressTimeoutRecordsTimedOutAttempt() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(trip: trip, components: [.startAddress])]]
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                try await Task.sleep(for: .seconds(5))
                return .init(label: "Too late", components: nil)
            },
            routeResolver: RouteResolverStub.successful,
            addressRequestTimeoutSeconds: 0.01
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.failures.map(\.component), [.startAddress])
        XCTAssertEqual(store.failures.map(\.category), [.timedOut])
        XCTAssertTrue(store.unavailable.isEmpty)
    }

    func testOfflineFailureBacksOffAndLaterSuccessClearsAttempt() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let store = TripStore(context: persistence.container.viewContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = routeSamples()
        let saved = try store.saveCompletedTrip(TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(360),
            samples: samples,
            distanceMeters: DistanceCalculator.routeDistanceMeters(samples: samples)
        ))
        _ = try store.markEnrichmentUnavailable(
            basis: TripAutomaticEnrichmentBasis(trip: saved),
            component: .endAddress
        )

        let clock = MutableEnrichmentClock(date: start)
        let geocoder = ConnectivityGeocoder()
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: geocoder,
            routeResolver: RouteResolverStub.successful,
            now: { clock.date }
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        let failedAttempt = try XCTUnwrap(store.fetchEnrichmentAttempt(
            tripID: saved.id,
            component: .startAddress
        ))
        XCTAssertEqual(failedAttempt.failureCategory, .networkUnavailable)
        XCTAssertEqual(failedAttempt.consecutiveFailures, 1)
        XCTAssertEqual(failedAttempt.lastAttemptAt, start)
        XCTAssertTrue(try store.fetchAddressEnrichmentCandidates(
            now: start.addingTimeInterval(5 * 60 - 1)
        ).isEmpty)
        XCTAssertEqual(
            try store.fetchAddressEnrichmentCandidates(
                now: start.addingTimeInterval(5 * 60)
            ).first?.components,
            [.startAddress]
        )

        await geocoder.restoreConnectivity()
        clock.date = start.addingTimeInterval(5 * 60)
        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        let enriched = try store.fetchTrip(id: saved.id)
        XCTAssertEqual(enriched.startAddress, "Resolved after reconnect")
        XCTAssertEqual(enriched.startAddressEnrichmentState, .complete)
        XCTAssertNil(try store.fetchEnrichmentAttempt(
            tripID: saved.id,
            component: .startAddress
        ))
    }

    func testMissingRawSamplesMarkPendingRouteUnavailable() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.routeBatches = [[TripEnrichmentCandidate(trip: trip, components: [.route])]]
        var appliedTripIDs: [UUID] = []
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Unused", components: nil)
            },
            routeResolver: RouteResolverStub.successful,
            didApply: { appliedTripIDs.append($0) }
        )

        coordinator.scheduleRouteEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.unavailable.map(\.tripID), [trip.id])
        XCTAssertEqual(store.unavailable.map(\.component), [.route])
        XCTAssertEqual(appliedTripIDs, [trip.id])
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertTrue(store.routeCompletionTripIDs.isEmpty)
    }

    func testTerminalRouteSkipMarksPendingRouteUnavailable() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.routeBatches = [[TripEnrichmentCandidate(trip: trip, components: [.route])]]
        store.samplesByTripID[trip.id] = [
            sample(
                date: trip.startDate,
                latitude: 40,
                longitude: -74,
                horizontalAccuracy: 200
            ),
            sample(
                date: trip.startDate.addingTimeInterval(120),
                latitude: 40.01,
                longitude: -73.99,
                horizontalAccuracy: 200
            )
        ]
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Unused", components: nil)
            },
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleRouteEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.unavailable.map(\.tripID), [trip.id])
        XCTAssertEqual(store.unavailable.map(\.component), [.route])
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertTrue(store.routeCompletionTripIDs.isEmpty)
    }

    func testBlockedRouteWorkerDoesNotDelayAddressWorker() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(trip: trip, components: [.startAddress])]]
        store.routeBatches = [[TripEnrichmentCandidate(trip: trip, components: [.route])]]
        store.samplesByTripID[trip.id] = routeSamples()
        let routeGate = AsyncGate()
        let resolver = RouteResolverStub { _, _ in
            await routeGate.wait()
            throw CoordinatorTestError.failed
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Resolved while route waits", components: nil)
            },
            routeResolver: resolver
        )

        coordinator.schedulePendingEnrichment()
        await waitUntil { store.appliedEndpoints.count == 1 }

        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertTrue(coordinator.isRunning)

        await routeGate.open()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.failures.map(\.component), [.route])
        XCTAssertEqual(store.failures.map(\.category), [.unknown])
    }

    func testWorkersRequestSpecifiedBatchLimits() async {
        let trips = (0 ..< 12).map { _ in makeTrip() }
        let store = CoordinatorStoreStub()
        store.addressBatches = [trips.map {
            TripEnrichmentCandidate(trip: $0, components: [.startAddress])
        }]
        store.routeBatches = [trips.map {
            TripEnrichmentCandidate(trip: $0, components: [.route])
        }]
        for trip in trips {
            store.samplesByTripID[trip.id] = routeSamples()
        }
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Resolved", components: nil)
            },
            routeResolver: RouteResolverStub.successful
        )

        coordinator.schedulePendingEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.addressFetchLimits, [10])
        XCTAssertEqual(store.routeFetchLimits, [2])
        XCTAssertEqual(store.appliedEndpoints.count, 10)
        XCTAssertEqual(store.routeCompletionTripIDs.count, 2)
    }

    func testWaterEvidenceAutomaticallyMarksNotADriveAndContinuesAddressEnrichment() async throws {
        let trip = makeTrip()
        let samples = waterCandidateSamples(for: trip, automotiveCount: 2)
        let plan = try XCTUnwrap(WaterTripClassifier().probePlan(for: trip, samples: samples))
        let probeCoordinates = plan.probeSamples.map {
            Coordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let waterCoordinates = Array(probeCoordinates.prefix(2))
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        store.samplesByTripID[trip.id] = samples
        var appliedTripIDs: [UUID] = []
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { coordinate in
                if probeCoordinates.contains(coordinate) {
                    return .init(
                        label: "Water probe",
                        components: nil,
                        isWater: waterCoordinates.contains(coordinate)
                    )
                }
                return .init(label: "Resolved endpoint", components: nil)
            },
            routeResolver: RouteResolverStub.successful,
            didApply: { appliedTripIDs.append($0) }
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(store.automaticClassifications.count, 1)
        XCTAssertEqual(store.automaticClassifications.first?.tripID, trip.id)
        XCTAssertEqual(store.automaticClassifications.first?.classification, .notADrive)
        XCTAssertEqual(store.automaticClassifications.first?.source, .autoWater)
        XCTAssertEqual(store.appliedEndpoints.count, 2)
        XCTAssertEqual(appliedTripIDs.count, 3)
    }

    func testWaterProbeFailureAbstainsWithoutBlockingAddressEnrichment() async throws {
        let trip = makeTrip()
        let samples = waterCandidateSamples(for: trip, automotiveCount: 0)
        let plan = try XCTUnwrap(WaterTripClassifier().probePlan(for: trip, samples: samples))
        let failingProbe = Coordinate(
            latitude: plan.probeSamples[1].latitude,
            longitude: plan.probeSamples[1].longitude
        )
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        store.samplesByTripID[trip.id] = samples
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { coordinate in
                if coordinate == failingProbe {
                    throw EndpointGeocodingError.noResult
                }
                return .init(label: "Resolved", components: nil, isWater: true)
            },
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertTrue(store.automaticClassifications.isEmpty)
        XCTAssertEqual(store.appliedEndpoints.count, 2)
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testAutomotiveMotionDoesNotSkipWaterProbes() async {
        // CoreMotion can label a powerboat as automotive. The three
        // mid-path map probes still decide whether the path is on water.
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        store.samplesByTripID[trip.id] = waterCandidateSamples(
            for: trip,
            automotiveCount: 9
        )
        let recorder = CoordinateRecorder()
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { coordinate in
                await recorder.append(coordinate)
                return .init(label: "Resolved", components: nil, isWater: true)
            },
            routeResolver: RouteResolverStub.successful
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        let resolvedCoordinates = await recorder.coordinates
        XCTAssertEqual(store.automaticClassifications.count, 1)
        XCTAssertEqual(store.automaticClassifications.first?.source, .autoWater)
        XCTAssertEqual(resolvedCoordinates.count, 5)
        XCTAssertTrue(resolvedCoordinates.contains(trip.startCoordinate!))
        XCTAssertTrue(resolvedCoordinates.contains(trip.endCoordinate!))
    }

    func testConcurrentClassificationRefusalDoesNotEmitWaterApplyCallback() async {
        let trip = makeTrip()
        let store = CoordinatorStoreStub()
        store.addressBatches = [[TripEnrichmentCandidate(
            trip: trip,
            components: [.startAddress, .endAddress]
        )]]
        store.samplesByTripID[trip.id] = waterCandidateSamples(for: trip, automotiveCount: 0)
        store.allowsAutomaticClassification = false
        var appliedTripIDs: [UUID] = []
        let coordinator = AutomaticTripEnrichmentCoordinator(
            store: store,
            geocoder: EndpointGeocoderStub { _ in
                .init(label: "Resolved", components: nil, isWater: true)
            },
            routeResolver: RouteResolverStub.successful,
            didApply: { appliedTripIDs.append($0) }
        )

        coordinator.scheduleAddressEnrichment()
        await coordinator.waitUntilIdle()

        XCTAssertTrue(store.automaticClassifications.isEmpty)
        XCTAssertEqual(store.appliedEndpoints.count, 2)
        XCTAssertEqual(appliedTripIDs.count, 2)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }

    private func makeTrip() -> TripSummary {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        // Make every trip's endpoints unique so gated test operations can
        // distinguish candidates without sharing mutable test state.
        let offset = Double(nextTripOffset) / 10_000
        nextTripOffset += 1
        return TripSummary(
            id: id,
            createdAt: date,
            updatedAt: date,
            captureSource: "automatic",
            startDate: date,
            endDate: date.addingTimeInterval(600),
            startCoordinate: Coordinate(latitude: 40 + offset, longitude: -74),
            endCoordinate: Coordinate(latitude: 40.015 + offset, longitude: -73.98),
            startAddress: nil,
            endAddress: nil,
            distanceMeters: 3_000,
            routePolyline: nil,
            classification: nil,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil,
            startAddressEnrichmentState: .pending,
            endAddressEnrichmentState: .pending,
            routeEnrichmentState: .pending
        )
    }

    private func routeSamples() -> [LocationSample] {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            sample(date: date, latitude: 40.000, longitude: -74.000),
            sample(date: date.addingTimeInterval(120), latitude: 40.000, longitude: -73.990),
            sample(date: date.addingTimeInterval(240), latitude: 40.010, longitude: -73.990),
            sample(date: date.addingTimeInterval(360), latitude: 40.010, longitude: -73.980)
        ]
    }

    private func waterCandidateSamples(
        for trip: TripSummary,
        automotiveCount: Int
    ) -> [LocationSample] {
        (0..<9).map { index in
            let timestamp = trip.startDate.addingTimeInterval(Double(index) * 30)
            let automotive = index < automotiveCount
            let hint: MotionHint = automotive ? .automotive : .unknown
            return LocationSample(
                timestamp: timestamp,
                latitude: 40 + Double(index) * 0.0015,
                longitude: -74,
                horizontalAccuracy: 5,
                speedMetersPerSecond: 8,
                speedAccuracyMetersPerSecond: 0.5,
                motionHint: hint,
                motionActivity: MotionActivitySnapshot(
                    startDate: timestamp,
                    confidence: .high,
                    hints: [hint]
                )
            )
        }
    }

    private func sample(
        date: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double = 5
    ) -> LocationSample {
        LocationSample(
            timestamp: date,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            speedMetersPerSecond: 10,
            speedAccuracyMetersPerSecond: 0.5,
            motionHint: .automotive
        )
    }
}

private struct EndpointGeocoderStub: EndpointGeocoding {
    let resolve: @Sendable (Coordinate) async throws -> EndpointGeocoder.ResolvedEndpoint

    init(
        resolve: @escaping @Sendable (Coordinate) async throws -> EndpointGeocoder.ResolvedEndpoint
    ) {
        self.resolve = resolve
    }

    func endpoint(for coordinate: Coordinate) async throws -> EndpointGeocoder.ResolvedEndpoint {
        try await resolve(coordinate)
    }
}

@MainActor
private final class RouteResolverStub: DrivingRouteResolving {
    static var successful: RouteResolverStub {
        RouteResolverStub { start, end in
            let distance = DistanceCalculator.distanceMeters(from: start, to: end)
            return ResolvedDrivingRoute(
                startCoordinate: start,
                endCoordinate: end,
                routePolyline: EncodedPolyline.encode([start, end]),
                distanceMeters: distance * 1.05
            )
        }
    }

    let resolve: (Coordinate, Coordinate) async throws -> ResolvedDrivingRoute

    init(resolve: @escaping (Coordinate, Coordinate) async throws -> ResolvedDrivingRoute) {
        self.resolve = resolve
    }

    func resolveDrivingRoute(start: Coordinate, end: Coordinate) async throws -> ResolvedDrivingRoute {
        try await resolve(start, end)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor CoordinateRecorder {
    private(set) var coordinates: [Coordinate] = []

    func append(_ coordinate: Coordinate) {
        coordinates.append(coordinate)
    }
}

@MainActor
private final class MutableEnrichmentClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

private actor ConnectivityGeocoder: EndpointGeocoding {
    private var isConnected = false

    func restoreConnectivity() {
        isConnected = true
    }

    func endpoint(for _: Coordinate) async throws -> EndpointGeocoder.ResolvedEndpoint {
        guard isConnected else {
            throw URLError(.notConnectedToInternet)
        }
        return .init(label: "Resolved after reconnect", components: nil)
    }
}

@MainActor
private final class CoordinatorStoreStub: AutomaticTripEnrichmentStoring {
    struct EndpointApply: Equatable {
        var tripID: UUID
        var component: TripEnrichmentComponent
        var address: String
    }

    struct Failure: Equatable {
        var tripID: UUID
        var component: TripEnrichmentComponent
        var category: TripEnrichmentFailureCategory
    }

    var addressBatches: [[TripEnrichmentCandidate]] = []
    var routeBatches: [[TripEnrichmentCandidate]] = []
    var samplesByTripID: [UUID: [LocationSample]] = [:]
    var addressFetchLimits: [Int] = []
    var routeFetchLimits: [Int] = []
    var allowsAutomaticClassification = true
    var automaticClassifications: [(tripID: UUID, classification: TripClassification, source: TripClassificationSource)] = []
    var appliedEndpoints: [EndpointApply] = []
    var routeCompletionTripIDs: [UUID] = []
    var failures: [Failure] = []
    var unavailable: [(tripID: UUID, component: TripEnrichmentComponent)] = []
    private var trips: [UUID: TripSummary] = [:]

    func fetchAddressEnrichmentCandidates(limit: Int, now _: Date) throws -> [TripEnrichmentCandidate] {
        addressFetchLimits.append(limit)
        guard !addressBatches.isEmpty else { return [] }
        let batch = Array(addressBatches.removeFirst().prefix(limit))
        batch.forEach { trips[$0.trip.id] = $0.trip }
        return batch
    }

    func fetchRouteEnrichmentCandidates(limit: Int, now _: Date) throws -> [TripEnrichmentCandidate] {
        routeFetchLimits.append(limit)
        guard !routeBatches.isEmpty else { return [] }
        let batch = Array(routeBatches.removeFirst().prefix(limit))
        batch.forEach { trips[$0.trip.id] = $0.trip }
        return batch
    }

    func fetchRawSamples(tripID: UUID) throws -> [LocationSample] {
        samplesByTripID[tripID] ?? []
    }

    func applyAutomaticClassificationIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        rawSamples: [LocationSample],
        classification: TripClassification,
        source: TripClassificationSource
    ) throws -> TripSummary? {
        guard allowsAutomaticClassification,
              var trip = trips[basis.tripID],
              samplesByTripID[basis.tripID] == rawSamples,
              trip.classification == nil else {
            return nil
        }
        trip.classification = classification
        trip.classificationSource = source
        trips[basis.tripID] = trip
        automaticClassifications.append((basis.tripID, classification, source))
        return trip
    }

    func updateAutomaticEndpointIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        address: String,
        components _: TripEndpointAddressComponents?
    ) throws -> TripSummary? {
        guard let trip = trips[basis.tripID] else { return nil }
        appliedEndpoints.append(.init(tripID: basis.tripID, component: component, address: address))
        return trip
    }

    func updateAutomaticRouteIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        routePolyline _: String,
        distanceMeters _: Double?,
        attentionReason _: String?
    ) throws -> TripSummary? {
        guard let trip = trips[basis.tripID] else { return nil }
        routeCompletionTripIDs.append(basis.tripID)
        return trip
    }

    func appendAutomaticRouteAttentionReasonIfUnchanged(
        basis: TripAutomaticEnrichmentBasis,
        attentionReason _: String
    ) throws -> TripSummary? {
        guard let trip = trips[basis.tripID] else { return nil }
        routeCompletionTripIDs.append(basis.tripID)
        return trip
    }

    func recordEnrichmentFailure(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent,
        category: TripEnrichmentFailureCategory,
        at: Date
    ) throws -> TripEnrichmentAttempt? {
        failures.append(.init(tripID: basis.tripID, component: component, category: category))
        return TripEnrichmentAttempt(
            tripID: basis.tripID,
            component: component,
            lastAttemptAt: at,
            consecutiveFailures: 1,
            failureCategory: category
        )
    }

    func markEnrichmentUnavailable(
        basis: TripAutomaticEnrichmentBasis,
        component: TripEnrichmentComponent
    ) throws -> TripSummary? {
        unavailable.append((basis.tripID, component))
        return trips[basis.tripID]
    }
}

private enum CoordinatorTestError: Error {
    case failed
}
