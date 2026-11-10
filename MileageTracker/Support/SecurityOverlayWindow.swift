import SwiftUI
import UIKit

/// Hosts `AppSecurityOverlay` in its own window above every presented sheet.
/// A root-view overlay would render *below* SwiftUI sheet presentations, so
/// the app-switcher snapshot would leak sheet content and an open sheet
/// would stay tappable above the lock screen. The system Face ID dialog
/// lives in its own higher system window and always appears on top.
@MainActor
final class SecurityOverlayWindowPresenter {
    private var window: PassThroughWindow?

    func ensureWindow(appLock: AppLockController) {
        if let window, window.windowScene != nil { return }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else { return }

        let window = PassThroughWindow(windowScene: scene)

        // Read the current lock state for every touch. An onChange modifier
        // constructed here captures the initial mode: the hosted cover can
        // redraw independently while that modifier's value never changes.
        // Caching the touch policy there leaves an invisible blocking window
        // after unlock, or a pass-through window after the app relocks.
        window.shouldInterceptTouches = { appLock.overlayMode == .lockScreen }
        let hosting = UIHostingController(rootView: AppSecurityOverlay(appLock: appLock))
        hosting.view.backgroundColor = .clear

        window.rootViewController = hosting
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isHidden = false
        self.window = window
    }
}

private final class PassThroughWindow: UIWindow {
    var shouldInterceptTouches: () -> Bool = { true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        shouldInterceptTouches() ? super.hitTest(point, with: event) : nil
    }
}
