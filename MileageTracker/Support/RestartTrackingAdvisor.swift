import Foundation

/// Rations the "open Mileager once" notices for the two states where Core
/// Location refuses background location sessions.
///
/// Platform rule (CLServiceSession.h, iOS 26.5 SDK): a `CLServiceSession` must
/// be created while the app is in use, or immediately at a background launch
/// when a matching session was held before — otherwise it reports
/// `insufficientlyInUse` and live GPS delivers nothing **until the app returns
/// to the foreground**. That happens (a) after a device restart until the
/// first foreground (once-per-boot notice via `shouldNotifyForCurrentBoot`),
/// and (b) mid-boot whenever sessions are recreated from background wakes —
/// observed 2026-07-05 losing a whole drive (interval-rationed notice via
/// `shouldNotifyForTrackingRestoration`). Background *wakes* (SLC/visit/
/// geofence) still fire in both states, so the app can run these checks from a
/// wake and tell the user the one action that restores tracking.
///
/// Boot identity comes from `kern.boottime` (stable across reads, unlike
/// `ProcessInfo.systemUptime`, which excludes sleep). All bookkeeping lives in
/// `UserDefaults` — readable on any post-first-unlock launch, and the pre-unlock
/// window is unreachable anyway (iOS never background-launches apps there).
struct RestartTrackingAdvisor {
    private enum Key {
        static let lastForegroundBoot = "restartAdvisor.lastForegroundBootTime"
        static let notifiedBoot = "restartAdvisor.notifiedBootTime"
        static let lastRestorationNoticeAt = "restartAdvisor.lastRestorationNoticeAt"
    }

    private let defaults: UserDefaults
    private let bootTime: () -> Date?

    init(
        defaults: UserDefaults = .standard,
        bootTime: @escaping () -> Date? = Self.systemBootTime
    ) {
        self.defaults = defaults
        self.bootTime = bootTime
    }

    static func systemBootTime() -> Date? {
        var bootTimeValue = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTimeValue, &size, nil, 0) == 0,
              bootTimeValue.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(bootTimeValue.tv_sec))
    }

    /// Call whenever the app reaches the foreground: one foreground pass per
    /// boot is exactly what restores background location sessions.
    func recordForegrounded() {
        guard let boot = currentBootStamp() else { return }
        defaults.set(boot, forKey: Key.lastForegroundBoot)
    }

    /// True exactly once per boot, and only while the app has NOT been
    /// foregrounded since that boot. The caller supplies the third condition —
    /// a live "session unfulfilled" signal — before asking.
    func shouldNotifyForCurrentBoot() -> Bool {
        guard let boot = currentBootStamp() else { return false }
        guard defaults.double(forKey: Key.lastForegroundBoot) != boot else { return false }
        guard defaults.double(forKey: Key.notifiedBoot) != boot else { return false }
        defaults.set(boot, forKey: Key.notifiedBoot)
        return true
    }

    static let trackingRestorationNoticeMinimumInterval: TimeInterval = 6 * 60 * 60

    /// Ration for the mid-boot restoration notice (2026-07-05 incident):
    /// sessions created from background wakes were refused even though the app
    /// HAD been foregrounded this boot. Requires a foreground this boot — the
    /// never-foregrounded case belongs to `shouldNotifyForCurrentBoot` — and
    /// fires at most once per `trackingRestorationNoticeMinimumInterval` of
    /// wall clock.
    func shouldNotifyForTrackingRestoration(now: Date = Date()) -> Bool {
        guard let boot = currentBootStamp() else { return false }
        guard defaults.double(forKey: Key.lastForegroundBoot) == boot else { return false }
        let last = defaults.double(forKey: Key.lastRestorationNoticeAt)
        guard now.timeIntervalSince1970 - last >= Self.trackingRestorationNoticeMinimumInterval else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastRestorationNoticeAt)
        return true
    }

    /// Round to 10 s: `kern.boottime` is stable, but the rounding makes the
    /// stored comparison immune to any sub-second reporting jitter.
    private func currentBootStamp() -> Double? {
        guard let boot = bootTime() else { return nil }
        return (boot.timeIntervalSince1970 / 10).rounded() * 10
    }
}
