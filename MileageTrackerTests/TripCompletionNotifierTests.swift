import AppCore
import Foundation
import UserNotifications
import XCTest
@testable import MileageTracker

@MainActor
final class TripCompletionNotifierTests: XCTestCase {
    private var model: MileageAppModel!
    private var delegate: TripCompletionNotificationDelegate!
    private var removedNotificationIDs: [UUID] = []
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        TripIntentDataProvider.isReady = { _ in true }
        removedNotificationIDs = []
        delegate = TripCompletionNotificationDelegate { [weak self] id in
            self?.removedNotificationIDs.append(id)
        }
        let defaults = try makeTestDefaults()
        model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )
        TripIntentDataProvider.modelProvider = { [weak model] in model }
    }

    override func tearDown() async throws {
        TripIntentDataProvider.resetForTesting()
        model = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Pure helpers

    func testRequestIdentifierRoundTripsTripID() {
        let id = UUID()
        let identifier = TripCompletionNotifier.requestIdentifier(for: id)
        XCTAssertEqual(TripCompletionNotifier.tripID(fromRequestIdentifier: identifier), id)
        XCTAssertNil(TripCompletionNotifier.tripID(fromRequestIdentifier: "month-end-mileage-review"))
        XCTAssertNil(TripCompletionNotifier.tripID(fromRequestIdentifier: "trip-completed-not-a-uuid"))
    }

    func testBodyShowsTimeRangeAndDistanceOnly() {
        let trip = makeTrip(startDate: start, miles: 12.3)
        let body = TripCompletionNotifier.body(
            for: trip,
            unit: .miles,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        // 2027-01-15 03:00 EST, 30 minutes long.
        XCTAssertEqual(body, "3:00\u{2009}–\u{2009}3:30\u{202F}AM · 12.3 mi")
        XCTAssertFalse(body.contains("Start"), "addresses must not appear on the Lock Screen")
        XCTAssertFalse(body.contains("End"), "addresses must not appear on the Lock Screen")
    }

    func testBodyHonorsKilometerPreference() {
        let trip = makeTrip(startDate: start, miles: 10)
        let body = TripCompletionNotifier.body(
            for: trip,
            unit: .kilometers,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        XCTAssertTrue(body.contains("16.1 km"), body)
    }

    func testContentCarriesCategoryAndTripID() {
        let trip = makeTrip(startDate: start, miles: 3)
        let content = TripCompletionNotifier.makeContent(for: trip, unit: .miles)
        XCTAssertEqual(content.categoryIdentifier, TripCompletionNotifier.categoryIdentifier)
        XCTAssertEqual(content.userInfo[TripCompletionNotifier.tripIDUserInfoKey] as? String, trip.id.uuidString)
        XCTAssertEqual(content.interruptionLevel, .active, "time-sensitive needs an entitlement the app does not hold")
    }

    func testCategoryOffersFirstTwoPurposesThenPersonalAndNotADriveWithIcons() {
        let businessPurposes = ["Client meeting", "Site visit", "Supplies"]
        let definitions = TripCompletionNotifier.actionDefinitions(
            businessPurposes: businessPurposes
        )
        let category = TripCompletionNotifier.makeCategory(
            businessPurposes: businessPurposes
        )
        XCTAssertEqual(category.identifier, TripCompletionNotifier.categoryIdentifier)
        XCTAssertEqual(category.actions.count, 4, "iPhone notification detail supports at most four actions")
        XCTAssertEqual(category.actions.map(\.identifier), definitions.map(\.identifier))
        XCTAssertEqual(category.actions.map(\.title), [
            "Client meeting",
            "Site visit",
            TripCompletionNotifier.Action.personal.title,
            TripCompletionNotifier.Action.notADrive.title
        ])
        XCTAssertEqual(definitions.map(\.systemImageName), [
            "briefcase.fill",
            "briefcase",
            "person.fill",
            "nosign"
        ])
        XCTAssertTrue(category.actions.allSatisfy { $0.icon != nil })
        for action in category.actions {
            XCTAssertFalse(
                action.options.contains(.authenticationRequired),
                "\(action.identifier) must work from the Lock Screen"
            )
            XCTAssertFalse(
                action.options.contains(.foreground),
                "\(action.identifier) must not open the app"
            )
        }
        XCTAssertFalse(category.actions[0].options.contains(.destructive))
        XCTAssertFalse(category.actions[1].options.contains(.destructive))
        XCTAssertFalse(category.actions[2].options.contains(.destructive))
        XCTAssertTrue(category.actions[3].options.contains(.destructive))
    }

    func testCategorySafelyHandlesZeroAndOneBusinessPurpose() {
        let fallback = TripCompletionNotifier.makeCategory(businessPurposes: [])
        XCTAssertEqual(fallback.actions.map(\.identifier), [
            TripCompletionNotifier.Action.business.rawValue,
            TripCompletionNotifier.Action.personal.rawValue,
            TripCompletionNotifier.Action.notADrive.rawValue
        ])
        XCTAssertEqual(fallback.actions.map(\.title), [
            TripCompletionNotifier.Action.business.title,
            TripCompletionNotifier.Action.personal.title,
            TripCompletionNotifier.Action.notADrive.title
        ])

        let onePurpose = TripCompletionNotifier.makeCategory(
            businessPurposes: ["  Photo shoot  "]
        )
        XCTAssertEqual(onePurpose.actions.count, 3)
        XCTAssertEqual(onePurpose.actions.map(\.title), [
            "Photo shoot",
            TripCompletionNotifier.Action.personal.title,
            TripCompletionNotifier.Action.notADrive.title
        ])
        XCTAssertEqual(
            TripCompletionNotifier.businessPurpose(
                fromActionIdentifier: onePurpose.actions[0].identifier
            ),
            "Photo shoot"
        )
    }

    func testDecisionMapsActionsToClassifications() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [TripCompletionNotifier.tripIDUserInfoKey: id.uuidString]
        let expectations: [(String, TripClassification)] = [
            (TripCompletionNotifier.Action.business.rawValue, .business),
            (TripCompletionNotifier.Action.personal.rawValue, .personal),
            (TripCompletionNotifier.Action.notADrive.rawValue, .notADrive)
        ]
        for (identifier, classification) in expectations {
            let decision = TripCompletionNotifier.decision(actionIdentifier: identifier, userInfo: userInfo)
            XCTAssertEqual(decision?.tripID, id)
            XCTAssertEqual(decision?.classification, classification)
            XCTAssertNil(decision?.businessPurpose)
        }
        XCTAssertNil(TripCompletionNotifier.decision(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: userInfo
        ))
        XCTAssertNil(TripCompletionNotifier.decision(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: userInfo
        ))
        XCTAssertNil(TripCompletionNotifier.decision(
            actionIdentifier: TripCompletionNotifier.Action.business.rawValue,
            userInfo: [:]
        ))
    }

    func testDecisionMapsPurposeActionsToTheExactDisplayedPurpose() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [TripCompletionNotifier.tripIDUserInfoKey: id.uuidString]
        let purposes = ["Séance photo", "Kundentermin"]
        let category = TripCompletionNotifier.makeCategory(businessPurposes: purposes)

        for (action, purpose) in zip(category.actions.prefix(2), purposes) {
            let decision = TripCompletionNotifier.decision(
                actionIdentifier: action.identifier,
                userInfo: userInfo
            )
            XCTAssertEqual(action.title, purpose)
            XCTAssertEqual(decision?.tripID, id)
            XCTAssertEqual(decision?.classification, .business)
            XCTAssertEqual(decision?.businessPurpose, purpose)
        }

        XCTAssertNil(TripCompletionNotifier.decision(
            actionIdentifier: "trip-completed.business-purpose.not-valid-base64!",
            userInfo: userInfo
        ))
    }

    // MARK: - Applying a Lock Screen decision

    func testDefaultTapOpensTripWithoutClassifyingIt() async throws {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "Home",
            endAddress: "Office",
            distanceMeters: 5_000,
            classification: nil
        ))
        let action = try XCTUnwrap(TripCompletionNotifier.responseAction(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: TripCompletionNotifier.makeContent(for: trip, unit: .miles).userInfo
        ))
        XCTAssertEqual(action, .openTrip(trip.id))

        // A notification response can arrive before the first foreground
        // activation. Opening it must not wait for that transition to finish.
        model.appLock.handleScenePhaseChange(.background)
        await delegate.handle(action)

        XCTAssertEqual(model.requestedTripDetailID, trip.id)
        XCTAssertTrue(try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id)).isUnresolved)
        XCTAssertEqual(model.appLock.overlayMode, .privacyCover)
    }

    func testDefaultTapOnDeletedTripDoesNotQueueNavigation() async {
        await delegate.handle(.openTrip(UUID()))
        XCTAssertNil(model.requestedTripDetailID)
    }

    func testDismissAndMalformedNotificationResponsesDoNothing() {
        let userInfo: [AnyHashable: Any] = [TripCompletionNotifier.tripIDUserInfoKey: UUID().uuidString]
        XCTAssertNil(TripCompletionNotifier.responseAction(
            actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: userInfo
        ))
        XCTAssertNil(TripCompletionNotifier.responseAction(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]
        ))
        XCTAssertNil(TripCompletionNotifier.responseAction(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [TripCompletionNotifier.tripIDUserInfoKey: "not-a-uuid"]
        ))
    }

    func testClassificationResponseStillCarriesExactPurpose() throws {
        let id = UUID()
        XCTAssertEqual(TripCompletionNotifier.responseAction(
            actionIdentifier: TripCompletionNotifier.businessPurposeActionIdentifier(for: "Site visit"),
            userInfo: [TripCompletionNotifier.tripIDUserInfoKey: id.uuidString]
        ), .classify(id, .business, businessPurpose: "Site visit"))
    }

    func testDelegateAppliesClassificationToStoredTrip() async throws {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: 42),
            classification: nil,
            businessPurpose: nil,
            notes: nil
        ))
        XCTAssertTrue(trip.isUnresolved)

        await delegate.apply(.personal, toTripID: trip.id)

        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.classification, .personal)
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertEqual(model.trips.first(where: { $0.id == trip.id })?.classification, .personal)
        XCTAssertEqual(removedNotificationIDs, [trip.id])
    }

    func testDelegateAppliesExactBusinessPurposeToStoredTrip() async throws {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: 42),
            classification: nil,
            businessPurpose: nil,
            notes: nil
        ))

        await delegate.apply(
            .business,
            businessPurpose: "Site scouting",
            toTripID: trip.id
        )

        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.classification, .business)
        XCTAssertEqual(updated.businessPurpose, "Site scouting")
        XCTAssertEqual(updated.reviewStatus, .readyToExport)
        XCTAssertEqual(
            model.trips.first(where: { $0.id == trip.id })?.businessPurpose,
            "Site scouting"
        )
    }

    func testDelegateDoesNotOverrideSettledTrip() async throws {
        let trip = try model.tripStore.createManualTrip(ManualTripInput(
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            startAddress: "145 Court St, Brooklyn, NY",
            endAddress: "9 Pine St, Darien, CT",
            distanceMeters: DistanceConversion.meters(fromMiles: 5),
            classification: .personal
        ))
        XCTAssertFalse(trip.isUnresolved)

        await delegate.apply(.business, toTripID: trip.id)

        let updated = try XCTUnwrap(model.tripStore.fetchTripIfExists(id: trip.id))
        XCTAssertEqual(updated.classification, .personal)
    }

    func testDelegateIgnoresUnknownTrip() async {
        await delegate.apply(.business, toTripID: UUID())
        XCTAssertTrue(model.trips.isEmpty)
    }

    func testPreferenceDefaultsOffAndPersists() throws {
        let defaults = try makeTestDefaults()
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.tripCompletionNotificationsEnabled)
        preferences.tripCompletionNotificationsEnabled = true
        XCTAssertTrue(Preferences(defaults: defaults).tripCompletionNotificationsEnabled)
    }
}
