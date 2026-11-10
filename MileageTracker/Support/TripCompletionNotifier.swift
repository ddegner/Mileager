import AppCore
import Foundation
import os
import UserNotifications
#if DEBUG
import UIKit
#endif

/// Lock Screen classification for freshly captured drives.
///
/// When a drive finishes while the app is in the background, a local
/// notification names its time and distance and offers up to two configured
/// business purposes, Personal, and Not a Drive as notification actions. The
/// actions carry no
/// `.authenticationRequired` or `.foreground` option, so a tap classifies the
/// trip straight from the Lock Screen without unlocking or opening the app;
/// iOS launches the process in the background to deliver the response.
///
/// The pure pieces (identifiers, content, action decoding) are `enum`
/// statics so they can be unit-tested without `UNUserNotificationCenter`.
enum TripCompletionNotifier {
    static let categoryIdentifier = "trip-completed"
    static let tripIDUserInfoKey = "tripID"
    private static let requestIdentifierPrefix = "trip-completed-"
    private static let businessPurposeActionIdentifierPrefix = "trip-completed.business-purpose."
    private static let maxBusinessPurposeActionCount = 2

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.localfirst.MileageTracker",
        category: "TripCompletionNotifier"
    )

    enum Action: String {
        case business = "trip-completed.business"
        case personal = "trip-completed.personal"
        case notADrive = "trip-completed.not-a-drive"

        var classification: TripClassification {
            switch self {
            case .business: .business
            case .personal: .personal
            case .notADrive: .notADrive
            }
        }

        var title: String {
            switch self {
            case .business: String(localized: "Business")
            case .personal: String(localized: "Personal")
            case .notADrive: String(localized: "Not a Drive")
            }
        }
    }

    struct ActionDefinition {
        let identifier: String
        let title: String
        let systemImageName: String
        let options: UNNotificationActionOptions
    }

    enum ResponseAction: Equatable, Sendable {
        case openTrip(UUID)
        case classify(UUID, TripClassification, businessPurpose: String?)
    }

    // MARK: - Pure helpers

    static func requestIdentifier(for tripID: UUID) -> String {
        requestIdentifierPrefix + tripID.uuidString
    }

    static func tripID(fromRequestIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(requestIdentifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(requestIdentifierPrefix.count)))
    }

    /// The purpose lives in the action identifier rather than an array index.
    /// Notification categories are global and can be re-registered after a
    /// purpose edit; encoding the value keeps the action's visible title and
    /// eventual response paired even for an older delivered notification.
    static func businessPurposeActionIdentifier(for purpose: String) -> String {
        let encoded = Data(purpose.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return businessPurposeActionIdentifierPrefix + encoded
    }

    static func businessPurpose(fromActionIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(businessPurposeActionIdentifierPrefix) else { return nil }
        var encoded = String(identifier.dropFirst(businessPurposeActionIdentifierPrefix.count))
        guard !encoded.isEmpty else { return nil }
        encoded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let purpose = String(data: data, encoding: .utf8) else { return nil }
        return TripReviewPolicy.normalizedBusinessPurpose(purpose)
    }

    static func actionDefinitions(businessPurposes: [String]) -> [ActionDefinition] {
        let purposes = Array(
            BusinessPurposePresetStore.normalized(businessPurposes)
                .prefix(maxBusinessPurposeActionCount)
        )
        let businessActions: [ActionDefinition]
        if purposes.isEmpty {
            // Preserve the existing behavior for someone who deletes every
            // preset: Business still classifies and lets the model apply its
            // normal default-purpose policy (which may leave it Needs Review).
            businessActions = [ActionDefinition(
                identifier: Action.business.rawValue,
                title: Action.business.title,
                systemImageName: "briefcase.fill",
                options: []
            )]
        } else {
            businessActions = purposes.enumerated().map { index, purpose in
                ActionDefinition(
                    identifier: businessPurposeActionIdentifier(for: purpose),
                    title: purpose,
                    systemImageName: index == 0 ? "briefcase.fill" : "briefcase",
                    options: []
                )
            }
        }
        return businessActions + [
            ActionDefinition(
                identifier: Action.personal.rawValue,
                title: Action.personal.title,
                systemImageName: "person.fill",
                options: []
            ),
            ActionDefinition(
                identifier: Action.notADrive.rawValue,
                title: Action.notADrive.title,
                systemImageName: "nosign",
                options: [.destructive]
            )
        ]
    }

    /// "8:05 – 8:31 AM · 12.3 mi". Times only — addresses are not yet geocoded
    /// when the trip is saved, and the Lock Screen is a public surface anyway.
    static func body(
        for trip: TripSummary,
        unit: DistanceUnit,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        let timeRange = (trip.startDate..<trip.endDate).formatted(
            Date.IntervalFormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
        )
        let distance = DistanceFormatting.label(
            meters: trip.distanceMeters,
            unit: unit,
            fractionDigits: 0...1,
            locale: locale
        )
        return "\(timeRange) · \(distance)"
    }

    static func makeContent(for trip: TripSummary, unit: DistanceUnit) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Drive finished")
        content.body = body(for: trip, unit: unit)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = categoryIdentifier
        content.userInfo = [tripIDUserInfoKey: trip.id.uuidString]
        return content
    }

    static func makeCategory(businessPurposes: [String] = []) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: actionDefinitions(businessPurposes: businessPurposes).map { action in
                UNNotificationAction(
                    identifier: action.identifier,
                    title: action.title,
                    options: action.options,
                    icon: UNNotificationActionIcon(systemImageName: action.systemImageName)
                )
            },
            intentIdentifiers: [],
            options: []
        )
    }

    /// The classification and exact purpose a response asks for, or nil for
    /// dismiss/default taps. The legacy/fallback Business action deliberately
    /// returns a nil purpose so the model preserves its existing defaulting.
    static func decision(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> (tripID: UUID, classification: TripClassification, businessPurpose: String?)? {
        guard let raw = userInfo[tripIDUserInfoKey] as? String,
              let tripID = UUID(uuidString: raw) else { return nil }
        if let purpose = businessPurpose(fromActionIdentifier: actionIdentifier) {
            return (tripID, .business, purpose)
        }
        guard let action = Action(rawValue: actionIdentifier) else { return nil }
        return (tripID, action.classification, nil)
    }

    static func responseAction(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> ResponseAction? {
        if actionIdentifier == UNNotificationDefaultActionIdentifier,
           let raw = userInfo[tripIDUserInfoKey] as? String,
           let tripID = UUID(uuidString: raw) {
            return .openTrip(tripID)
        }
        guard let decision = decision(actionIdentifier: actionIdentifier, userInfo: userInfo) else { return nil }
        return .classify(decision.tripID, decision.classification, businessPurpose: decision.businessPurpose)
    }

    // MARK: - UNUserNotificationCenter

    /// Registers the category. Must run before the first notification is
    /// posted; cheap enough to call at every launch.
    static func registerCategory(businessPurposes: [String] = []) {
        UNUserNotificationCenter.current().setNotificationCategories([
            makeCategory(businessPurposes: businessPurposes)
        ])
    }

    static func post(for trip: TripSummary, unit: DistanceUnit, businessPurposes: [String]) {
        // Presets can be edited or synced while the app remains alive. Refresh
        // the global category immediately before posting so this notification
        // advertises the current first two; purpose-bearing identifiers keep
        // responses exact if older delivered notifications still exist.
        registerCategory(businessPurposes: businessPurposes)
        let request = UNNotificationRequest(
            identifier: requestIdentifier(for: trip.id),
            content: makeContent(for: trip, unit: unit),
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to post trip-completed notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func remove(tripID: UUID) {
        let identifier = requestIdentifier(for: tripID)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Drops delivered prompts whose trip has since been classified, deleted,
    /// or merged in-app, so the Lock Screen never asks about a settled drive.
    static func reconcileDelivered(unresolvedTripIDs: Set<UUID>) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered
                .map(\.request.identifier)
                .filter { identifier in
                    guard let tripID = tripID(fromRequestIdentifier: identifier) else { return false }
                    return !unresolvedTripIDs.contains(tripID)
                }
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
    }

    static func removeAll() {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ours = delivered.map(\.request.identifier).filter { tripID(fromRequestIdentifier: $0) != nil }
            if !ours.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ours)
            }
        }
    }

    #if DEBUG
    /// Exercises the real system notification response in an isolated UI-test
    /// store, including returning from SpringBoard instead of app.activate().
    @MainActor
    static func scheduleUITestNotificationIfNeeded(for trips: [TripSummary]) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"),
              arguments.contains("--schedule-trip-completion-notification"),
              let trip = trips.first(where: \.isUnresolved) else { return }
        Task {
            var trace: [String] = []
            func record(_ step: String) {
                trace.append("\(Date().timeIntervalSince1970): \(step)")
                UserDefaults.standard.set(trace, forKey: "UITest.tripCompletionNotificationTrace")
            }
            record("fixture started")
            let backgroundEvents = NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification
            )
            let center = UNUserNotificationCenter.current()
            let authorized = try? await center.requestAuthorization(options: [.alert, .sound])
            record("authorization returned \(String(describing: authorized)); application state \(UIApplication.shared.applicationState.rawValue)")
            guard authorized == true else { return }
            // The test taps a real SpringBoard notification. Start its timer
            // after backgrounding so slow simulator startup cannot consume it
            // while the foreground delegate intentionally suppresses banners.
            if UIApplication.shared.applicationState != .background {
                record("waiting for background")
                for await _ in backgroundEvents { break }
            }
            record("scheduling after background")
            let request = UNNotificationRequest(
                identifier: requestIdentifier(for: trip.id),
                content: makeContent(for: trip, unit: .miles),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)
            )
            do {
                try await center.add(request)
                record("notification scheduled")
            } catch {
                record("notification scheduling failed: \(error)")
            }
        }
    }
    #endif
}

