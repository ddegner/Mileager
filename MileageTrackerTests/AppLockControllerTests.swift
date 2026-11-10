import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
import XCTest
@testable import MileageTracker

@MainActor
final class AppLockControllerTests: XCTestCase {
    private final class MockAuthenticator: DeviceAuthenticating, @unchecked Sendable {
        var canAuthenticate = true
        var biometryType: LABiometryType = .faceID
        /// Scripted outcomes consumed in order; empty list means success.
        var results: [Result<Void, Error>] = []
        var deferCompletion = false
        private(set) var callCount = 0
        private(set) var pendingContinuations: [CheckedContinuation<Void, Error>] = []

        func authenticate(reason: String) async throws {
            callCount += 1
            if deferCompletion {
                try await withCheckedThrowingContinuation { pendingContinuations.append($0) }
                return
            }
            guard !results.isEmpty else { return }
            try results.removeFirst().get()
        }

        func resumePending(success: Bool) {
            guard !pendingContinuations.isEmpty else { return }
            let continuation = pendingContinuations.removeFirst()
            if success {
                continuation.resume(returning: ())
            } else {
                continuation.resume(throwing: LAError(.userCancel))
            }
        }
    }

    private func makeController(
        authenticator: MockAuthenticator = MockAuthenticator(),
        lockEnabled: Bool = false,
        platform: RunningPlatform = .iOS
    ) throws -> (AppLockController, MockAuthenticator, Preferences) {
        let preferences = Preferences(defaults: try makeTestDefaults())
        preferences.appLockEnabled = lockEnabled
        let controller = AppLockController(
            preferences: preferences,
            authenticator: authenticator,
            platform: platform
        )
        return (controller, authenticator, preferences)
    }

    /// Spins until the controller's auth task has registered its continuation
    /// with the mock, so the test can interleave scene events mid-prompt.
    private func waitForPendingAuth(_ authenticator: MockAuthenticator) async {
        while authenticator.pendingContinuations.isEmpty {
            await Task.yield()
        }
    }

    func testDefaultsToDisabledAndUnlocked() throws {
        let (controller, authenticator, _) = try makeController()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.lockState, .unlocked)

        controller.sceneDidEnterBackground()

        XCTAssertEqual(controller.lockState, .unlocked)
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testColdLaunchWithLockEnabledStartsLocked() throws {
        let (controller, _, _) = try makeController(lockEnabled: true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.lockState, .locked)
    }

    func testEnableRequiresSuccessfulAuth() async throws {
        let (controller, authenticator, preferences) = try makeController()

        authenticator.results = [.failure(LAError(.userCancel))]
        await controller.requestSetEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(preferences.appLockEnabled)

        authenticator.results = [.success(())]
        await controller.requestSetEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(preferences.appLockEnabled)
        XCTAssertEqual(controller.lockState, .unlocked, "Enabling must not lock immediately")
    }

    func testDisableRequiresSuccessfulAuth() async throws {
        let (controller, authenticator, preferences) = try makeController(lockEnabled: true)

        authenticator.results = [.failure(LAError(.userCancel))]
        await controller.requestSetEnabled(false)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(preferences.appLockEnabled)

        authenticator.results = [.success(())]
        await controller.requestSetEnabled(false)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(preferences.appLockEnabled)
    }

    func testLocksOnBackground() async throws {
        let (controller, authenticator, _) = try makeController()
        authenticator.results = [.success(())]
        await controller.requestSetEnabled(true)
        XCTAssertEqual(controller.lockState, .unlocked)

        controller.sceneDidEnterBackground()

        XCTAssertEqual(controller.lockState, .locked)
    }

    func testActiveWhileLockedAutoPromptsAndUnlocks() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        authenticator.results = [.success(())]

        controller.sceneDidBecomeActive()
        XCTAssertEqual(controller.lockState, .authenticating)
        await controller.authTask?.value

        XCTAssertEqual(controller.lockState, .unlocked)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testFailureLeavesLockedAndSuppressesAutoPrompt() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        authenticator.results = [.failure(LAError(.userCancel))]

