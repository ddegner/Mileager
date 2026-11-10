#if canImport(AppIntentsTesting) && APP_INTENTS_SYSTEM_TESTS
import AppIntentsTesting
import XCTest

/// Held-out routing measurement. Injected recognition text bypasses the
/// microphone and is explicitly reported separately from real spoken tests.
@available(iOS 27.0, *)
@MainActor
final class SiriNaturalLanguageUITests: MileageTrackerUITestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "com.daviddegner.MileageTracker")

    private struct Corpus: Decodable {
        let cases: [Request]
    }
    private struct Request: Decodable {
        let id: String
        let utterance: String
        let expected_target: String
        let expected_category: String?
    }
    private struct Snapshot: Equatable {
        let categories: [String: String]
        let currentID: String
        let previousID: String
    }

    override var launchArguments: [String] {
        super.launchArguments + ["--test-store-suffix=siri-held-out", "--seed-current-drive"]
    }

    override func tearDown() async throws {
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        try await super.tearDown()
    }

    // Each request gets a fresh XCTest session. A Siri accessibility timeout
    // must not prevent the other held-out requests from being measured.
    func testH01() async throws { try await evaluate("H01") }
    func testH02() async throws { try await evaluate("H02") }
    func testH03() async throws { try await evaluate("H03") }
    func testH04() async throws { try await evaluate("H04") }
    func testH05() async throws { try await evaluate("H05") }
    func testH06() async throws { try await evaluate("H06") }
    func testH07() async throws { try await evaluate("H07") }
    func testH08() async throws { try await evaluate("H08") }
    func testH09() async throws { try await evaluate("H09") }
    func testH10() async throws { try await evaluate("H10") }
    func testH11() async throws { try await evaluate("H11") }
    func testH12() async throws { try await evaluate("H12") }
    func testH13() async throws { try await evaluate("H13") }
    func testH14() async throws { try await evaluate("H14") }
    func testH15() async throws { try await evaluate("H15") }
    func testH16() async throws { try await evaluate("H16") }
    func testH17() async throws { try await evaluate("H17") }
    func testH18() async throws { try await evaluate("H18") }
    func testH19() async throws { try await evaluate("H19") }
    func testH20() async throws { try await evaluate("H20") }
    func testH21() async throws { try await evaluate("H21") }
    func testH22() async throws { try await evaluate("H22") }
    func testH23() async throws { try await evaluate("H23") }
    func testH24() async throws { try await evaluate("H24") }
    func testH25() async throws { try await evaluate("H25") }
    func testH26() async throws { try await evaluate("H26") }
    func testH27() async throws { try await evaluate("H27") }
    func testH28() async throws { try await evaluate("H28") }
    func testH29() async throws { try await evaluate("H29") }
    func testH30() async throws { try await evaluate("H30") }
    func testH31() async throws { try await evaluate("H31") }
    func testH32() async throws { try await evaluate("H32") }
    func testH33() async throws { try await evaluate("H33") }
    func testH34() async throws { try await evaluate("H34") }
    func testH35() async throws { try await evaluate("H35") }
    func testH36() async throws { try await evaluate("H36") }
    func testH37() async throws { try await evaluate("H37") }
    func testH38() async throws { try await evaluate("H38") }
    func testH39() async throws { try await evaluate("H39") }
    func testH40() async throws { try await evaluate("H40") }

    private func evaluate(_ id: String) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "held-out-requests", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        let request = try XCTUnwrap(corpus.cases.first { $0.id == id })
        var results: [[String: Any]] = []
        waitForTripsScreen()
        let before = try await snapshot()
        let expectedID = request.expected_target == "current" ? before.currentID : before.previousID
        let category = try XCTUnwrap(request.expected_category)
        // Ensure a requested category always differs from the starting
        // value, so an unchanged fixture cannot pass as successful Siri.
        try await clearClassificationIfNeeded(id: expectedID, current: request.expected_target == "current", category: category)
        let baseline = try await snapshot()
        let siri = XCUIDevice.shared.siriService
        siri.activate(voiceRecognitionText: request.utterance)
        // Siri's accessibility service can time out while presenting web
        // fallback results. Capture its visible response without querying that
        // service; evaluate success from the app's actual saved state below.
        try await Task.sleep(for: .seconds(20))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = request.id + " Siri response"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.press(.home)
        app.activate()
        let tripIDs = baseline.categories.keys.filter { $0 != baseline.currentID }
        let after = try await snapshot(tripIDs: tripIDs)
        // Relaunch without resets or fixture seeding. This is persistence
        // evidence; a successful dialog alone never passes the request.
        app.terminate()
        app.launchArguments = launchArguments.filter {
            !["--reset-data", "--reset-preferences", "--seed-current-drive", "--seed-mileage-data"].contains($0)
        }
        app.launch()
        let reloaded = try await snapshot(tripIDs: tripIDs)
        let changedIDs = Set(baseline.categories.keys).union(after.categories.keys).filter {
            baseline.categories[$0] != after.categories[$0]
        }
        let noWrongMutation = changedIDs.allSatisfy { $0 == expectedID && after.categories[$0] == category }
        let executed = after.categories[expectedID] == category
        let durable = reloaded.categories[expectedID] == category
        results.append([
            "id": request.id, "expected_target_id": expectedID,
            "observed_target_id": executed ? expectedID : "",
            "observed_category": after.categories[expectedID] ?? "missing",
            "reloaded_category": reloaded.categories[expectedID] ?? "missing",
            "no_wrong_mutation": noWrongMutation,
            "correct": noWrongMutation && executed && durable,
            "routing": "not_instrumented",
            "response_evidence": "Siri screenshot retained in xcresult; 20-second response window"
        ])
        print("SIRI_HELD_OUT \(request.id): saved=\(executed) durable=\(durable) correctTarget=\(noWrongMutation)")
        attachResults(results)
    }

    private func snapshot(tripIDs: [String]? = nil) async throws -> Snapshot {
        let current = try await definitions.entities["CurrentDriveAppEntity"].suggestedEntities()
        let trips: [AnyAppEntity]
        if let tripIDs {
            trips = try await definitions.entities["TripAppEntity"].entities(identifiers: tripIDs)
        } else {
            trips = try await definitions.entities["TripAppEntity"].suggestedEntities()
        }
        let newest = try await definitions.entities["TripAppEntity"].entities(matching: "last trip")
        var categories: [String: String] = [:]
        for entity in current + trips + newest {
            let category: AnyAppEnum? = try entity.classification
            categories[entity.identifier.instanceIdentifier] = category?.rawValue ?? "unclassified"
        }
        return Snapshot(
            categories: categories,
            currentID: try XCTUnwrap(current.first?.identifier.instanceIdentifier),
            previousID: try XCTUnwrap(newest.first?.identifier.instanceIdentifier)
        )
    }

    private func clearClassificationIfNeeded(id: String, current: Bool, category: String) async throws {
        let alternate = category == "personal" ? "business" : "personal"
        let value = definitions.enums["TripClassificationAppEnum"].makeCase(alternate)
        // Establish a known different category via direct execution. This is
        // fixture setup only and is not counted as language-routing success.
        if current {
            _ = try await definitions.intents["ClassifyCurrentDriveIntent"].makeIntent(
                drive: definitions.entities["CurrentDriveAppEntity"].makeReference(identifier: id), classification: value
            ).run()
        } else {
            _ = try await definitions.intents["SetTripClassificationIntent"].makeIntent(
                trip: definitions.entities["TripAppEntity"].makeReference(identifier: id), classification: value
            ).run()
        }
    }

    private func attachResults(_ results: [[String: Any]]) {
        let payload: [String: Any] = [
            "mode": "injected_text", "app_state": "foreground", "history": "used",
            "audio_route": "none", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "results": results
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "held-out-result-\(results.first?["id"] as? String ?? "unknown").json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
