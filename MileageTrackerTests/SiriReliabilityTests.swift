import AppCore
import AppIntents
import XCTest
@testable import MileageTracker

@MainActor
final class SiriReliabilityTests: XCTestCase {
    private var model: MileageAppModel!
    private var donationEvents: [TripIntentDonations.Event] = []

    override func setUp() async throws {
        try await super.setUp()
        model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding", "--seed-current-drive"]),
            preferences: Preferences(defaults: try makeTestDefaults()),
            intentDonationsOverride: TripIntentDonations { [weak self] event in self?.donationEvents.append(event) }
        )
        TripIntentDataProvider.modelProvider = { [weak model] in model }
        await model.startup()
    }

    override func tearDown() async throws {
        TripIntentDataProvider.resetForTesting()
        model = nil
        try await super.tearDown()
    }

    func testCurrentDriveCategoryAndPurposeSurviveIndependentContextReload() async throws {
        let id = try XCTUnwrap(model.currentDrive?.pendingTripID)
        let intent = ClassifyCurrentDriveIntent(classification: .business)
        intent.businessPurpose = "Client visit"
        _ = try await intent.perform()
        let context = model.persistence.container.newBackgroundContext()
        let saved = try context.performAndWait { try ActiveDriveStore(context: context).load() }
        XCTAssertEqual(saved?.pendingTripID, id)
        XCTAssertEqual(saved?.pendingClassification, .business)
        XCTAssertEqual(saved?.pendingBusinessPurpose, "Client visit")
    }

    func testReadyModelWaitsForRestorationAndTimesOutBoundedly() async throws {
        var checks = 0
        TripIntentDataProvider.isReady = { _ in checks += 1; return checks > 1 }
        let ready = try await TripIntentDataProvider.readyModel(timeout: .milliseconds(100))
        XCTAssertTrue(ready === model)
        XCTAssertGreaterThan(checks, 1)
        TripIntentDataProvider.isReady = { _ in false }
        do {
            _ = try await TripIntentDataProvider.readyModel(timeout: .zero)
            XCTFail("Unrestored capture must not look like an empty drive list")
        } catch TripIntentError.startupUnavailable { }
    }

    func testIdentityIsRevalidatedAfterReadinessSuspends() async throws {
        let old = try XCTUnwrap(model.currentDrive)
        let store = ActiveDriveStore(context: model.persistence.container.viewContext)
        var checks = 0
        var ready = false
        TripIntentDataProvider.isReady = { _ in
            checks += 1
            return ready
        }
        let intent = ClassifyCurrentDriveIntent(classification: .business)
        intent.drive = CurrentDriveAppEntity(old)
        let execution = Task { _ = try await intent.perform() }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertGreaterThan(checks, 0)
        // Replace the persisted drive while execution is suspended and the
        // model still holds the old summary. Revalidate at the write boundary.
        var replacement = try XCTUnwrap(store.load())
        replacement.pendingTripID = UUID()
        try store.save(replacement)
        ready = true
        do {
            try await execution.value
            XCTFail("An expired entity must not edit the replacement recording")
        } catch TripIntentError.currentDriveNotFound { }
        XCTAssertNil(try store.load()?.pendingClassification)
    }

    func testAppLockPreventsQueryAndMutation() async throws {
        let prefs = Preferences(defaults: try makeTestDefaults())
        prefs.appLockEnabled = true
        let locked = MileageAppModel(previewMode: true, preferences: prefs)
        TripIntentDataProvider.modelProvider = { locked }
        TripIntentDataProvider.isReady = { _ in true }
        XCTAssertNil(TripIntentDataProvider.availableModel())
        let entities = try await CurrentDriveAppEntityQuery().suggestedEntities()
        XCTAssertTrue(entities.isEmpty)
        do {
            _ = try await ClassifyCurrentDriveIntent(classification: .business).perform()
            XCTFail("Siri must honor the app's lock")
        } catch TripIntentError.appLocked { }
    }

    func testProtectedDataHasDistinctUnavailableResult() async throws {
        let locked = MileageAppModel(
            preferences: Preferences(defaults: try makeTestDefaults()),
            protectedDataAvailableOverride: false
        )
        TripIntentDataProvider.modelProvider = { locked }
        do {
            _ = try await TripIntentDataProvider.readyModel(timeout: .zero)
            XCTFail("The placeholder store must not answer Siri queries")
        } catch TripIntentError.storeUnavailable { }
    }

