import Foundation
import LocalAuthentication

/// Seam over `LAContext` so `AppLockController` can be unit-tested with
/// scripted auth outcomes and so UI-testing runs can force the feature
/// unavailable.
protocol DeviceAuthenticating: Sendable {
    /// Whether `.deviceOwnerAuthentication` can be evaluated — false when the
    /// device has no passcode set.
    var canAuthenticate: Bool { get }
    var biometryType: LABiometryType { get }
    /// Evaluates `.deviceOwnerAuthentication` (biometrics with device-passcode
    /// fallback). Returns on success, throws on failure or cancel.
    func authenticate(reason: String) async throws
}

struct DeviceAuthenticator: DeviceAuthenticating {
    // LAContext caches policy evaluation state, and a context that has
    // evaluated once should not be reused — create a fresh one per call.
    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    func authenticate(reason: String) async throws {
        // The async overload throws on failure/cancel; the Bool is redundant.
        _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// Used in UI-testing/preview mode so the lock can never engage there.
struct UnavailableAuthenticator: DeviceAuthenticating {
    var canAuthenticate: Bool { false }
    var biometryType: LABiometryType { .none }

    func authenticate(reason: String) async throws {
        throw LAError(.passcodeNotSet)
    }
}

/// Used by App Store screenshot runs so Settings shows the App Lock toggle in
/// its normal Face ID presentation instead of the disabled passcode-footer
/// state. The lock stays off (`appLockEnabled` is never seeded true), so this
/// never gates the screenshot run.
struct ScreenshotPresentationAuthenticator: DeviceAuthenticating {
    var canAuthenticate: Bool { true }
    var biometryType: LABiometryType { .faceID }

    func authenticate(reason: String) async throws {}
}
