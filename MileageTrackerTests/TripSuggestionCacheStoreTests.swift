import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class TripSuggestionCacheStoreTests: XCTestCase {
    func testRootSeparatesProductionHostedAndExplicitTestScopes() throws {
        let production = DerivedArtifactCacheRoot.productionRootURL()
        XCTAssertTrue(production.path.hasSuffix("/Library/Caches/Mileager/DerivedArtifacts/v1"))

        let first = DerivedArtifactCacheRoot.scopedRootURL(testSuffix: "cache-test-one")
        let second = DerivedArtifactCacheRoot.scopedRootURL(testSuffix: "cache-test-two")
        XCTAssertNotEqual(first, production)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.path.hasSuffix("/DerivedArtifacts/v1/testing/cache-test-one"))

        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            XCTAssertTrue(
                DerivedArtifactCacheRoot.scopedRootURL().path
                    .hasSuffix("/DerivedArtifacts/v1/testing/hosted-unit-tests")
            )
        }
    }

    func testStoreRoundTripsFreshThenStaleAndExpiresAfterThirtyDays() async throws {
        let suffix = "suggestion-age-\(UUID().uuidString)"
        defer { try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix) }
        let clock = SuggestionCacheTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = TripSuggestionCacheStore(testSuffix: suffix, now: { clock.now })
        let suggestion = makeSuggestion()

        await store.save(
            suggestion,
            fingerprint: "matching-fingerprint",
            tripUpdatedAt: suggestion.generatedAt
        )

        var hits = await store.load(matching: [suggestion.tripID: "matching-fingerprint"])
        XCTAssertEqual(hits[suggestion.tripID]?.freshness, .fresh)
        XCTAssertEqual(hits[suggestion.tripID]?.suggestion, suggestion)

        clock.advance(by: 25 * 60 * 60)
        hits = await store.load(matching: [suggestion.tripID: "matching-fingerprint"])
        XCTAssertEqual(hits[suggestion.tripID]?.freshness, .stale)

        clock.advance(by: 30 * 24 * 60 * 60)
        hits = await store.load(matching: [suggestion.tripID: "matching-fingerprint"])
        XCTAssertTrue(hits.isEmpty)
        let expiredEntryCount = await store.cachedEntryCount()
        XCTAssertEqual(expiredEntryCount, 0)
    }

    func testStoreTreatsCorruptionAndFingerprintChangesAsMisses() async throws {
        let suffix = "suggestion-corrupt-\(UUID().uuidString)"
        defer { try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix) }
        let directory = try DerivedArtifactCacheRoot.prepareSubdirectory(
            "suggestions",
            testSuffix: suffix
        )
        let tripID = UUID()
        let corruptURL = directory
            .appendingPathComponent(tripID.uuidString.lowercased())
            .appendingPathExtension("json")
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)
        let store = TripSuggestionCacheStore(testSuffix: suffix)

        var hits = await store.load(matching: [tripID: "expected"])
        XCTAssertTrue(hits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))

        let suggestion = makeSuggestion(tripID: tripID)
        await store.save(suggestion, fingerprint: "old", tripUpdatedAt: suggestion.generatedAt)
        hits = await store.load(matching: [tripID: "new"])
        XCTAssertTrue(hits.isEmpty)
        let invalidatedEntryCount = await store.cachedEntryCount()
        XCTAssertEqual(invalidatedEntryCount, 0)
    }

    func testConditionalRemovalPreservesAReplacementWithANewerFingerprint() async {
        let suffix = "suggestion-conditional-remove-\(UUID().uuidString)"
        defer { try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix) }
        let store = TripSuggestionCacheStore(testSuffix: suffix)
        let tripID = UUID()
        let oldSuggestion = makeSuggestion(tripID: tripID)
        let replacement = TripClassificationSuggestion(
            tripID: tripID,
            classification: .personal,
            businessPurpose: nil,
            evidence: [],
            generatedAt: oldSuggestion.generatedAt.addingTimeInterval(1)
        )

        await store.save(oldSuggestion, fingerprint: "old", tripUpdatedAt: oldSuggestion.generatedAt)
        await store.save(replacement, fingerprint: "new", tripUpdatedAt: replacement.generatedAt)
        await store.remove(entriesMatching: [tripID: "old"])

        let hits = await store.load(matching: [tripID: "new"])
        XCTAssertEqual(hits[tripID]?.suggestion, replacement)
    }

    func testStoreAppliesNoBackupClassCAndTwoHundredEntryLimit() async throws {
        let suffix = "suggestion-policy-\(UUID().uuidString)"
        defer { try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix) }
        let store = TripSuggestionCacheStore(testSuffix: suffix)
        var expected: [UUID: String] = [:]
        for index in 0..<205 {
            let suggestion = makeSuggestion(tripID: UUID(), generatedAt: Date().addingTimeInterval(Double(index)))
            let fingerprint = "fingerprint-\(index)"
            expected[suggestion.tripID] = fingerprint
            await store.save(
                suggestion,
                fingerprint: fingerprint,
                tripUpdatedAt: suggestion.generatedAt
            )
        }

        let hits = await store.load(matching: expected)
        XCTAssertEqual(hits.count, TripSuggestionCacheStore.maximumEntryCount)
        let retainedEntryCount = await store.cachedEntryCount()
        XCTAssertEqual(retainedEntryCount, TripSuggestionCacheStore.maximumEntryCount)

        let directory = try DerivedArtifactCacheRoot.prepareSubdirectory(
            "suggestions",
            testSuffix: suffix
        )
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #if targetEnvironment(simulator)
        // Simulator filesystems do not expose NSFileProtectionKey even when
        // the write options and attributes request it.
        let directoryProtection = directoryAttributes[.protectionKey] as? FileProtectionType
        XCTAssertTrue(directoryProtection == nil || directoryProtection == .completeUntilFirstUserAuthentication)
        #else
        XCTAssertEqual(
            directoryAttributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif

        let fileURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first
        )
        let fileValues = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #if targetEnvironment(simulator)
        let fileProtection = fileAttributes[.protectionKey] as? FileProtectionType
        XCTAssertTrue(fileProtection == nil || fileProtection == .completeUntilFirstUserAuthentication)
        #else
        XCTAssertEqual(
            fileAttributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    func testFingerprintCoversTripPromptLocalePresetsEvidencePermissionsAndMyCard() {
        let trip = makeTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            miles: 12
        )
        func fingerprint(
            trip: TripSummary = trip,
            locale: String = "en_US",
            presets: [String] = ["Client meeting"],
            calendarEnabled: Bool = true,
            calendarPermission: Bool = true,
            contactEnabled: Bool = true,
            contactsPermission: Int = 3,
            home: String? = "111 Private Street"
        ) -> String {
            SuggestionFingerprint.make(
                trip: trip,
                localeIdentifier: locale,
                businessPurposePresets: presets,
                calendarEvidenceEnabled: calendarEnabled,
                calendarPermissionGranted: calendarPermission,
                contactEvidenceEnabled: contactEnabled,
                contactsPermissionRawValue: contactsPermission,
                userCardName: "Private Person",
                userHomeStreetLine: home,
                userHomeCity: "Brooklyn",
                userWorkStreetLine: nil,
                userWorkCity: nil
            )
        }

        let baseline = fingerprint()
        var updatedTrip = trip
        updatedTrip.updatedAt = trip.updatedAt.addingTimeInterval(1)
        let variants = [
            fingerprint(trip: updatedTrip),
            fingerprint(locale: "de_DE"),
            fingerprint(presets: ["Site visit"]),
            fingerprint(calendarEnabled: false),
            fingerprint(calendarPermission: false),
            fingerprint(contactEnabled: false),
            fingerprint(contactsPermission: 0),
            fingerprint(home: "222 Changed Street"),
        ]
        XCTAssertEqual(baseline.count, 64)
        XCTAssertTrue(variants.allSatisfy { $0 != baseline })
        // A pure lowercase-hex digest cannot embed raw address text; checking
        // the bare number "111" instead would flake on hash coincidences.
        XCTAssertTrue(baseline.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertFalse(baseline.contains("Private"))
        XCTAssertFalse(baseline.contains("111 Private Street"))
    }

    @MainActor
    func testRelaunchHydratesFreshSuggestionWithoutCallingProviderAgain() async throws {
        let suffix = "suggestion-relaunch-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        let arguments = [
            "MileageTracker", "--uitesting", "--skip-onboarding",
            "--test-store-suffix=\(suffix)",
        ]
        let firstProvider = SuggestionCacheRecordingProvider()
        var firstModel: MileageAppModel? = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: firstProvider,
            calendarFullAccessProvider: { false }
        )
        await firstModel?.startup()
        let created = try XCTUnwrap(firstModel?.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        await firstModel?.suggestionBackfillTask?.value
        XCTAssertEqual(firstProvider.requests.count, 1)
        XCTAssertNotNil(firstModel?.tripSuggestions[created.id])
        firstModel = nil

        let secondProvider = SuggestionCacheRecordingProvider()
        let reopened = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: secondProvider,
            calendarFullAccessProvider: { false }
        )
        await reopened.startup()

        XCTAssertNotNil(reopened.tripSuggestions[created.id])
        XCTAssertTrue(secondProvider.requests.isEmpty)
    }

    @MainActor
    func testStaleSuggestionSurvivesFailedRefresh() async throws {
        let suffix = "suggestion-stale-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let preferences = Preferences(defaults: try makeTestDefaults())
        let arguments = [
            "MileageTracker", "--uitesting", "--skip-onboarding",
            "--test-store-suffix=\(suffix)",
        ]
        let firstProvider = SuggestionCacheRecordingProvider()
        var firstModel: MileageAppModel? = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: firstProvider,
            calendarFullAccessProvider: { false }
        )
        await firstModel?.startup()
        let created = try XCTUnwrap(firstModel?.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        await firstModel?.suggestionBackfillTask?.value
        let suggestion = try XCTUnwrap(firstModel?.tripSuggestions[created.id])
        let fingerprint = try XCTUnwrap(firstModel?.suggestionFingerprints[created.id])
        let staleDate = Date().addingTimeInterval(-25 * 60 * 60)
        let staleStore = TripSuggestionCacheStore(testSuffix: suffix, now: { staleDate })
        await staleStore.save(
            suggestion,
            fingerprint: fingerprint,
            tripUpdatedAt: try XCTUnwrap(firstModel?.trip(id: created.id)?.updatedAt)
        )
        firstModel = nil

        let failingProvider = SuggestionCacheRecordingProvider(returnsSuggestion: false)
        let reopened = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: failingProvider,
            calendarFullAccessProvider: { false }
        )
        await reopened.startup()
        await reopened.suggestionBackfillTask?.value

        XCTAssertEqual(reopened.tripSuggestions[created.id], suggestion)
        XCTAssertEqual(failingProvider.requests.map(\.trip.id), [created.id])
        XCTAssertTrue(reopened.suggestionRefreshNeeded.contains(created.id))
    }

    @MainActor
    func testResetAppClearsTheIsolatedDerivedArtifactScope() async throws {
        let suffix = "suggestion-reset-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let mapDirectory = try DerivedArtifactCacheRoot.prepareSubdirectory("maps", testSuffix: suffix)
        let marker = mapDirectory.appendingPathComponent("marker")
        try Data("cached".utf8).write(to: marker, options: .atomic)
        let provider = SuggestionCacheRecordingProvider()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker", "--uitesting", "--skip-onboarding",
                "--test-store-suffix=\(suffix)",
            ],
            preferences: Preferences(defaults: try makeTestDefaults()),
            suggestionProvider: provider,
            calendarFullAccessProvider: { false }
        )
        await model.startup()
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        await model.suggestionBackfillTask?.value
        XCTAssertNotNil(model.tripSuggestions[created.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        await model.resetApp()
        await model.waitForSuggestionCacheHydration()

        XCTAssertTrue(model.tripSuggestions.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: DerivedArtifactCacheRoot.scopedRootURL(testSuffix: suffix).path
            )
        )
    }

    @MainActor
    func testUnclassifiedEditRemovesItsDiskEntryAsynchronously() async throws {
        let suffix = "suggestion-edit-delete-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let provider = SuggestionCacheRecordingProvider()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker", "--uitesting", "--skip-onboarding",
                "--test-store-suffix=\(suffix)",
            ],
            preferences: Preferences(defaults: try makeTestDefaults()),
            suggestionProvider: provider,
            calendarFullAccessProvider: { false }
        )
        await model.startup()
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        await model.suggestionBackfillTask?.value
        let cacheStore = try XCTUnwrap(model.suggestionCacheStore)
        let initialEntryCount = await cacheStore.cachedEntryCount()
        XCTAssertEqual(initialEntryCount, 1)
        provider.isAvailable = false

        model.updateQuickNotes(try XCTUnwrap(model.trip(id: created.id)), notes: "Changed evidence")
        await model.waitForSuggestionCacheInvalidations()

        XCTAssertNil(model.tripSuggestions[created.id])
        let editedEntryCount = await cacheStore.cachedEntryCount()
        XCTAssertEqual(editedEntryCount, 0)
    }

    @MainActor
    func testRegenerationWaitsForOlderDeletionAndLeavesNewEntryOnDisk() async throws {
        let suffix = "suggestion-invalidation-race-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let provider = SuggestionCacheRecordingProvider()
        let model = MileageAppModel(
            arguments: [
                "MileageTracker", "--uitesting", "--skip-onboarding",
                "--test-store-suffix=\(suffix)",
            ],
            preferences: Preferences(defaults: try makeTestDefaults()),
            suggestionProvider: provider,
            calendarFullAccessProvider: { false }
        )
        await model.startup()
        let created = try XCTUnwrap(model.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        await model.suggestionBackfillTask?.value
        let cacheStore = try XCTUnwrap(model.suggestionCacheStore)
        let initialEntryCount = await cacheStore.cachedEntryCount()
        XCTAssertEqual(initialEntryCount, 1)

        model.saveBusinessPurposePresets(["Site visit"])
        await model.suggestionBackfillTask?.value
        await model.waitForSuggestionCacheInvalidations()

        XCTAssertEqual(provider.requests.count, 2)
        let regeneratedEntryCount = await cacheStore.cachedEntryCount()
        XCTAssertEqual(regeneratedEntryCount, 1)
        let current = try XCTUnwrap(model.trip(id: created.id))
        let fingerprint = model.suggestionFingerprint(for: current)
        let hits = await cacheStore.load(matching: [created.id: fingerprint])
        XCTAssertNotNil(hits[created.id])
    }

    @MainActor
    func testHydrationMismatchCleanupRemovesOldHitButPreservesConcurrentReplacement() async throws {
        let suffix = "suggestion-hydration-race-\(UUID().uuidString)"
        let storeDirectory = try XCTUnwrap(ResetCoordinator.storeDirectoryForUITesting(suffix: suffix))
        try? FileManager.default.removeItem(at: storeDirectory)
        try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        defer {
            try? FileManager.default.removeItem(at: storeDirectory)
            try? DerivedArtifactCacheRoot.removeAll(testSuffix: suffix)
        }

        let arguments = [
            "MileageTracker", "--uitesting", "--skip-onboarding",
            "--test-store-suffix=\(suffix)",
        ]
        let preferences = Preferences(defaults: try makeTestDefaults())
        let unavailableProvider = SuggestionCacheRecordingProvider()
        unavailableProvider.isAvailable = false
        var firstModel: MileageAppModel? = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: unavailableProvider,
            calendarFullAccessProvider: { false }
        )
        await firstModel?.startup()
        let firstTrip = try XCTUnwrap(firstModel?.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_001_800),
            distanceMiles: 12,
            origin: "Home",
            destination: "Client A",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        let secondTrip = try XCTUnwrap(firstModel?.createManualTrip(
            startDate: Date(timeIntervalSince1970: 1_800_086_400),
            endDate: Date(timeIntervalSince1970: 1_800_088_200),
            distanceMiles: 8,
            origin: "Home",
            destination: "Client B",
            classification: nil,
            purpose: "",
            notes: "",
            tolls: 0,
            parking: 0
        ))
        let firstStoredTrip = try XCTUnwrap(firstModel?.trip(id: firstTrip.id))
        let secondStoredTrip = try XCTUnwrap(firstModel?.trip(id: secondTrip.id))
        let firstOldFingerprint = try XCTUnwrap(firstModel)
            .suggestionFingerprint(for: firstStoredTrip)
        let secondOldFingerprint = try XCTUnwrap(firstModel)
            .suggestionFingerprint(for: secondStoredTrip)
        let initialStore = try XCTUnwrap(firstModel?.suggestionCacheStore)
        await initialStore.save(
            makeSuggestion(tripID: firstTrip.id),
            fingerprint: firstOldFingerprint,
            tripUpdatedAt: firstStoredTrip.updatedAt
        )
        await initialStore.save(
            makeSuggestion(tripID: secondTrip.id),
            fingerprint: secondOldFingerprint,
            tripUpdatedAt: secondStoredTrip.updatedAt
        )
        firstModel = nil

        let loadGate = SuggestionCacheLoadGate()
        let pausedStore = TripSuggestionCacheStore(
            testSuffix: suffix,
            afterLoad: { await loadGate.arriveAndWait() }
        )
        let reopened = MileageAppModel(
            arguments: arguments,
            preferences: preferences,
            suggestionProvider: unavailableProvider,
            suggestionCacheStoreOverride: pausedStore,
            calendarFullAccessProvider: { false }
        )
        let startupTask = Task { await reopened.startup() }
        await loadGate.waitUntilArrived()

        reopened.updateQuickNotes(
            try XCTUnwrap(reopened.trip(id: firstTrip.id)),
            notes: "Changed after cache read"
        )
        reopened.updateQuickNotes(
            try XCTUnwrap(reopened.trip(id: secondTrip.id)),
            notes: "Also changed after cache read"
        )
        let firstCurrent = try XCTUnwrap(reopened.trip(id: firstTrip.id))
        let secondCurrent = try XCTUnwrap(reopened.trip(id: secondTrip.id))
        let firstNewFingerprint = reopened.suggestionFingerprint(for: firstCurrent)
        let secondNewFingerprint = reopened.suggestionFingerprint(for: secondCurrent)
        XCTAssertNotEqual(firstNewFingerprint, firstOldFingerprint)
        XCTAssertNotEqual(secondNewFingerprint, secondOldFingerprint)

        let replacement = TripClassificationSuggestion(
            tripID: secondTrip.id,
            classification: .personal,
            businessPurpose: nil,
            evidence: [],
            generatedAt: Date()
        )
        await pausedStore.save(
            replacement,
            fingerprint: secondNewFingerprint,
            tripUpdatedAt: secondCurrent.updatedAt
        )
        await loadGate.release()
        await startupTask.value
        await reopened.waitForSuggestionCacheInvalidations()

        XCTAssertNil(reopened.tripSuggestions[firstTrip.id])
        XCTAssertNil(reopened.tripSuggestions[secondTrip.id])
        let retainedEntryCount = await pausedStore.cachedEntryCount()
        XCTAssertEqual(retainedEntryCount, 1)
        let hits = await pausedStore.load(matching: [secondTrip.id: secondNewFingerprint])
        XCTAssertEqual(hits[secondTrip.id]?.suggestion, replacement)
    }

    private func makeSuggestion(
        tripID: UUID = UUID(),
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> TripClassificationSuggestion {
        TripClassificationSuggestion(
            tripID: tripID,
            classification: .business,
            businessPurpose: "Client meeting",
            rationale: "The destination and note indicate a client meeting.",
            evidence: [.calendarEvent(title: "Portrait shoot")],
            generatedAt: generatedAt
        )
    }
}

private final class SuggestionCacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor SuggestionCacheLoadGate {
    private var didArrive = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        didArrive = true
        let waiters = arrivalWaiters
        arrivalWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilArrived() async {
        guard !didArrive else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class SuggestionCacheRecordingProvider: TripSuggestionProviding {
    var isAvailable = true
    private(set) var requests: [TripSuggestionRequest] = []
    private let returnsSuggestion: Bool

    init(returnsSuggestion: Bool = true) {
        self.returnsSuggestion = returnsSuggestion
    }

    func prewarm() {}

    func suggestion(for request: TripSuggestionRequest) async -> TripClassificationSuggestion? {
        requests.append(request)
        guard returnsSuggestion else { return nil }
        return TripClassificationSuggestion(
            tripID: request.trip.id,
            classification: .business,
            businessPurpose: "Client meeting",
            evidence: [],
            generatedAt: Date()
        )
    }
}