#if compiler(>=6.4)
    func testSchemaOpenAndSearchPreserveTargetAndDoNotClassify() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("System schemas require iOS 27") }
        let current = try XCTUnwrap(model.currentDrive)
        let open = OpenCurrentDriveIntent()
        open.target = CurrentDriveAppEntity(current)
        _ = try await open.perform()
        XCTAssertEqual(model.currentDrivePresentationRequestID, current.pendingTripID)
        let search = SearchTripsIntent()
        search.criteria = StringSearchCriteria(term: "make this business")
        _ = try await search.perform()
        XCTAssertEqual(model.requestedTripSearch?.text, "make this business")
        XCTAssertNil(model.currentDrive?.classification)
    }
#endif

    func testUIClassificationDonatesOnceButSiriDoesNotRedonate() async throws {
        model.siriIndexingEnabled = true
        await model.intentDonations.waitForPendingOperations()
        donationEvents = []
        model.setCurrentDriveClassification(.personal)
        _ = try await ClassifyCurrentDriveIntent(classification: .business).perform()
        await model.intentDonations.waitForPendingOperations()
        XCTAssertEqual(donationEvents.count, 1)
        guard case let .current(entity, category) = donationEvents.first else {
            return XCTFail("Expected one saved in-app classification")
        }
        XCTAssertEqual(category, .personal)
        XCTAssertEqual(entity.id, model.currentDrive?.pendingTripID)
        XCTAssertEqual(model.currentDrive?.classification, .business)
    }

    func testDonationOptOutAndExpirationFollowSavedAction() async throws {
        var events: [String] = []
        let donations = TripIntentDonations { event in
            switch event {
            case .current: events.append("donate")
            case .removeCurrentDrive: events.append("expire")
            case .removeAll: events.append("clear")
            default: XCTFail("Unexpected donation event")
            }
            await Task.yield()
        }
        var current = try XCTUnwrap(model.currentDrive)
        current.classification = .business
        donations.classifiedCurrentDrive(current)
        donations.setEnabled(true)
        donations.classifiedCurrentDrive(current)
        await donations.waitForPendingOperations()
        donations.removeCurrentDrive(current.pendingTripID)
        donations.setEnabled(false)
        donations.classifiedCurrentDrive(current)
        await donations.waitForPendingOperations()
        XCTAssertEqual(events, ["donate", "expire", "clear"])
    }

    func testOptOutInvalidatesQueuedDonationEvenWhenQuicklyReenabled() async throws {
        var donationsSent = 0
        var clears = 0
        let donations = TripIntentDonations { event in
            switch event {
            case .current: donationsSent += 1
            case .removeAll: clears += 1
            default: XCTFail("Unexpected event")
            }
        }
        var current = try XCTUnwrap(model.currentDrive)
        current.classification = .business
        donations.setEnabled(true)
        donations.classifiedCurrentDrive(current)
        // No suspension: the queued donation has not started yet.
        donations.setEnabled(false)
        donations.setEnabled(true)
        await donations.waitForPendingOperations()
        XCTAssertEqual(donationsSent, 0)
        XCTAssertEqual(clears, 1)
    }

    func testOptOutDeletesAnInFlightDonationAfterItFinishes() async throws {
        let started = expectation(description: "Donation reached the system")
        var release: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let donations = TripIntentDonations { event in
            switch event {
            case .current:
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
                events.append("donated")
            case .removeAll: events.append("cleared")
            default: XCTFail("Unexpected event")
            }
        }
        var current = try XCTUnwrap(model.currentDrive)
        current.classification = .business
        donations.setEnabled(true)
        donations.classifiedCurrentDrive(current)
        await fulfillment(of: [started], timeout: 1)
        donations.setEnabled(false)
        XCTAssertTrue(events.isEmpty)
        release?.resume()
        await donations.waitForPendingOperations()
        XCTAssertEqual(events, ["donated", "cleared"])
    }
}
