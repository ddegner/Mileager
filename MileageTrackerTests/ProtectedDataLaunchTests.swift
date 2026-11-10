import AppCore
import CoreData
import Foundation
import XCTest
@testable import MileageTracker

/// Covers the before-first-unlock (BFU) launch path: when iOS relaunches the
/// app for a location event while the store files are still encrypted, the
/// app must not crash, and it must adopt the real on-disk store once the
/// device is unlocked.
@MainActor
final class ProtectedDataLaunchTests: XCTestCase {
    private let suffix = "bfu-\(UUID().uuidString)"

    private func arguments() -> [String] {
        // A fixed store suffix so the degraded model and the verification
        // model share the same on-disk directory.
        ["MileageTracker", "--uitesting", "--skip-onboarding", "--test-store-suffix=\(suffix)"]
    }

    func testLockedLaunchDoesNotCrashAndDegrades() throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )

        XCTAssertTrue(model.isAwaitingProtectedData)
        // The placeholder keeps a headless wake alive, but it must never accept
        // user data that would disappear when the real store replaces it.
        XCTAssertNil(model.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 5,
            origin: "A",
            destination: "B",
            classification: .business,
            purpose: "Work",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        XCTAssertFalse(model.loadSampleData())
        XCTAssertTrue(model.trips.isEmpty)
    }

    func testLockedPlaceholderNeverHydratesDerivedSuggestionCache() async throws {
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false,
            suggestionProvider: ProtectedDataUnavailableSuggestionProvider()
        )

        await model.startup()

        XCTAssertTrue(model.isAwaitingProtectedData)
        XCTAssertFalse(model.hasHydratedSuggestionCache)
        XCTAssertNil(model.suggestionCacheHydrationTask)
        XCTAssertTrue(model.tripSuggestions.isEmpty)
        let suggestionDirectory = DerivedArtifactCacheRoot.scopedRootURL(testSuffix: suffix)
            .appendingPathComponent("suggestions", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: suggestionDirectory.path))

        await model.reloadPersistenceForProtectedData()
        await model.waitForSuggestionCacheHydration()

        XCTAssertFalse(model.isAwaitingProtectedData)
        XCTAssertTrue(model.hasHydratedSuggestionCache)
    }

    func testReloadAdoptsOnDiskStoreAndPersists() async throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )
        XCTAssertTrue(model.isAwaitingProtectedData)

        // Simulates UIApplication.protectedDataDidBecomeAvailable firing.
        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)

        // A trip created after the reload must land on the on-disk store...
        let start = Date(timeIntervalSince1970: 1_810_000_000)
        XCTAssertNotNil(model.createManualTrip(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            distanceMiles: 12,
            origin: "Office",
            destination: "Client",
            classification: .business,
            purpose: "Client",
            notes: "",
            tolls: 0,
            parking: 0
        ))

        // ...and be visible to a fresh, fully-unlocked model on the same store.
        let reopened = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true
        )
        await reopened.startup()
        XCTAssertFalse(reopened.isAwaitingProtectedData)
        XCTAssertTrue(reopened.trips.contains { $0.startAddress == "Office" && $0.endAddress == "Client" })
    }

    func testUnlockRunsRetiredMaintenanceAgainstRealStoreBeforePublishingTrips() async throws {
        let archivedID = UUID()
        let activeID = UUID()
        try seedRetiredState(archivedID: archivedID, activeID: activeID)

        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )
        await model.startup()

        XCTAssertTrue(model.isAwaitingProtectedData)
        XCTAssertFalse(model.hasLoadedInitialTrips)

        await model.reloadPersistenceForProtectedData()

        XCTAssertFalse(model.isAwaitingProtectedData)
        XCTAssertTrue(model.hasLoadedInitialTrips)
        XCTAssertFalse(model.trips.contains { $0.id == archivedID })
        let active = try XCTUnwrap(model.trips.first { $0.id == activeID })
        XCTAssertFalse(active.needsAttention)
        XCTAssertFalse(active.attentionReasons.contains("Possible duplicate found after sync"))
        XCTAssertEqual(active.reviewStatus, .readyToExport)
    }

    func testUnlockRetriesRetiredMaintenanceAfterFailure() async throws {
        let attempts = MaintenanceAttemptCounter()
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false,
            retiredTripMaintenanceRunner: { controller in
                if await attempts.shouldFail() {
                    throw MaintenanceTestError.firstAttempt
                }
                return try await RetiredTripMaintenance(persistence: controller).run()
            }
        )

        await model.reloadPersistenceForProtectedData()
        XCTAssertTrue(model.isAwaitingProtectedData)

        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)
        let attemptCount = await attempts.count()
        XCTAssertEqual(attemptCount, 2)
    }

    /// A maintenance failure must degrade, not abort: aborting startup left
    /// the app blank (no refresh, Spotlight, or sync) on every launch for as
    /// long as one row kept the cleanup throwing.
    func testStartupContinuesLoadingWhenRetiredMaintenanceKeepsFailing() async throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true,
            retiredTripMaintenanceRunner: { _ in
                throw MaintenanceTestError.firstAttempt
            }
        )
        await model.startup()

        XCTAssertTrue(
            model.hasLoadedInitialTrips,
            "startup aborted on a maintenance error instead of degrading"
        )
    }

    func testLockedLocationWakeDefersTrackingBootstrapAndRetriesAfterUnlock() async throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )
        model.trackingActive = true

        await model.startup(launchReason: .locationWake)

        var diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Deferred tracking wake bootstrap until protected data is available"
        })
        // A deferred launch must still hold store-independent wake channels —
        // with zero armed CoreLocation clients the suspended process is an
        // unwakeable zombie for the rest of the drive.
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Armed protected-data wake keeper (beacon geofence + SLC/visits)"
        })

        await model.reloadPersistenceForProtectedData()

        diagnostics = try decodeDiagnostics(from: model)
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Retrying tracking wake bootstrap after protected data became available"
        })
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "lifecycle"
                && $0.message == "Resumed drive capture during location wake"
        })
        XCTAssertTrue(diagnostics.events.contains {
            $0.category == "wakeBootstrap"
                && $0.message == "Released protected-data wake keeper"
        })
    }

    func testReloadIsIdempotent() async throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )

        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)
        // A second call must be a no-op rather than re-swapping the store.
        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)
    }

    func testNormalLaunchIsNotDegraded() async throws {
        let model = MileageAppModel(
            arguments: arguments(),
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: true
        )

        XCTAssertFalse(model.isAwaitingProtectedData)
        // Reload is a no-op on the normal path.
        await model.reloadPersistenceForProtectedData()
        XCTAssertFalse(model.isAwaitingProtectedData)
    }

    private func decodeDiagnostics(from model: MileageAppModel) throws -> DiagnosticsExport {
        let data = try XCTUnwrap(model.exportDiagnostics())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticsExport.self, from: data)
    }

    private func seedRetiredState(archivedID: UUID, activeID: UUID) throws {
        let directory = ResetCoordinator.storeDirectoryForUITesting(suffix: suffix)
        let persistence = try PersistenceController(
            mode: .localOnly,
            inMemory: false,
            storeDirectory: directory
        )
        let context = persistence.container.viewContext
        try context.performAndWait {
            let archived = Self.insertTrip(id: archivedID, in: context)
            archived.setValue(true, forKey: "isArchived")

            let active = Self.insertTrip(id: activeID, in: context)
            active.setValue(TripClassification.personal.rawValue, forKey: "classificationRaw")
            active.setValue(true, forKey: "needsAttention")
            active.setValue(ReviewStatus.needsReview.rawValue, forKey: "reviewStatusRaw")
            active.setValue(
                try JSONEncoder().encode(["Possible duplicate found after sync"]),
                forKey: "attentionReasonsData"
            )
            try context.save()
        }
    }

    nonisolated private static func insertTrip(
        id: UUID,
        in context: NSManagedObjectContext
    ) -> NSManagedObject {
        let trip = NSEntityDescription.insertNewObject(
            forEntityName: "TripEntity",
            into: context
        )
        let start = Date(timeIntervalSince1970: 1_820_000_000)
        trip.setValue(id, forKey: "id")
        trip.setValue(start, forKey: "createdAt")
        trip.setValue(start, forKey: "updatedAt")
        trip.setValue("manual", forKey: "captureSource")
        trip.setValue(start, forKey: "startDate")
        trip.setValue(start.addingTimeInterval(600), forKey: "endDate")
        trip.setValue(1_000.0, forKey: "distanceMeters")
        trip.setValue(600.0, forKey: "durationSeconds")
        trip.setValue(ReviewStatus.needsReview.rawValue, forKey: "reviewStatusRaw")
        trip.setValue(false, forKey: "needsAttention")
        return trip
    }
}

@MainActor
private final class ProtectedDataUnavailableSuggestionProvider: TripSuggestionProviding {
    var isAvailable: Bool { false }

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        nil
    }
}

private enum MaintenanceTestError: Error {
    case firstAttempt
}

private actor MaintenanceAttemptCounter {
    private var value = 0

    func shouldFail() -> Bool {
        value += 1
        return value == 1
    }

    func count() -> Int {
        value
    }
}
