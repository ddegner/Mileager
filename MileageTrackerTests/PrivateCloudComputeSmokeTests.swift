import AppCore
import Foundation
import XCTest

#if os(iOS) && compiler(>=6.4)
import FoundationModels

/// On-device smoke tests for the Private Cloud Compute suggestion path.
/// Compiled only under the iOS 27 SDK (Swift 6.4 fence) — release-toolchain
/// builds skip this file entirely — and skipped at runtime below iOS 27 or
/// when PCC is unavailable (no entitlement, Apple Intelligence off, quota).
/// Run explicitly on a beta device:
///   DEVELOPER_DIR=/Applications/Xcode-beta.app xcodebuild test ... \
///     -only-testing:MileageTrackerTests/PrivateCloudComputeSmokeTests
final class PrivateCloudComputeSmokeTests: XCTestCase {
    /// Mirror of the provider's fileprivate SuggestionOutput.
    @Generable
    struct SuggestionOutput {
        @Guide(description: "ID of the one calendar event that best explains this trip, or none", .anyOf(["none", "L1", "L2", "L3", "C1", "C2", "C3", "C4"]))
        var citedEventID: String
        @Guide(description: "What kind of engagement the cited event's title describes", .anyOf(["none", "work-engagement", "personal", "ambiguous"]))
        var citedEventNature: String
        @Guide(description: "Most likely classification for this trip", .anyOf(["business", "personal"]))
        var classification: String
        @Guide(description: "Short business purpose, only when business — derived from the cited calendar event when there is one; otherwise prefer one of the user's presets")
        var businessPurpose: String?
        @Guide(description: "Plain 4-8 word evidence phrase; do not repeat classification or business purpose")
        var rationale: String
        @Guide(description: "Confidence from 1 (a guess) to 5 (near certain); 2 when unsure")
        var confidence: Int
    }

    func testCloudModelGeneratesSuggestionThroughProductionEvidencePipeline() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        let cloudModel = PrivateCloudComputeLanguageModel()
        print("[pcc-smoke] availability: \(cloudModel.availability)")
        print("[pcc-smoke] quota: \(cloudModel.quotaUsage)")
        guard cloudModel.isAvailable else {
            throw XCTSkip("PCC unavailable: \(cloudModel.availability)")
        }

        // Real evidence pipeline, synthetic data (no EventKit dependency):
        // a morning drive to a portrait job, with the job on the calendar.
        let tripStart = try XCTUnwrap(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 9, minute: 13)
        ))
        let tripEnd = tripStart.addingTimeInterval(28 * 60)
        let buckets = CalendarEventEvidenceBuilder.bucketedEvents(
            candidates: [CalendarEventCandidate(
                title: "Example Studio portrait session",
                startDate: tripStart.addingTimeInterval(-13 * 60),
                endDate: tripStart.addingTimeInterval(47 * 60),
                calendarName: "Work"
            )],
            tripStart: tripStart,
            tripEnd: tripEnd,
            tripEndCoordinate: nil,
            tripEndComponents: TripEndpointAddressComponents(
                streetNumber: "444", streetName: "Somerville Ave", city: "Somerville"
            )
        )
        XCTAssertEqual(buckets.linked.map(\.id), ["L1"], "the overlapping job must link")

        let instructions = TripSuggestionPromptBuilder.instructions(
            localeIdentifier: "en_US",
            calendarEvidenceIncluded: true
        )
        var prompt = "Trip: Thu Aug 27, 2026 9:13 AM – Thu Aug 27, 2026 9:41 AM, 1.5 mi\n"
        prompt += "From: 320 Broadway, Cambridge, MA\nTo: 444 Somerville Ave, Somerville, MA\n"
        prompt += "Business purpose presets: Photo shoot; Site visit; Supplies\n"
        prompt += TripSuggestionPromptBuilder.bucketedCalendarSection(
            linkedLines: buckets.linked.map(\.line),
            contextLines: buckets.context.map(\.line)
        )

        let session = LanguageModelSession(model: cloudModel) { instructions }
        let started = Date()
        let output = try await session.respond(to: prompt, generating: SuggestionOutput.self).content
        let seconds = Date().timeIntervalSince(started)
        print("[pcc-smoke] \(String(format: "%.1f", seconds))s class=\(output.classification) conf=\(output.confidence) cite=\(output.citedEventID) nature=\(output.citedEventNature) purpose=\(output.businessPurpose ?? "-") rationale=\"\(output.rationale)\"")
        print("[pcc-smoke] quota after: \(cloudModel.quotaUsage)")

        // A cloud-sized model given a linked, place-matched job should call
        // this one cleanly; anything else is worth knowing before adoption.
        XCTAssertEqual(output.classification, "business")
        XCTAssertEqual(output.citedEventID, "L1")
        XCTAssertGreaterThanOrEqual(output.confidence, 3)
    }

    @MainActor
    func testProviderCloudPreferenceFallsBackSoftly() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("needs iOS 27") }
        // Transport-level check of the shipping provider path: whatever PCC's
        // state (available, quota-blocked, unentitled), the provider must
        // return a normal result or nil — never crash, never hang.
        var recorded: [String] = []
        let provider = FoundationModelsSuggestionProvider(
            record: { recorded.append($0) },
            preferPrivateCloudCompute: true
        )
        guard provider.isAvailable else { throw XCTSkip("system model unavailable") }
        let trip = TripSummary(
            id: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            captureSource: "manual",
            startDate: Date().addingTimeInterval(-3_600),
            endDate: Date().addingTimeInterval(-1_800),
            startCoordinate: nil,
            endCoordinate: nil,
            startAddress: "320 Broadway, Cambridge, MA",
            endAddress: "444 Somerville Ave, Somerville, MA",
            distanceMeters: 2_400,
            routePolyline: nil,
            classification: nil,
            reviewStatus: .needsReview,
            businessPurpose: nil,
            notes: nil,
            tollsAmount: 0,
            parkingAmount: 0,
            needsAttention: false,
            attentionReasons: [],
            manualDistanceOverrideMeters: nil
        )
        let request = TripSuggestionRequest(
            trip: trip,
            businessPurposePresets: ["Photo shoot", "Site visit", "Supplies"],
            calendarEvidenceEnabled: false,
            localeIdentifier: "en_US"
        )
        let suggestion = await provider.suggestion(for: request)
        print("[pcc-smoke] provider result: \(String(describing: suggestion)); recorded: \(recorded)")
        // No assertion on the suggestion itself: with calendar evidence off
        // and no notes, the business gate legitimately yields nil. The test
        // passes by completing without a crash or hang.
    }
}
#endif
