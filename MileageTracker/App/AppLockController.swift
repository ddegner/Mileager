import Foundation
import LocalAuthentication
import SwiftUI

/// Owns the optional app-lock state. The lock is UI-only: it gates what the
/// security overlay shows, never the capture pipeline or persistence, so
/// background drive recording is untouched while the app is locked.
@MainActor
@Observable
final class AppLockController {
    enum LockState: Equatable {
        case unlocked
        case locked
        case authenticating
    }

    private(set) var lockState: LockState
    private(set) var isEnabled: Bool
    /// Whether `.deviceOwnerAuthentication` is available (device has a
    /// passcode). Starts pessimistic; refreshed when Settings appears so init
    /// stays free of LocalAuthentication work.
    private(set) var isAvailable = false
    private(set) var biometryType: LABiometryType = .none
    /// True while a Settings-toggle auth prompt is up, so the overlay knows
    /// this `.inactive` phase is self-inflicted and skips the privacy cover.
    private(set) var isPerformingInlineAuth = false
    /// True while the app has put up a system permission prompt (Motion,
    /// Notifications, Bluetooth, Location). Like `isPerformingInlineAuth`, it
    /// marks the resulting `.inactive` phase as self-inflicted so the overlay
    /// skips the privacy cover that would otherwise flash behind the dialog.
    /// Cleared when the app returns to `.active`/`.background` or the request
    /// resolves.
    private(set) var isPresentingSystemPermissionPrompt = false
    /// Mirrors the window scene phase for the overlay; the overlay lives in
    /// its own UIWindow where `@Environment(\.scenePhase)` is not plumbed.
    private(set) var scenePhase: ScenePhase = .active

    enum OverlayMode: Equatable {
        case hidden
        case privacyCover
        case lockScreen
    }

    /// Single source of truth for what the security overlay shows. The lock
    /// screen wins while our own auth prompt is up (it doubles as the privacy
    /// cover behind the system Face ID dialog), and a Settings-toggle prompt
    /// suppresses the cover so the user still sees the toggle they tapped.
    var overlayMode: OverlayMode {
        if isEnabled, lockState != .unlocked { return .lockScreen }
        if isPerformingInlineAuth { return .hidden }
        // The app-switcher snapshot is taken on `.background`, so that is always
        // covered. `.inactive` (Control Center / notification shade) is covered
        // too — except on the Mac, where the window resigns active every time
        // it loses focus and covering on `.inactive` would blank the app
        // constantly, and except when we put up a system permission prompt
        // ourselves, whose brief `.inactive` should not flash the cover behind
        // the dialog. (Runtime check: Designed for iPhone is not Catalyst, so
        // a `#if targetEnvironment` branch would be dead code here.)
        if scenePhase == .background { return .privacyCover }
        if platform.hasLockScreen, scenePhase == .inactive, !isPresentingSystemPermissionPrompt { return .privacyCover }
        return .hidden
    }

    /// Invalidates in-flight auth attempts when the app re-enters background
    /// mid-prompt; a completion whose epoch is stale is discarded.
    @ObservationIgnored private var authEpoch = 0
    /// Set after a failed/cancelled attempt so the `.active` flutter from the
    /// dismissing system prompt doesn't immediately re-prompt in a loop.
    @ObservationIgnored private var autoPromptSuppressed = false
    @ObservationIgnored private(set) var authTask: Task<Void, Never>?

    private let preferences: Preferences
    private let authenticator: any DeviceAuthenticating
    private let platform: RunningPlatform

    init(
        preferences: Preferences,
        authenticator: any DeviceAuthenticating,
        platform: RunningPlatform = .current
    ) {
        self.preferences = preferences
        self.authenticator = authenticator
        self.platform = platform
        let enabled = preferences.appLockEnabled
        isEnabled = enabled
        lockState = enabled ? .locked : .unlocked
    }

    // MARK: - Scene lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            sceneDidBecomeActive()
        case .background:
            sceneDidEnterBackground()
        case .inactive:
            // The LocalAuthentication system prompt drives the scene to
            // `.inactive`; reacting here would re-lock mid-auth. The privacy
            // cover handles the visual side.
            break
        @unknown default:
            break
        }
    }

    func sceneDidBecomeActive() {
        // Any system permission prompt has dismissed now that we are active
        // again; drop the suppression so a later Control Center pull is covered.
        isPresentingSystemPermissionPrompt = false
        guard isEnabled, lockState == .locked, !autoPromptSuppressed else { return }
        beginAuthentication()
    }

    func sceneDidEnterBackground() {
        isPresentingSystemPermissionPrompt = false
        guard isEnabled else { return }
        // Covers `.unlocked` (normal re-lock) and `.authenticating` (the user
        // left the app mid-prompt; invalidate that attempt).
        lockState = .locked
        autoPromptSuppressed = false
        authEpoch += 1
    }

    // MARK: - System permission prompts

    /// Marks that the app is about to present a system permission prompt, so the
    /// overlay treats the resulting `.inactive` phase as self-inflicted and does
    /// not flash the privacy cover behind the dialog.
    func beginSystemPermissionPrompt() {
        isPresentingSystemPermissionPrompt = true
    }

    /// Clears the system-permission-prompt suppression. Idempotent; also cleared
    /// automatically when the scene next becomes active or backgrounded.
    func endSystemPermissionPrompt() {
        isPresentingSystemPermissionPrompt = false
    }

    // MARK: - Unlocking

    /// Explicit retry from the lock screen's Unlock button.
    func requestUnlock() {
        autoPromptSuppressed = false
        beginAuthentication()
    }

    func beginAuthentication() {
        guard lockState == .locked else { return }
        guard authenticator.canAuthenticate else {
            // No device passcode: the policy can never be satisfied, and the
            // device itself is unprotected — don't dead-end the UI.
            lockState = .unlocked
            return
        }
        lockState = .authenticating
        authEpoch += 1
        let epoch = authEpoch
        authTask = Task { [weak self] in
            var success = true
            do {
                try await self?.authenticator.authenticate(reason: "Unlock Mileager")
            } catch {
                success = false
            }
            self?.finishAuthentication(epoch: epoch, success: success)
        }
    }

    private func finishAuthentication(epoch: Int, success: Bool) {
        authTask = nil
        guard epoch == authEpoch, lockState == .authenticating else { return }
        if success {
            lockState = .unlocked
        } else {
            lockState = .locked
            autoPromptSuppressed = true
        }
    }

    // MARK: - Settings

    /// Re-query availability (the user may have set or removed a passcode
    /// since launch). Called when the Settings section appears.
    func refreshAvailability() {
        isAvailable = authenticator.canAuthenticate
        biometryType = authenticator.biometryType
    }

    /// Auth-gated in both directions: enabling proves the user can actually
    /// unlock before they get locked out; disabling stops a passerby from
    /// quietly switching protection off.
    func requestSetEnabled(_ newValue: Bool) async {
        guard newValue != isEnabled, authenticator.canAuthenticate else { return }
        isPerformingInlineAuth = true
        defer { isPerformingInlineAuth = false }
        do {
            try await authenticator.authenticate(
                reason: newValue
                    ? "Confirm you can unlock Mileager before turning on App Lock"
                    : "Authenticate to turn off App Lock"
            )
            isEnabled = newValue
            preferences.appLockEnabled = newValue
            lockState = .unlocked
        } catch {
            // isEnabled is unchanged, so the Settings toggle
            // snaps back on its own.
        }
    }
}
