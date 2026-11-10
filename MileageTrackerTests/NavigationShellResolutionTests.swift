import SwiftUI
import UIKit
import XCTest

@testable import MileageTracker

/// The shell rule had no coverage at all while it lived as a private computed
/// property on `ContentView`, and its two toolbar gates encode real Mac bugs:
/// a `.bottomBar` group laid an invisible `UIToolbar` across the whole sidebar
/// and made it inert, and the sidebar's top toolbar renders in the Mac
/// titlebar strip where it never delivers clicks.
final class NavigationShellResolutionTests: XCTestCase {
    private func shell(
        _ sizeClass: UserInterfaceSizeClass?,
        _ idiom: UIUserInterfaceIdiom,
        forced: NavigationShell? = nil
    ) -> NavigationShell {
        NavigationShellResolution.shell(
            for: NavigationShellContext(
                horizontalSizeClass: sizeClass,
                idiom: idiom,
                forcedShell: forced
            )
        )
    }

    // MARK: - The shipping rule

    func testRegularWidthOnPadUsesSplitShell() {
        XCTAssertEqual(shell(.regular, .pad), .split)
    }

    /// A "Designed for iPad" app on Apple silicon reports `.pad`, not `.mac`,
    /// so this is belt-and-braces: whichever the system claims, wide is split.
    func testRegularWidthOnMacIdiomUsesSplitShell() {
        XCTAssertEqual(shell(.regular, .mac), .split)
    }

    /// The landscape Max-class iPhone. It DOES report regular width, and had
    /// zero coverage before this file. Gating on the raw size class here
    /// silently gives phones the split view — or strips the stack's toolbar of
    /// its Settings gear and Add Trip button, which have no substitute there.
    func testRegularWidthOnPhoneUsesStackShell() {
        XCTAssertEqual(shell(.regular, .phone), .stack)
    }

    /// iPad in Slide Over.
    func testCompactWidthOnPadUsesStackShell() {
        XCTAssertEqual(shell(.compact, .pad), .stack)
    }

    func testCompactWidthOnPhoneUsesStackShell() {
        XCTAssertEqual(shell(.compact, .phone), .stack)
    }

    /// The rule tests FOR `.regular` rather than against `.compact` precisely
    /// so the nil first pass cannot briefly mount a split view and then swap.
    func testNilSizeClassUsesStackShellOnEveryIdiom() {
        for idiom: UIUserInterfaceIdiom in [.phone, .pad, .mac, .tv, .carPlay, .unspecified] {
            XCTAssertEqual(shell(nil, idiom), .stack, "idiom \(idiom.rawValue)")
        }
    }

    /// Pins that the rule is "not phone" rather than an allowlist, so a new
    /// idiom fails open to the wide layout instead of the phone's.
    func testUnspecifiedIdiomAtRegularWidthUsesSplitShell() {
        XCTAssertEqual(shell(.regular, .unspecified), .split)
    }

    // MARK: - The UI-testing override

    func testForcedSplitOverridesPhoneAndCompactWidth() {
        XCTAssertEqual(shell(.compact, .phone, forced: .split), .split)
    }

    func testForcedStackOverridesRegularWidthOnPad() {
        XCTAssertEqual(shell(.regular, .pad, forced: .stack), .stack)
    }

    /// Otherwise a forced-split UI test flashes the stack on the nil pass and
    /// races its own first assertion.
    func testForcedShellAppliesBeforeSizeClassArrives() {
        XCTAssertEqual(shell(nil, .pad, forced: .split), .split)
    }

    // MARK: - "Has the environment settled?" is a different question

    func testEnvironmentIsUnsettledUntilSizeClassArrives() {
        XCTAssertFalse(NavigationShellResolution.isEnvironmentSettled(
            NavigationShellContext(horizontalSizeClass: nil, idiom: .pad)
        ))
        XCTAssertTrue(NavigationShellResolution.isEnvironmentSettled(
            NavigationShellContext(horizontalSizeClass: .compact, idiom: .phone)
        ))
    }

    /// A forced shell must not make the environment look settled: the launch
    /// redirect would then run an ordering that ships to nobody.
    func testForcedShellDoesNotMakeTheEnvironmentLookSettled() {
        XCTAssertFalse(NavigationShellResolution.isEnvironmentSettled(
            NavigationShellContext(horizontalSizeClass: nil, idiom: .pad, forcedShell: .split)
        ))
    }
}