/// Receives notification action taps. The model may still be opening its
/// stores when iOS launches the app in the background to deliver the response,
/// so the handler waits briefly for `TripIntentDataProvider.availableModel()`
/// (same gate the App Intents use) before applying the classification.
@MainActor
final class TripCompletionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TripCompletionNotificationDelegate()
    private let removeNotification: (UUID) -> Void

    init(removeNotification: @escaping (UUID) -> Void = TripCompletionNotifier.remove) {
        self.removeNotification = removeNotification
        super.init()
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.localfirst.MileageTracker",
        category: "TripCompletionNotifier"
    )
    private static let modelWaitAttempts = 40
    private static let modelWaitInterval: Duration = .milliseconds(250)

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Preserve the pre-delegate behaviour: nothing is shown while the app
        // is in the foreground (the Trips list already reflects the drive).
        []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let action = TripCompletionNotifier.responseAction(
            actionIdentifier: actionIdentifier,
            userInfo: userInfo
        )
        // UIKit's default-tap completion restores the scene and its snapshot.
        // The async delegate thunk invokes it on a cooperative executor, which
        // trips UIKit's main-thread assertion while foregrounding the app.
        // Complete every response on MainActor, including dismiss/unknown taps.
        Task { @MainActor in
            if let action { await handle(action) }
            completionHandler()
        }
    }

    func handle(_ action: TripCompletionNotifier.ResponseAction) async {
        switch action {
        case let .openTrip(tripID):
            guard let model = await waitForModel() else {
                Self.logger.error("Trip store unavailable; could not open notification trip")
                return
            }
            do {
                guard try model.tripStore.fetchTripIfExists(id: tripID) != nil else { return }
                // Queue navigation without waiting for scene activation or
                // authentication: iOS must be free to finish the response and
                // bring the app forward. The security overlay still owns access.
                model.requestOpenTrip(id: tripID)
            } catch {
                Self.logger.error("Opening notification trip failed: \(error.localizedDescription, privacy: .public)")
            }
        case let .classify(tripID, classification, businessPurpose):
            await apply(classification, businessPurpose: businessPurpose, toTripID: tripID)
        }
    }

    func apply(
        _ classification: TripClassification,
        businessPurpose: String? = nil,
        toTripID tripID: UUID
    ) async {
        guard let model = await waitForModel() else {
            Self.logger.error("Trip store unavailable; dropped Lock Screen classification for \(tripID.uuidString, privacy: .public)")
            return
        }
        do {
            guard let trip = try model.tripStore.fetchTripIfExists(id: tripID) else {
                Self.logger.notice("Trip \(tripID.uuidString, privacy: .public) no longer exists; ignoring Lock Screen classification")
                removeNotification(tripID)
                return
            }
            // The Lock Screen only fills in a blank: a prompt that outlived an
            // in-app or synced decision must not overwrite the newer one.
            guard trip.isUnresolved else {
                removeNotification(tripID)
                return
            }
            _ = try model.applyClassification(
                to: trip,
                classification: classification,
                purpose: classification == .business ? businessPurpose : nil
            )
            removeNotification(tripID)
        } catch {
            Self.logger.error("Lock Screen classification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func waitForModel() async -> MileageAppModel? {
        for _ in 0..<Self.modelWaitAttempts {
            if let model = TripIntentDataProvider.availableModel() { return model }
            try? await Task.sleep(for: Self.modelWaitInterval)
        }
        return TripIntentDataProvider.availableModel()
    }
}
