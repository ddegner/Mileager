import UIKit
import XCTest
@testable import MileageTracker

@MainActor
final class UndoResponderBridgeTests: XCTestCase {
    private var window: UIWindow!
    private var previousKeyWindow: UIWindow?
    private var root: UIViewController!
    private var bridge: UndoResponderViewController!

    override func setUp() async throws {
        try await super.setUp()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.keyWindow
        window = UIWindow(windowScene: scene)
        root = UIViewController()
        window.rootViewController = root
        bridge = UndoResponderViewController(coordinator: TripUndoCoordinator())
        root.addChild(bridge)
        root.view.addSubview(bridge.view)
        bridge.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        bridge.didMove(toParent: root)
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.endEditing(true)
        window.isHidden = true
        previousKeyWindow?.makeKey()
        bridge = nil
        root = nil
        window = nil
        previousKeyWindow = nil
        try await super.tearDown()
    }

    func testRootUpdatePreservesTextFieldFocusWithoutSoftwareKeyboard() {
        let field = UITextField()
        focus(field)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        bridge.claimFirstResponderIfNeeded()

        XCTAssertTrue(field.isFirstResponder, "A root update must not take focus from the active text field.")
        XCTAssertFalse(bridge.isFirstResponder)
    }

    func testRootUpdatePreservesSearchFieldFocusWithoutSoftwareKeyboard() {
        let field = UISearchTextField()
        focus(field)
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        bridge.claimFirstResponderIfNeeded()

        XCTAssertTrue(field.isFirstResponder, "Search must retain typing and text-selection commands.")
    }

    func testSceneActivationPreservesTextViewFocus() async {
        let field = UITextView()
        focus(field)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await nextMainQueueTurn()

        XCTAssertTrue(field.isFirstResponder, "Returning to the app must preserve the notes editor's focus.")
    }

    func testUndoResponderReturnsAfterTextEditingEnds() async {
        let field = UITextField()
        focus(field)
        XCTAssertTrue(field.resignFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        await nextMainQueueTurn()

        XCTAssertTrue(bridge.isFirstResponder, "Trip undo must work again once typing has ended.")
        XCTAssertTrue(bridge.undoManager === bridge.coordinator.undoManager)
    }

    private func focus(_ field: UIView) {
        field.frame = CGRect(x: 30, y: 100, width: 250, height: 50)
        root.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertTrue(field.isFirstResponder)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
