import XCTest

@testable import MileageTracker

/// `--ui-shell=` and `--mac-mode=` exist so a UI test can reach states the
/// device it runs on would never produce: the split shell on an iPhone
/// simulator, and Mac mode anywhere above the model layer.
@MainActor
final class MileageAppModelShellOverrideTests: XCTestCase {
    private func makeModel(
        _ extra: [String] = [],
        uiTesting: Bool = true,
        platformOverride: RunningPlatform? = nil
    ) throws -> MileageAppModel {
        let base = uiTesting
            ? ["MileageTracker", "--uitesting", "--reset-data", "--reset-preferences", "--skip-onboarding"]
            : ["MileageTracker"]
        let preferences = try Preferences(defaults: makeTestDefaults())
        // Argument parsing does not depend on the simulator's live permission service.
        if !uiTesting { preferences.automaticTrackingEnabled = false }
        return MileageAppModel(
            arguments: appModelArguments(base + extra),
            preferences: preferences,
            platformOverride: platformOverride
        )
    }

    // MARK: - --ui-shell=

    func testShellOverrideParsesSplit() throws {
        XCTAssertEqual(try makeModel(["--ui-shell=split"]).shellOverrideForUITesting, .split)
    }

    func testShellOverrideParsesStack() throws {
        XCTAssertEqual(try makeModel(["--ui-shell=stack"]).shellOverrideForUITesting, .stack)
    }

    func testAbsentShellOverrideLeavesTheDeviceToDecide() throws {
        XCTAssertNil(try makeModel().shellOverrideForUITesting)
    }

    /// A shipping launch must never be able to pick up a shell override, even
    /// if the argument somehow reaches the process.
    func testShellOverrideIsIgnoredWithoutUITesting() throws {
        XCTAssertNil(try makeModel(["--ui-shell=split"], uiTesting: false).shellOverrideForUITesting)
    }

    // MARK: - --mac-mode=

    func testMacModeArgumentForcesMacMode() throws {
        XCTAssertEqual(try makeModel(["--mac-mode=on"]).platform, .mac)
    }

    func testMacModeArgumentCanForceMacModeOff() throws {
        XCTAssertEqual(try makeModel(["--mac-mode=off"]).platform, .iOS)
    }

    func testMacModeArgumentIsIgnoredWithoutUITesting() throws {
        XCTAssertEqual(try makeModel(["--mac-mode=on"], uiTesting: false).platform, .current)
    }

    /// Parameter-first resolution is what keeps every existing platform test
    /// byte-identical.
    func testInitParameterWinsOverTheMacModeArgument() throws {
        let model = try makeModel(["--mac-mode=on"], platformOverride: .iOS)
        XCTAssertEqual(model.platform, .iOS)
    }

    /// Proves the argument path lands in the same state the init parameter
    /// reaches, rather than merely setting a flag.
    func testMacModeArgumentSuppressesDriveCapture() throws {
        let model = try makeModel(["--mac-mode=on"])
        XCTAssertTrue(model.driveCaptureSuppressed)
        XCTAssertEqual(model.availableTrackingPermissionKinds, [.notifications])
    }

    /// The two axes are independent: an iPad suite wants the split shell with
    /// ordinary capture behavior, and only the Mac-proxy tests want both.
    func testShellAndMacModeAreIndependent() throws {
        let model = try makeModel(["--ui-shell=split"])
        XCTAssertEqual(model.shellOverrideForUITesting, .split)
        XCTAssertEqual(model.platform, .current)
    }
}