        controller.sceneDidBecomeActive()
        await controller.authTask?.value
        XCTAssertEqual(controller.lockState, .locked)
        XCTAssertEqual(authenticator.callCount, 1)

        // The dismissing prompt flutters the scene back to active; that must
        // not re-prompt in a loop.
        controller.sceneDidBecomeActive()
        XCTAssertEqual(controller.lockState, .locked)
        XCTAssertEqual(authenticator.callCount, 1)

        // The Unlock button is an explicit retry and clears the suppression.
        authenticator.results = [.success(())]
        controller.requestUnlock()
        await controller.authTask?.value
        XCTAssertEqual(controller.lockState, .unlocked)
        XCTAssertEqual(authenticator.callCount, 2)
    }

    func testInactiveDuringAuthDoesNotRelockOrReprompt() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        authenticator.deferCompletion = true

        controller.sceneDidBecomeActive()
        await waitForPendingAuth(authenticator)
        let task = controller.authTask

        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.lockState, .authenticating)

        controller.sceneDidBecomeActive()
        XCTAssertEqual(authenticator.callCount, 1, "Re-activation after our own prompt must not double-prompt")

        authenticator.resumePending(success: true)
        await task?.value
        XCTAssertEqual(controller.lockState, .unlocked)
    }

    func testBackgroundDuringAuthInvalidatesInFlightAttempt() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        authenticator.deferCompletion = true

        controller.sceneDidBecomeActive()
        await waitForPendingAuth(authenticator)
        let task = controller.authTask

        controller.sceneDidEnterBackground()
        XCTAssertEqual(controller.lockState, .locked)

        // The original attempt completing successfully after the app was
        // backgrounded must be discarded.
        authenticator.resumePending(success: true)
        await task?.value
        XCTAssertEqual(controller.lockState, .locked)
    }

    func testNoPasscodeUnlocksInsteadOfDeadEnding() throws {
        let authenticator = MockAuthenticator()
        authenticator.canAuthenticate = false
        let (controller, _, _) = try makeController(authenticator: authenticator, lockEnabled: true)

        controller.sceneDidBecomeActive()

        XCTAssertEqual(controller.lockState, .unlocked)
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testUnavailableAuthenticatorDisablesFeature() async throws {
        let authenticator = MockAuthenticator()
        authenticator.canAuthenticate = false
        let (controller, _, preferences) = try makeController(authenticator: authenticator)

        controller.refreshAvailability()
        XCTAssertFalse(controller.isAvailable)

        await controller.requestSetEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(preferences.appLockEnabled)
        XCTAssertEqual(authenticator.callCount, 0)
    }

    func testUITestingModeForcesLockUnavailable() throws {
        let defaults = try makeTestDefaults()
        let model = MileageAppModel(
            arguments: appModelArguments(["MileageTracker", "--uitesting", "--reset-data", "--skip-onboarding"]),
            preferences: Preferences(defaults: defaults)
        )

        model.appLock.refreshAvailability()

        XCTAssertFalse(model.appLock.isAvailable)
        XCTAssertFalse(model.appLock.isEnabled)
        XCTAssertEqual(model.appLock.lockState, .unlocked)
    }

    // MARK: - Overlay mode

    private func makeSecurityWindow(
        for controller: AppLockController
    ) throws -> (SecurityOverlayWindowPresenter, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached })
        let existing = Set(scene.windows.map(ObjectIdentifier.init))
        let presenter = SecurityOverlayWindowPresenter()
        presenter.ensureWindow(appLock: controller)
        let window = try XCTUnwrap(scene.windows.first {
            !existing.contains(ObjectIdentifier($0))
        })
        window.layoutIfNeeded()
        return (presenter, window)
    }

    func testSecurityWindowReleasesTouchesAfterCancelledAuthenticationIsRetried() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        let (presenter, window) = try makeSecurityWindow(for: controller)
        defer { window.isHidden = true }
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        XCTAssertNotNil(window.hitTest(point, with: nil))

        authenticator.results = [.failure(LAError(.userCancel))]
        controller.handleScenePhaseChange(.active)
        await controller.authTask?.value
        controller.handleScenePhaseChange(.inactive)
        controller.handleScenePhaseChange(.active)
        XCTAssertEqual(controller.lockState, .locked)
        XCTAssertNotNil(window.hitTest(point, with: nil), "Cancel must keep trips protected")

        controller.requestUnlock()
        await controller.authTask?.value
        XCTAssertEqual(controller.overlayMode, .hidden)
        // Let the hosted SwiftUI cover update, as it does on the phone.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(window.hitTest(point, with: nil), "The invisible security window must not swallow taps")
        withExtendedLifetime(presenter) {}
    }

    func testSecurityWindowBlocksTouchesWhenAnUnlockedAppRelocks() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)
        controller.requestUnlock()
        await controller.authTask?.value
        let (presenter, window) = try makeSecurityWindow(for: controller)
        defer { window.isHidden = true }
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        XCTAssertNil(window.hitTest(point, with: nil))

        authenticator.results = [.failure(LAError(.userCancel))]
        controller.handleScenePhaseChange(.background)
        controller.handleScenePhaseChange(.active)
        await controller.authTask?.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.overlayMode, .lockScreen)
        XCTAssertNotNil(window.hitTest(point, with: nil), "A relocked window must intercept touches")
        withExtendedLifetime(presenter) {}
    }

    func testOverlayModeShowsPrivacyCoverWhenInactive() throws {
        let (controller, _, _) = try makeController()

        XCTAssertEqual(controller.overlayMode, .hidden)

        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .privacyCover)

        controller.handleScenePhaseChange(.background)
        XCTAssertEqual(controller.overlayMode, .privacyCover)

        controller.handleScenePhaseChange(.active)
        XCTAssertEqual(controller.overlayMode, .hidden)
    }

    func testSystemPermissionPromptSuppressesInactivePrivacyCover() throws {
        let (controller, _, _) = try makeController()

        controller.beginSystemPermissionPrompt()
        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .hidden)

        controller.handleScenePhaseChange(.background)
        XCTAssertEqual(controller.overlayMode, .privacyCover)
    }

    func testReturningActiveClearsPermissionPromptSuppression() throws {
        let (controller, _, _) = try makeController()

        controller.beginSystemPermissionPrompt()
        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .hidden)

        controller.handleScenePhaseChange(.active)
        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .privacyCover)
    }

    func testEndSystemPermissionPromptRestoresCoverWhileInactive() throws {
        let (controller, _, _) = try makeController()

        controller.beginSystemPermissionPrompt()
        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .hidden)

        controller.endSystemPermissionPrompt()
        XCTAssertEqual(controller.overlayMode, .privacyCover)
    }

    func testMacInactiveDoesNotShowPrivacyCover() throws {
        // On the Mac the window resigns active every time it loses focus;
        // covering on .inactive would blank the app constantly.
        let (controller, _, _) = try makeController(platform: .mac)

        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .hidden)
    }

    func testMacBackgroundStillShowsPrivacyCover() throws {
        let (controller, _, _) = try makeController(platform: .mac)

        controller.handleScenePhaseChange(.background)
        XCTAssertEqual(controller.overlayMode, .privacyCover)
    }

    func testMacLockScreenStillWinsWhileLocked() throws {
        let (controller, _, _) = try makeController(lockEnabled: true, platform: .mac)

        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .lockScreen)
    }

    func testOverlayModeLockScreenWinsWhileLocked() async throws {
        let (controller, authenticator, _) = try makeController(lockEnabled: true)

        XCTAssertEqual(controller.overlayMode, .lockScreen)

        // While our own prompt drives the scene inactive, the lock screen
        // still wins (it doubles as the privacy cover).
        authenticator.deferCompletion = true
        controller.sceneDidBecomeActive()
        await waitForPendingAuth(authenticator)
        controller.handleScenePhaseChange(.inactive)
        XCTAssertEqual(controller.overlayMode, .lockScreen)

        authenticator.resumePending(success: true)
        await controller.authTask?.value
        controller.handleScenePhaseChange(.active)
        XCTAssertEqual(controller.overlayMode, .hidden)
    }
}
