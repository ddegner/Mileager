import Foundation

/// Which of the two kinds of machine this one binary is running on.
///
/// The app used to say this three ways — `MileageAppModel.isMacMode`, a
/// threaded `deviceIsMac: Bool`, and raw `ProcessInfo.processInfo.isiOSAppOnMac`
/// — so a reader had to know all three to find every place behavior forks.
///
/// Note there is no `iPad` case, and that is not an oversight: iPhone and iPad
/// run the identical capture pipeline, the identical permissions, and the
/// identical intents. What differs between them is the *shell* — which
/// navigation container is mounted — and that is `NavigationShell`'s job, on a
/// separate axis. Adding an `iPad` case here would invite gating capture
/// behavior on the idiom, which is never correct.
enum RunningPlatform: Sendable, Equatable {
    /// iPhone or iPad. Both capture drives.
    case iOS
    /// The same binary on Apple silicon, "Designed for iPad".
    case mac

    /// Resolved once, at first use.
    ///
    /// `isiOSAppOnMac` cannot change while the process lives, so every reader
    /// may treat this as a constant. That is what lets `macSheetFrame()` branch
    /// without ever switching a sheet's structural identity mid-presentation
    /// and discarding its `@State`.
    static let current = RunningPlatform(isRunningOnMac: ProcessInfo.processInfo.isiOSAppOnMac)

    init(isRunningOnMac: Bool) {
        self = isRunningOnMac ? .mac : .iOS
    }

    /// For copy and layout that simply differs by machine.
    var isMac: Bool { self == .mac }

    /// A Mac never captures: no tracker bootstrap, no spooled-signal drain, no
    /// wake keeper, and no location/motion/Bluetooth permission rows, which
    /// would prompt for access that can never pay off.
    var capturesDrives: Bool { self == .iOS }

    /// Exports land in a `.fileExporter` save panel here and the activity
    /// sheet elsewhere.
    var exportsThroughSavePanel: Bool { self == .mac }

    /// Mac windows have no Lock Screen, so no Live Activity and no
    /// drive-completion classification prompt.
    var hasLockScreen: Bool { self == .iOS }
}
