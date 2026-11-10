import Foundation
import os
import UserNotifications

enum ReminderScheduler {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.localfirst.MileageTracker",
        category: "ReminderScheduler"
    )

    static func requestAuthorization(completion: (@Sendable () -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            completion?()
        }
    }

    static func authorizationState(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    static func authorizationStatus(completion: @escaping @Sendable (Bool) -> Void) {
        authorizationState { status in
            switch status {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .denied, .notDetermined:
                completion(false)
            @unknown default:
                completion(false)
            }
        }
    }

    static func scheduleMonthEndReview(unresolvedCount: Int, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["month-end-mileage-review"])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Review mileage")
        if unresolvedCount > 0 {
            content.body = String(localized: "Review \(unresolvedCount) unresolved trips and export last month's report.")
        } else {
            content.body = String(localized: "Export last month's mileage report.")
        }
        content.sound = .default

        guard let triggerDate = monthEndReviewDate(now: now) else { return }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)

        let request = UNNotificationRequest(
            identifier: "month-end-mileage-review",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        center.add(request) { error in
            if let error {
                logger.error("Failed to schedule month-end reminder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Twice a year is all the IRS needs: a New Year reading anchors both tax
    /// years, and a mid-year reading keeps report interpolation honest.
    static func scheduleOdometerReadingReminders(multipleVehicles: Bool = false) {
        let center = UNUserNotificationCenter.current()
        let identifiersByMonth = [
            ("odometer-reading-january", 1),
            ("odometer-reading-july", 7)
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiersByMonth.map(\.0))

        for (identifier, month) in identifiersByMonth {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Log your odometer reading")
            content.body = multipleVehicles
                ? String(localized: "Enter each vehicle's current mileage in Mileager. Two readings a year keep report estimates accurate.")
                : String(localized: "Enter your car's current mileage in Mileager. Two readings a year keep report estimates accurate.")
            content.sound = .default

            var components = DateComponents()
            components.month = month
            components.day = 1
            components.hour = 9

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
            center.add(request) { error in
                if let error {
                    logger.error("Failed to schedule odometer reminder: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Post-restart notice: iOS won't honor background location sessions until
    /// the app is foregrounded once per boot, so one tap here restores
    /// automatic tracking. Delivered immediately (no trigger); rationed to
    /// once per boot by `RestartTrackingAdvisor`.
    static func postRestartTrackingNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["restart-tracking-notice"])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Automatic tracking is limited")
        content.body = String(localized: "Your device restarted. Open Mileager once to restore automatic drive tracking.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "restart-tracking-notice",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logger.error("Failed to post restart tracking notice: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Mid-boot restoration notice: iOS stopped honoring background location
    /// sessions during an active drive even though the app has run this boot
    /// (2026-07-05 incident). One tap restores delivery within seconds.
    /// Distinct identifier and copy from the post-restart notice; rationed by
    /// `RestartTrackingAdvisor.shouldNotifyForTrackingRestoration`.
    static func postRestoreTrackingNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["restore-tracking-notice"])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Trip tracking needs attention")
        content.body = String(localized: "Background tracking paused on this device. Open Mileager once to restore automatic drive tracking.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "restore-tracking-notice",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logger.error("Failed to post restore tracking notice: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Schedules the review after the month is complete, preserving the
    /// 10 a.m. delivery time on the first day of the next month.
    static func monthEndReviewDate(now: Date, calendar: Calendar = .current) -> Date? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: now) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: monthInterval.end)
        components.hour = 10
        components.minute = 0
        return calendar.date(from: components)
    }
}
