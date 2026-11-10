import Foundation
import XCTest
@testable import MileageTracker

final class RestartTrackingAdvisorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "RestartTrackingAdvisorTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    private func advisor(bootTime: Date?) -> RestartTrackingAdvisor {
        RestartTrackingAdvisor(defaults: defaults, bootTime: { bootTime })
    }

    func testNotifiesExactlyOncePerBootWhenNeverForegrounded() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        let advisor = advisor(bootTime: boot)

        XCTAssertTrue(advisor.shouldNotifyForCurrentBoot())
        XCTAssertFalse(advisor.shouldNotifyForCurrentBoot(), "second ask same boot must be rationed")
    }

    func testForegroundPassStandsTheNoticeDown() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        let advisor = advisor(bootTime: boot)

        advisor.recordForegrounded()

        XCTAssertFalse(advisor.shouldNotifyForCurrentBoot())
    }

    func testNewBootNotifiesAgainAfterEarlierForeground() {
        let firstBoot = Date(timeIntervalSince1970: 1_800_000_000)
        advisor(bootTime: firstBoot).recordForegrounded()
        XCTAssertFalse(advisor(bootTime: firstBoot).shouldNotifyForCurrentBoot())

        // Reboot: new boot time, no foreground since.
        let secondBoot = firstBoot.addingTimeInterval(86_400)
        XCTAssertTrue(advisor(bootTime: secondBoot).shouldNotifyForCurrentBoot())
        XCTAssertFalse(advisor(bootTime: secondBoot).shouldNotifyForCurrentBoot())
    }

    func testSubSecondBootTimeJitterDoesNotDefeatTheRation() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(advisor(bootTime: boot).shouldNotifyForCurrentBoot())
        XCTAssertFalse(advisor(bootTime: boot.addingTimeInterval(2)).shouldNotifyForCurrentBoot())
    }

    func testUnknownBootTimeNeverNotifies() {
        XCTAssertFalse(advisor(bootTime: nil).shouldNotifyForCurrentBoot())
    }

    func testSystemBootTimeIsPlausible() throws {
        let boot = try XCTUnwrap(RestartTrackingAdvisor.systemBootTime())
        XCTAssertLessThan(boot, Date())
        XCTAssertGreaterThan(boot, Date().addingTimeInterval(-365 * 24 * 60 * 60))
    }

    // MARK: - Mid-boot tracking-restoration notice (2026-07-05 regression)

    func testTrackingRestorationNoticeRequiresForegroundThisBoot() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        // Never foregrounded this boot: the once-per-boot reboot notice owns
        // that state, the restoration ration must decline.
        XCTAssertFalse(advisor(bootTime: boot).shouldNotifyForTrackingRestoration(now: boot.addingTimeInterval(600)))
    }

    func testTrackingRestorationNoticeFiresAfterForegroundThisBoot() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        let advisor = advisor(bootTime: boot)
        advisor.recordForegrounded()

        XCTAssertTrue(advisor.shouldNotifyForTrackingRestoration(now: boot.addingTimeInterval(600)))
    }

    func testTrackingRestorationNoticeRateLimitedByInterval() {
        let boot = Date(timeIntervalSince1970: 1_800_000_000)
        let advisor = advisor(bootTime: boot)
        advisor.recordForegrounded()
        let first = boot.addingTimeInterval(600)

        XCTAssertTrue(advisor.shouldNotifyForTrackingRestoration(now: first))
        XCTAssertFalse(advisor.shouldNotifyForTrackingRestoration(now: first.addingTimeInterval(60 * 60)),
                       "one hour later is inside the 6-hour ration")
        XCTAssertTrue(advisor.shouldNotifyForTrackingRestoration(now: first.addingTimeInterval(7 * 60 * 60)))
    }

    func testTrackingRestorationNoticeDoesNotConsumeRebootNotice() {
        let firstBoot = Date(timeIntervalSince1970: 1_800_000_000)
        let firstAdvisor = advisor(bootTime: firstBoot)
        firstAdvisor.recordForegrounded()
        XCTAssertTrue(firstAdvisor.shouldNotifyForTrackingRestoration(now: firstBoot.addingTimeInterval(600)))

        // Reboot: the once-per-boot notice must be unaffected by the mid-boot stamp.
        let secondBoot = firstBoot.addingTimeInterval(86_400)
        XCTAssertTrue(advisor(bootTime: secondBoot).shouldNotifyForCurrentBoot())
    }

    func testTrackingRestorationNoticeUnknownBootTimeNeverNotifies() {
        XCTAssertFalse(advisor(bootTime: nil).shouldNotifyForTrackingRestoration(now: Date()))
    }
}

final class ReminderSchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testMonthEndReviewFallsOnFirstDayOfNextMonthAtTenAM() throws {
        let now = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 31, hour: 18)
        ))

        let reminder = try XCTUnwrap(ReminderScheduler.monthEndReviewDate(
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder),
            DateComponents(year: 2026, month: 8, day: 1, hour: 10, minute: 0)
        )
    }

    func testMonthEndReviewRollsIntoNextYear() throws {
        let now = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 12, day: 15, hour: 9)
        ))

        let reminder = try XCTUnwrap(ReminderScheduler.monthEndReviewDate(
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder),
            DateComponents(year: 2027, month: 1, day: 1, hour: 10, minute: 0)
        )
    }
}
