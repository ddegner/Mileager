import SwiftUI
import UIKit
import os

/// Puts a first responder in the view hierarchy that vends the app's
/// `UndoManager`, which is what makes shake-to-undo, three-finger swipe, and
/// three-finger double-tap reach the app at all.
///
/// ## Why a first responder and not the app delegate
///
/// The obvious approach — make `AppDelegate` a `UIResponder` and override
/// `undoManager`, since every responder chain terminates at
/// `UIWindow → UIApplication → delegate` — was built and **measured on device:
/// shake produced no alert.** UIKit delivers the shake motion event to the first
/// responder and does not walk all the way to the delegate when nothing is
/// editing. A real first responder does receive it (verified via `motionEnded`),
/// so this is the design that works.
///
/// ## Text fields still win, which is correct
///
/// A focused `UITextField` overrides `undoManager` with its own field editor and
/// sits closer to the front of the chain, so shaking while editing produces
/// "Undo Typing" rather than reverting a trip — confirmed on device. This
/// controller only reclaims first responder once the field resigns, and never
/// steals it from a live one.
struct UndoResponderBridge: UIViewControllerRepresentable {
    let coordinator: TripUndoCoordinator

    func makeUIViewController(context: Context) -> UndoResponderViewController {
        UndoResponderViewController(coordinator: coordinator)
    }

    func updateUIViewController(_ controller: UndoResponderViewController, context _: Context) {
        controller.coordinator = coordinator
        // Navigation pushes and SwiftUI view updates can quietly move
        // first-responder status elsewhere, and there is no notification for
        // "the first responder changed". This runs on every re-evaluation of the
        // root view, which is the most reliable hook available, and it is just a
        // boolean check when nothing has moved.
        controller.claimFirstResponderIfNeeded()
    }
}

final class UndoResponderViewController: UIViewController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MileageTracker",
        category: "undo"
    )

    var coordinator: TripUndoCoordinator

    /// Keyboard visibility protects input hosted outside our window. It is not
    /// a substitute for checking focus: a field can be editing before the
    /// keyboard appears, or while a hardware keyboard hides the software one.
    private var isKeyboardVisible = false

    init(coordinator: TripUndoCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var undoManager: UndoManager? { coordinator.undoManager }

    /// Diagnostic breadcrumb. This feature has no visible UI, so this log line
    /// is the only field signal that the gesture path is alive — and during
    /// development it is what distinguishes "the shake never arrived" from
    /// "it arrived and the stack was empty", which look identical on screen.
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            Self.logger.notice(
                """
                shake received: firstResponder=\(self.isFirstResponder, privacy: .public) \
                canUndo=\(self.undoManager?.canUndo ?? false, privacy: .public)
                """
            )
        }
        super.motionEnded(motion, with: event)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The 1x1 host must not intercept touches; it exists only to hold
        // first-responder status.
        view.isUserInteractionEnabled = false
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification, object: nil
        )
        // The keyboard hiding may mean a text input released focus and
        // there is a gap for us to reclaim. App activation is the other case:
        // a scene change can leave first-responder status elsewhere with no
        // keyboard event at all.
        for name in [UIResponder.keyboardDidHideNotification,
                     UIApplication.didBecomeActiveNotification] {
            center.addObserver(
                self, selector: #selector(focusMayBeAvailable), name: name, object: nil
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        claimFirstResponder()
    }

    @objc private func keyboardWillShow() {
        isKeyboardVisible = true
    }

    /// Deferred to the next turn of the main queue: at notification time the
    /// resigning text input is often still the first responder, so claiming
    /// immediately would fail.
    @objc private func focusMayBeAvailable() {
        isKeyboardVisible = false
        DispatchQueue.main.async { [weak self] in
            self?.claimFirstResponder()
        }
    }

    func claimFirstResponderIfNeeded() {
        claimFirstResponder()
    }

    private func claimFirstResponder() {
        guard let window = view.window, !isFirstResponder, !isKeyboardVisible,
              !window.containsFocusedTextInput else { return }
        let became = becomeFirstResponder()
        Self.logger.notice("bridge reclaimed firstResponder=\(became, privacy: .public)")
    }
}

private extension UIView {
    var containsFocusedTextInput: Bool {
        if isFirstResponder, self is UIKeyInput { return true }
        return subviews.contains { $0.containsFocusedTextInput }
    }
}
