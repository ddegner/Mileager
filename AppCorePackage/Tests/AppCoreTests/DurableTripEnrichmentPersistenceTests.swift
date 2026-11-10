import CoreData
import XCTest
@testable import AppCore
@testable import AppCorePersistence

@MainActor
final class DurableTripEnrichmentPersistenceTests: XCTestCase {
    func testPreviousModelStoresLightweightMigrateWithoutChangingLegacyRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableEnrichmentMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldModelURL = try XCTUnwrap(
            PersistenceController.managedObjectModelURL(
                versionName: "MileageTrackerVehicleConnections"
            )
        )
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: oldModelURL))
        let oldContainer = NSPersistentContainer(name: "MileageTracker", managedObjectModel: oldModel)
        oldContainer.persistentStoreDescriptions = [
            storeDescription(
                configuration: PersistenceController.cloudConfigurationName,
                url: directory.appendingPathComponent("MileageTracker.sqlite")
            ),
            storeDescription(
                configuration: PersistenceController.localConfigurationName,
                url: directory.appendingPathComponent("MileageTrackerRaw.sqlite")
            )
        ]
        var loadErrors: [Error] = []
        oldContainer.loadPersistentStores { _, error in
            if let error { loadErrors.append(error) }
        }
        XCTAssertTrue(loadErrors.isEmpty)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = NSEntityDescription.insertNewObject(
            forEntityName: TripEntity.entityName,
            into: oldContainer.viewContext
        )
        let id = UUID()
        legacy.setValue(id, forKey: "id")
        legacy.setValue(start, forKey: "createdAt")
        legacy.setValue(start, forKey: "updatedAt")
        legacy.setValue("automatic", forKey: "captureSource")
        legacy.setValue(start, forKey: "startDate")
        legacy.setValue(start.addingTimeInterval(600), forKey: "endDate")
        legacy.setValue(42.0, forKey: "startLatitude")
        legacy.setValue(-71.0, forKey: "startLongitude")
        legacy.setValue(42.1, forKey: "endLatitude")
        legacy.setValue(-71.1, forKey: "endLongitude")
        legacy.setValue(7_777.0, forKey: "distanceMeters")
        legacy.setValue(600.0, forKey: "durationSeconds")
        legacy.setValue("legacy-route-bytes", forKey: "routePolyline")
        legacy.setValue(ReviewStatus.needsReview.rawValue, forKey: "reviewStatusRaw")
        legacy.setValue(0.0, forKey: "tollsAmount")
        legacy.setValue(0.0, forKey: "parkingAmount")
        legacy.setValue(false, forKey: "needsAttention")
        legacy.setValue(false, forKey: "isArchived")
        try oldContainer.viewContext.save()
        for store in oldContainer.persistentStoreCoordinator.persistentStores {
            try oldContainer.persistentStoreCoordinator.remove(store)
        }

        let migrated = try PersistenceController(mode: .localOnly, storeDirectory: directory)
        let store = TripStore(context: migrated.container.viewContext)
        XCTAssertEqual(try store.normalizeLegacyEnrichmentStates(), 1)
        let trip = try store.fetchTrip(id: id)
        XCTAssertEqual(trip.routeEnrichmentState, .legacy)
        XCTAssertEqual(trip.routePolyline, "legacy-route-bytes")
        XCTAssertEqual(trip.distanceMeters, 7_777)
        XCTAssertEqual(trip.startAddressEnrichmentState, .pending)
        XCTAssertEqual(trip.endAddressEnrichmentState, .pending)
    }

    func testModelKeepsSyncedStateOnTripAndAttemptsInLocalStoreOnly() throws {
        let persistence = try PersistenceController(inMemory: true)
        let model = persistence.container.managedObjectModel
        let trip = try XCTUnwrap(model.entitiesByName[TripEntity.entityName])
        XCTAssertNotNil(trip.attributesByName["startAddressEnrichmentStateRaw"])
        XCTAssertNotNil(trip.attributesByName["endAddressEnrichmentStateRaw"])
        XCTAssertNotNil(trip.attributesByName["routeEnrichmentStateRaw"])

        let cloudNames = Set(
            model.entities(forConfigurationName: PersistenceController.cloudConfigurationName)?
                .compactMap(\.name) ?? []
        )
        let localNames = Set(
            model.entities(forConfigurationName: PersistenceController.localConfigurationName)?
                .compactMap(\.name) ?? []
        )
        XCTAssertTrue(cloudNames.contains(TripEntity.entityName))
        XCTAssertFalse(cloudNames.contains(TripEnrichmentAttemptEntity.entityName))
        XCTAssertTrue(localNames.contains(TripEnrichmentAttemptEntity.entityName))
    }

    func testCompletedAutomaticTripStartsPendingAndRawSamplesAreOrdered() throws {
        let (persistence, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = automaticDraft(start: start, reverseSampleOrder: true)

        let trip = try store.saveCompletedTrip(draft)
        let samples = try store.fetchRawSamples(tripID: trip.id)

        XCTAssertEqual(trip.startAddressEnrichmentState, .pending)
        XCTAssertEqual(trip.endAddressEnrichmentState, .pending)
        XCTAssertEqual(trip.routeEnrichmentState, .pending)
        XCTAssertEqual(samples.map(\.timestamp), samples.map(\.timestamp).sorted())
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(persistence.hasLoadedStore(
            configurationName: PersistenceController.localConfigurationName
        ))
    }

    func testLegacyNormalizationRepairsAddressesButNeverTouchesRouteOrDistance() throws {
        let (persistence, store) = try makeStore()
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = "legacy-route-bytes"
        let trip = insertLegacyAutomatic(
            start: start,
            startAddress: nil,
            endAddress: "Known Destination",
            routePolyline: route,
            distanceMeters: 12_345,
            in: context
        )
        let tripID = try XCTUnwrap(trip.id)
        insertRawSample(
            tripID: tripID,
            date: start,
            latitude: 42,
            longitude: -71,
            in: context
        )
        insertRawSample(
            tripID: tripID,
            date: start.addingTimeInterval(60),
            latitude: 42.1,
            longitude: -71.1,
            in: context
        )
        try context.save()
        let rawSamplesBefore = try store.fetchRawSamples(tripID: tripID)

        XCTAssertNil(trip.startAddressEnrichmentStateRaw)
        XCTAssertNil(trip.endAddressEnrichmentStateRaw)
        XCTAssertNil(trip.routeEnrichmentStateRaw)
        XCTAssertEqual(try store.normalizeLegacyEnrichmentStates(), 1)

        let normalized = try store.fetchTrip(id: tripID)
        XCTAssertEqual(normalized.startAddressEnrichmentState, .pending)
        XCTAssertEqual(normalized.endAddressEnrichmentState, .complete)
        XCTAssertEqual(normalized.routeEnrichmentState, .legacy)
        XCTAssertEqual(normalized.routePolyline, route)
        XCTAssertEqual(normalized.distanceMeters, 12_345)
        XCTAssertEqual(try store.fetchRawSamples(tripID: tripID), rawSamplesBefore)

        let addressed = try XCTUnwrap(store.updateAutomaticEndpointIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: normalized),
            component: .startAddress,
            address: "Resolved Historical Start"
        ))
        XCTAssertEqual(addressed.startAddress, "Resolved Historical Start")
        XCTAssertEqual(addressed.routePolyline, route)
        XCTAssertEqual(addressed.distanceMeters, 12_345)
        XCTAssertEqual(try store.fetchRawSamples(tripID: tripID), rawSamplesBefore)
    }

    func testLegacyTripWithNilRouteAndRetainedSamplesIsNeverRouteCandidate() throws {
        let (persistence, store) = try makeStore()
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let distance = 4_321.0
        let trip = insertLegacyAutomatic(
            start: start,
            routePolyline: nil,
            distanceMeters: distance,
            in: context
        )
        let tripID = try XCTUnwrap(trip.id)
        insertRawSample(
            tripID: tripID,
            date: start,
            latitude: 42,
            longitude: -71,
            in: context
        )
        insertRawSample(
            tripID: tripID,
            date: start.addingTimeInterval(60),
            latitude: 42.1,
            longitude: -71.1,
            in: context
        )
        try context.save()
        let rawSamplesBefore = try store.fetchRawSamples(tripID: tripID)

        XCTAssertEqual(try store.normalizeLegacyEnrichmentStates(), 1)

        let normalized = try store.fetchTrip(id: tripID)
        XCTAssertEqual(normalized.routeEnrichmentState, .legacy)
        XCTAssertNil(normalized.routePolyline)
        XCTAssertEqual(normalized.distanceMeters, distance)
        XCTAssertEqual(try store.fetchRawSamples(tripID: tripID), rawSamplesBefore)
        XCTAssertFalse(try store.fetchRouteEnrichmentCandidates().contains {
            $0.trip.id == tripID
        })
    }

    func testLegacyBlankManualAndInvalidCoordinateEndpointsAreNotPending() throws {
        let (persistence, store) = try makeStore()
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let manual = insertLegacyAutomatic(start: start, in: context)
        manual.captureSource = "manual"
        let invalid = insertLegacyAutomatic(start: start.addingTimeInterval(7_200), in: context)
        invalid.startLatitude = 100
        try context.save()

        XCTAssertEqual(try store.normalizeLegacyEnrichmentStates(), 2)
        XCTAssertEqual(manual.startAddressEnrichmentState, .legacy)
        XCTAssertEqual(invalid.startAddressEnrichmentState, .legacy)
        let candidates = try store.fetchAddressEnrichmentCandidates()
        XCTAssertEqual(candidates.map(\.trip.id), [invalid.id])
        XCTAssertEqual(candidates.first?.components, [.endAddress])
    }

    func testCandidateBackoffUsesRequestedSchedule() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trip = try store.saveCompletedTrip(automaticDraft(start: start))
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        _ = try store.markEnrichmentUnavailable(basis: basis, component: .endAddress)

        let first = try XCTUnwrap(store.recordEnrichmentFailure(
            basis: basis,
            component: .startAddress,
            category: .networkUnavailable,
            at: start
        ))
        XCTAssertEqual(first.consecutiveFailures, 1)
        XCTAssertEqual(first.nextEligibleAt, start.addingTimeInterval(5 * 60))
        XCTAssertTrue(try store.fetchAddressEnrichmentCandidates(
            now: start.addingTimeInterval(5 * 60 - 1)
        ).isEmpty)
        XCTAssertEqual(
            try store.fetchAddressEnrichmentCandidates(now: start.addingTimeInterval(5 * 60))
                .first?.components,
            [.startAddress]
        )

        let second = try XCTUnwrap(store.recordEnrichmentFailure(
            basis: basis,
            component: .startAddress,
            category: .timedOut,
            at: start.addingTimeInterval(5 * 60)
        ))
        XCTAssertEqual(second.consecutiveFailures, 2)
        XCTAssertEqual(second.nextEligibleAt, start.addingTimeInterval(35 * 60))
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 1), 5 * 60)
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 2), 30 * 60)
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 3), 2 * 60 * 60)
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 4), 12 * 60 * 60)
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 5), 24 * 60 * 60)
        XCTAssertEqual(TripEnrichmentAttempt.retryDelay(forConsecutiveFailures: 6), 24 * 60 * 60)
    }

    func testAddressCandidatesAreNewestFirstAndLimitedByTrip() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = try store.saveCompletedTrip(automaticDraft(start: start))
        let newest = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(3_600))
        )

        let candidates = try store.fetchAddressEnrichmentCandidates(limit: 1, now: start)

        XCTAssertEqual(candidates.map(\.trip.id), [newest.id])
        XCTAssertNotEqual(candidates.first?.trip.id, oldest.id)
        XCTAssertEqual(candidates.first?.components, [.startAddress, .endAddress])
    }

    func testConcurrentEndpointResultsCanApplyFromSameBasis() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let basis = TripAutomaticEnrichmentBasis(trip: trip)

        XCTAssertNotNil(try store.updateAutomaticEndpointIfUnchanged(
            basis: basis,
            component: .startAddress,
            address: "Resolved Start"
        ))
        XCTAssertNotNil(try store.updateAutomaticEndpointIfUnchanged(
            basis: basis,
            component: .endAddress,
            address: "Resolved End"
        ))

        let resolved = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(resolved.startAddress, "Resolved Start")
        XCTAssertEqual(resolved.endAddress, "Resolved End")
        XCTAssertEqual(resolved.startAddressEnrichmentState, .complete)
        XCTAssertEqual(resolved.endAddressEnrichmentState, .complete)
    }

    func testSameManualAddressLabelsPreserveResolvedComponentsAndState() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let components = TripEndpointAddressComponents(
            streetNumber: "1",
            streetName: "Main Street",
            neighborhood: "Downtown",
            city: "Boston",
            state: "MA",
            country: "United States",
            countryCode: "US"
        )
        let resolved = try XCTUnwrap(store.updateAutomaticEndpointIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: trip),
            component: .startAddress,
            address: "1 Main Street",
            components: components
        ))

        let unchanged = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "1 Main Street",
            endAddress: nil
        )
        XCTAssertEqual(unchanged.startAddressComponents, resolved.startAddressComponents)
        XCTAssertEqual(unchanged.startAddressEnrichmentState, .complete)

        let edited = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "My House",
            endAddress: nil
        )
        XCTAssertNil(edited.startAddressComponents)
        XCTAssertEqual(edited.startAddressEnrichmentState, .userManaged)
    }

    func testExplicitManualRouteDecisionSuppressesPendingRetryEvenWhenValuesMatch() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let edited = try store.updateRoute(
            tripID: trip.id,
            startCoordinate: try XCTUnwrap(trip.startCoordinate),
            endCoordinate: try XCTUnwrap(trip.endCoordinate),
            routePolyline: trip.routePolyline,
            distanceMeters: trip.distanceMeters
        )

        XCTAssertEqual(edited.routeEnrichmentState, .userManaged)
        XCTAssertTrue(try store.fetchRouteEnrichmentCandidates().isEmpty)
    }

    func testStaleFailuresAndTerminalResultsCannotAffectResavedCapture() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = automaticDraft(start: start)
        let trip = try store.saveCompletedTrip(draft)
        let staleBasis = TripAutomaticEnrichmentBasis(trip: trip)

        draft.samples[0].latitude = 43
        draft.distanceMeters = 4_000
        _ = try store.saveCompletedTrip(draft)

        XCTAssertNil(try store.recordEnrichmentFailure(
            basis: staleBasis,
            component: .startAddress,
            category: .networkUnavailable,
            at: start
        ))
        XCTAssertNil(try store.markEnrichmentUnavailable(
            basis: staleBasis,
            component: .route
        ))
        XCTAssertNil(try store.fetchEnrichmentAttempt(
            tripID: trip.id,
            component: .startAddress
        ))
        XCTAssertEqual(try store.fetchTrip(id: trip.id).routeEnrichmentState, .pending)
    }

    func testResavingCapturePreservesCompletedAndUserManagedEnrichment() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = automaticDraft(start: start)
        let trip = try store.saveCompletedTrip(draft)
        let addressed = try XCTUnwrap(store.updateAutomaticEndpointIfUnchanged(
            basis: TripAutomaticEnrichmentBasis(trip: trip),
            component: .startAddress,
            address: "Resolved Start"
        ))
        let userRoute = try store.updateRoute(
            tripID: trip.id,
            startCoordinate: try XCTUnwrap(addressed.startCoordinate),
            endCoordinate: try XCTUnwrap(addressed.endCoordinate),
            routePolyline: addressed.routePolyline,
            distanceMeters: 9_999
        )

        let resaved = try store.saveCompletedTrip(draft)

        XCTAssertEqual(resaved.startAddress, "Resolved Start")
        XCTAssertEqual(resaved.startAddressEnrichmentState, .complete)
        XCTAssertEqual(resaved.routeEnrichmentState, .userManaged)
        XCTAssertEqual(resaved.distanceMeters, userRoute.distanceMeters)
    }

    func testManualEditAndDeleteCleanUpLocalAttempts() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        _ = try store.recordEnrichmentFailure(
            basis: basis,
            component: .startAddress,
            category: .timedOut
        )
        _ = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "My Start",
            endAddress: nil
        )
        XCTAssertNil(try store.fetchEnrichmentAttempt(
            tripID: trip.id,
            component: .startAddress
        ))

        _ = try store.recordEnrichmentFailure(
            basis: basis,
            component: .route,
            category: .serviceUnavailable
        )
        try store.deleteTrip(id: trip.id)
        XCTAssertNil(try store.fetchEnrichmentAttempt(tripID: trip.id, component: .route))
    }

    func testReconcileEnrichmentAttemptsRemovesRemoteStaleAndOrphanRows() throws {
        let (persistence, store) = try makeStore()
        let context = persistence.container.viewContext
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = try store.saveCompletedTrip(automaticDraft(start: start))
        let completed = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(3_600))
        )
        let manual = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(10_800))
        )
        let invalidCoordinate = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(14_400))
        )
        let populatedEndpoint = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(18_000))
        )
        let userManagedRoute = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(21_600))
        )

        for trip in [valid, completed, manual, invalidCoordinate, populatedEndpoint] {
            XCTAssertNotNil(try store.recordEnrichmentFailure(
                basis: TripAutomaticEnrichmentBasis(trip: trip),
                component: .startAddress,
                category: .timedOut,
                at: start
            ))
        }
        for trip in [valid, userManagedRoute] {
            XCTAssertNotNil(try store.recordEnrichmentFailure(
                basis: TripAutomaticEnrichmentBasis(trip: trip),
                component: .route,
                category: .serviceUnavailable,
                at: start
            ))
        }

        try tripEntity(id: completed.id, in: context).startAddressEnrichmentState = .complete
        try tripEntity(id: manual.id, in: context).captureSource = "manual"
        try tripEntity(id: invalidCoordinate.id, in: context).startLatitude = 100
        let populatedEntity = try tripEntity(id: populatedEndpoint.id, in: context)
        populatedEntity.startAddress = "Resolved Remotely"
        try tripEntity(id: userManagedRoute.id, in: context).routeEnrichmentState = .userManaged

        let orphanID = UUID()
        let orphan = TripEnrichmentAttemptEntity.insert(into: context)
        orphan.id = UUID()
        orphan.tripID = orphanID
        orphan.component = .startAddress
        orphan.lastAttemptAt = start
        orphan.consecutiveFailures = 1
        orphan.failureCategory = .networkUnavailable

        let malformed = TripEnrichmentAttemptEntity.insert(into: context)
        malformed.id = UUID()
        malformed.tripID = valid.id
        malformed.componentRaw = "not-a-component"
        malformed.lastAttemptAt = start
        malformed.consecutiveFailures = 1
        malformed.failureCategory = .unknown
        try context.save()

        XCTAssertEqual(try store.reconcileEnrichmentAttempts(), 7)

        XCTAssertNotNil(try store.fetchEnrichmentAttempt(
            tripID: valid.id,
            component: .startAddress
        ))
        XCTAssertNotNil(try store.fetchEnrichmentAttempt(
            tripID: valid.id,
            component: .route
        ))
        for tripID in [
            completed.id,
            manual.id,
            invalidCoordinate.id,
            populatedEndpoint.id,
            orphanID
        ] {
            XCTAssertNil(try store.fetchEnrichmentAttempt(
                tripID: tripID,
                component: .startAddress
            ))
        }
        XCTAssertNil(try store.fetchEnrichmentAttempt(
            tripID: userManagedRoute.id,
            component: .route
        ))
        XCTAssertEqual(try context.count(for: TripEnrichmentAttemptEntity.fetchRequest()), 2)
    }

    func testMacEditorCommitsManualProvenanceAndAttemptCleanupAtomically() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        try seedPendingAttempts(for: trip, in: store)

        var invalidUpdate = TripEditorUpdate(trip: trip, fees: [])
        invalidUpdate.startAddress = "Edited Start"
        invalidUpdate.endAddress = "Edited End"
        invalidUpdate.distanceMeters += 250
        invalidUpdate.startCoordinate = Coordinate(latitude: 200, longitude: -71)

        XCTAssertThrowsError(try store.updateTrip(id: trip.id, update: invalidUpdate))
        let unchanged = try store.fetchTrip(id: trip.id)
        XCTAssertEqual(unchanged.startAddressEnrichmentState, .pending)
        XCTAssertEqual(unchanged.endAddressEnrichmentState, .pending)
        XCTAssertEqual(unchanged.routeEnrichmentState, .pending)
        try assertHasAllEnrichmentAttempts(tripID: trip.id, in: store)

        var validUpdate = TripEditorUpdate(trip: unchanged, fees: [])
        validUpdate.startAddress = "Edited Start"
        validUpdate.endAddress = "Edited End"
        validUpdate.distanceMeters += 250
        let edited = try store.updateTrip(id: trip.id, update: validUpdate)

        assertAllEnrichmentIsUserManaged(edited)
        try assertHasNoEnrichmentAttempts(tripID: trip.id, in: store)
    }

    func testClearingResolvedEndpointsMarksBothAsUserManaged() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        XCTAssertNotNil(try store.updateAutomaticEndpointIfUnchanged(
            basis: basis,
            component: .startAddress,
            address: "Resolved Start"
        ))
        XCTAssertNotNil(try store.updateAutomaticEndpointIfUnchanged(
            basis: basis,
            component: .endAddress,
            address: "Resolved End"
        ))

        let cleared = try store.updateAddresses(
            tripID: trip.id,
            startAddress: "",
            endAddress: ""
        )

        XCTAssertNil(cleared.startAddress)
        XCTAssertNil(cleared.endAddress)
        XCTAssertEqual(cleared.startAddressEnrichmentState, .userManaged)
        XCTAssertEqual(cleared.endAddressEnrichmentState, .userManaged)
        XCTAssertEqual(cleared.routeEnrichmentState, .pending)
    }

    func testRouteDeletionAndClearRouteMapRecordManualProvenance() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let routeDeletionTrip = try store.saveCompletedTrip(automaticDraft(start: start))
        let deletedRoute = try store.updateRoute(
            tripID: routeDeletionTrip.id,
            startCoordinate: try XCTUnwrap(routeDeletionTrip.startCoordinate),
            endCoordinate: try XCTUnwrap(routeDeletionTrip.endCoordinate),
            routePolyline: nil,
            distanceMeters: nil
        )
        XCTAssertNil(deletedRoute.routePolyline)
        XCTAssertEqual(deletedRoute.routeEnrichmentState, .userManaged)
        XCTAssertEqual(deletedRoute.startAddressEnrichmentState, .pending)
        XCTAssertEqual(deletedRoute.endAddressEnrichmentState, .pending)

        let mapClearingTrip = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(3_600))
        )
        try seedPendingAttempts(for: mapClearingTrip, in: store)
        let clearedMap = try store.clearRouteMap(tripID: mapClearingTrip.id)

        XCTAssertNil(clearedMap.startCoordinate)
        XCTAssertNil(clearedMap.endCoordinate)
        XCTAssertNil(clearedMap.routePolyline)
        assertAllEnrichmentIsUserManaged(clearedMap)
        try assertHasNoEnrichmentAttempts(tripID: mapClearingTrip.id, in: store)
    }

    func testMergeCreatesUserManagedProvenanceAndRemovesSourceAttempts() throws {
        let (_, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.saveCompletedTrip(automaticDraft(start: start))
        let second = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(180))
        )
        try seedPendingAttempts(for: first, in: store)
        try seedPendingAttempts(for: second, in: store)

        let merged = try store.mergeTrips(ids: [first.id, second.id])

        assertAllEnrichmentIsUserManaged(merged)
        XCTAssertNil(try store.fetchTripIfExists(id: first.id))
        XCTAssertNil(try store.fetchTripIfExists(id: second.id))
        try assertHasNoEnrichmentAttempts(tripID: first.id, in: store)
        try assertHasNoEnrichmentAttempts(tripID: second.id, in: store)
    }

    func testSplitMarksRestoredAndRemainingTripsUserManagedAndClearsAttempts() throws {
        let (persistence, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let trips = try (0..<3).map { index in
            try store.saveCompletedTrip(
                automaticDraft(start: start.addingTimeInterval(Double(index) * 180))
            )
        }
        let merged = try store.mergeTrips(ids: trips.map(\.id))
        try forcePendingEnrichmentWithAttempts(
            tripID: merged.id,
            context: persistence.container.viewContext
        )

        let restored = try store.splitMergedTrip(
            id: merged.id,
            legIDs: [merged.legs[1].id]
        )
        let remaining = try store.fetchTrip(id: merged.id)

        XCTAssertEqual(restored.count, 1)
        assertAllEnrichmentIsUserManaged(try XCTUnwrap(restored.first))
        assertAllEnrichmentIsUserManaged(remaining)
        try assertHasNoEnrichmentAttempts(tripID: merged.id, in: store)
    }

    func testUnmergeMarksEveryRestoredTripUserManagedAndClearsAttempts() throws {
        let (persistence, store) = try makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.saveCompletedTrip(automaticDraft(start: start))
        let second = try store.saveCompletedTrip(
            automaticDraft(start: start.addingTimeInterval(180))
        )
        let merged = try store.mergeTrips(ids: [first.id, second.id])
        try forcePendingEnrichmentWithAttempts(
            tripID: merged.id,
            context: persistence.container.viewContext
        )

        let restored = try store.unmergeTrip(id: merged.id)

        XCTAssertEqual(restored.count, 2)
        restored.forEach { assertAllEnrichmentIsUserManaged($0) }
        XCTAssertNil(try store.fetchTripIfExists(id: merged.id))
        try assertHasNoEnrichmentAttempts(tripID: merged.id, in: store)
    }

    func testDuplicateAndRecreateUseUserManagedProvenanceAndClearOrphanAttempts() throws {
        let (persistence, store) = try makeStore()
        let original = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        let duplicateID = UUID()
        try insertEnrichmentAttempts(
            tripID: duplicateID,
            context: persistence.container.viewContext
        )

        let result = try store.duplicateTripWithSnapshot(
            id: original.id,
            newID: duplicateID,
            startDate: original.startDate.addingTimeInterval(86_400)
        )

        assertAllEnrichmentIsUserManaged(result.trip)
        try assertHasNoEnrichmentAttempts(tripID: duplicateID, in: store)

        try store.deleteTrip(id: duplicateID)
        try insertEnrichmentAttempts(
            tripID: duplicateID,
            context: persistence.container.viewContext
        )
        let recreated = try store.recreateTrip(from: result.snapshot)

        assertAllEnrichmentIsUserManaged(recreated)
        try assertHasNoEnrichmentAttempts(tripID: duplicateID, in: store)
    }

    func testRestoreSnapshotMarksChangedComponentsUserManagedAndClearsAttempts() throws {
        let (_, store) = try makeStore()
        let trip = try store.saveCompletedTrip(
            automaticDraft(start: Date(timeIntervalSince1970: 1_800_000_000))
        )
        try seedPendingAttempts(for: trip, in: store)
        var snapshot = try store.editableSnapshot(tripID: trip.id)
        snapshot.startAddress = "Restored Start"
        snapshot.endAddress = "Restored End"
        snapshot.manualDistanceOverrideMeters = trip.distanceMeters + 100

        let restored = try store.restoreEditableSnapshot(snapshot)

        XCTAssertEqual(restored.startAddress, "Restored Start")
        XCTAssertEqual(restored.endAddress, "Restored End")
        assertAllEnrichmentIsUserManaged(restored)
        try assertHasNoEnrichmentAttempts(tripID: trip.id, in: store)
    }

    private func makeStore() throws -> (PersistenceController, TripStore) {
        let persistence = try PersistenceController(inMemory: true)
        return (persistence, TripStore(context: persistence.container.viewContext))
    }

    private func tripEntity(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> TripEntity {
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func seedPendingAttempts(
        for trip: TripSummary,
        in store: TripStore
    ) throws {
        let basis = TripAutomaticEnrichmentBasis(trip: trip)
        for component in TripEnrichmentComponent.allCases {
            XCTAssertNotNil(try store.recordEnrichmentFailure(
                basis: basis,
                component: component,
                category: .timedOut
            ))
        }
    }

    private func assertAllEnrichmentIsUserManaged(
        _ trip: TripSummary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(trip.startAddressEnrichmentState, .userManaged, file: file, line: line)
        XCTAssertEqual(trip.endAddressEnrichmentState, .userManaged, file: file, line: line)
        XCTAssertEqual(trip.routeEnrichmentState, .userManaged, file: file, line: line)
    }

    private func assertHasAllEnrichmentAttempts(
        tripID: UUID,
        in store: TripStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for component in TripEnrichmentComponent.allCases {
            XCTAssertNotNil(
                try store.fetchEnrichmentAttempt(tripID: tripID, component: component),
                file: file,
                line: line
            )
        }
    }

    private func assertHasNoEnrichmentAttempts(
        tripID: UUID,
        in store: TripStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for component in TripEnrichmentComponent.allCases {
            XCTAssertNil(
                try store.fetchEnrichmentAttempt(tripID: tripID, component: component),
                file: file,
                line: line
            )
        }
    }

    private func forcePendingEnrichmentWithAttempts(
        tripID: UUID,
        context: NSManagedObjectContext
    ) throws {
        let request = TripEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", tripID as CVarArg)
        let trip = try XCTUnwrap(context.fetch(request).first)
        trip.startAddressEnrichmentState = .pending
        trip.endAddressEnrichmentState = .pending
        trip.routeEnrichmentState = .pending
        try insertEnrichmentAttempts(tripID: tripID, context: context, saves: false)
        try context.save()
    }

    private func insertEnrichmentAttempts(
        tripID: UUID,
        context: NSManagedObjectContext,
        saves: Bool = true
    ) throws {
        for component in TripEnrichmentComponent.allCases {
            let attempt = TripEnrichmentAttemptEntity.insert(into: context)
            attempt.id = UUID()
            attempt.tripID = tripID
            attempt.component = component
            attempt.lastAttemptAt = Date(timeIntervalSince1970: 1_800_000_000)
            attempt.consecutiveFailures = 1
            attempt.failureCategory = .timedOut
        }
        if saves {
            try context.save()
        }
    }

    private func storeDescription(
        configuration: String,
        url: URL
    ) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.configuration = configuration
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        return description
    }

    private func automaticDraft(
        start: Date,
        reverseSampleOrder: Bool = false
    ) -> TripDraft {
        var samples = [
            LocationSample(
                timestamp: start,
                latitude: 42,
                longitude: -71,
                horizontalAccuracy: 5
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(60),
                latitude: 42.1,
                longitude: -71.1,
                horizontalAccuracy: 5
            ),
            LocationSample(
                timestamp: start.addingTimeInterval(120),
                latitude: 42.2,
                longitude: -71.2,
                horizontalAccuracy: 5
            )
        ]
        if reverseSampleOrder {
            samples.reverse()
        }
        return TripDraft(
            startDate: start,
            endDate: start.addingTimeInterval(120),
            samples: samples,
            distanceMeters: 3_000
        )
    }

    @discardableResult
    private func insertLegacyAutomatic(
        start: Date,
        startAddress: String? = nil,
        endAddress: String? = nil,
        routePolyline: String? = nil,
        distanceMeters: Double = 1_000,
        in context: NSManagedObjectContext
    ) -> TripEntity {
        let trip = TripEntity.insert(into: context)
        trip.id = UUID()
        trip.createdAt = start
        trip.updatedAt = start
        trip.captureSource = "automatic"
        trip.startDate = start
        trip.endDate = start.addingTimeInterval(600)
        trip.startCoordinate = Coordinate(latitude: 42, longitude: -71)
        trip.endCoordinate = Coordinate(latitude: 42.1, longitude: -71.1)
        trip.startAddress = startAddress
        trip.endAddress = endAddress
        trip.distanceMeters = distanceMeters
        trip.durationSeconds = 600
        trip.routePolyline = routePolyline
        trip.reviewStatus = .needsReview
        trip.tollsAmount = 0
        trip.parkingAmount = 0
        trip.needsAttention = false
        return trip
    }

    private func insertRawSample(
        tripID: UUID,
        date: Date,
        latitude: Double,
        longitude: Double,
        in context: NSManagedObjectContext
    ) {
        let sample = RawSampleEntity.insert(into: context)
        sample.id = UUID()
        sample.tripID = tripID
        sample.timestamp = date
        sample.latitude = latitude
        sample.longitude = longitude
        sample.horizontalAccuracy = 5
        sample.motionHintRaw = MotionHint.automotive.rawValue
        sample.expiresAt = date.addingTimeInterval(30 * 24 * 60 * 60)
    }
}
