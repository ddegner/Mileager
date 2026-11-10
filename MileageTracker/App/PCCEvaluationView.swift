#if DEBUG
import AppCore
import CryptoKit
import SwiftUI
import UIKit

/// Explicit diagnostic launch only. The app constructs no app model
/// and mounts this view instead of the normal scene, so evaluating frozen
/// history never opens or writes the user's trip store or preferences.
struct PCCEvaluationView: View {
    static var runName: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"),
              let argument = arguments.first(where: { $0.hasPrefix("--pcc-evaluation=") }) else { return nil }
        let name = String(argument.dropFirst("--pcc-evaluation=".count))
        guard !name.isEmpty, name.count <= 48,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return name
    }

    @State private var completed = 0
    @State private var total = 0
    @State private var status = "Preparing accuracy test…"
    @State private var started = false

    var body: some View {
        VStack(spacing: 16) {
            Text(verbatim: "PCC Accuracy Test").font(.title2)
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
            Text(verbatim: "\(completed) of \(total) trips").monospacedDigit()
            Text(status).foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            guard !started else { return }
            started = true
            await run()
        }
    }

    private struct Input: Decodable {
        var trips: [TripSummary]
        var events: [Event]
        var businessPurposePresets: [String]
    }

    private struct Event: Decodable {
        var title: String
        var startDate: Date
        var endDate: Date
        var isAllDay: Bool
        var locationText: String?
        var calendarName: String?
        var candidate: CalendarEventCandidate {
            CalendarEventCandidate(title: title, startDate: startDate, endDate: endDate,
                isAllDay: isAllDay, locationText: locationText, calendarName: calendarName)
        }
    }

    private struct Manifest: Codable, Equatable {
        let inputSHA256: String
        let promptVersion: Int
        let count: Int
        let build: String
        let os: String
    }

    @MainActor private func run() async {
        guard let name = Self.runName else { return }
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        do {
            let directory = URL.documentsDirectory.appending(path: "PCCEvaluation", directoryHint: .isDirectory)
            let data = try Data(contentsOf: directory.appending(path: "input.json"))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let input = try decoder.decode(Input.self, from: data)
            // Fail closed if a preparation mistake puts the answer in a case.
            guard input.trips.allSatisfy({ $0.classification == nil && $0.businessPurpose == nil && $0.notes == nil }),
                  Set(input.trips.map(\.id)).count == input.trips.count else {
                throw EvaluationError.invalidInput
            }
            let manifest = Manifest(inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                promptVersion: SuggestionFingerprint.promptVersion, count: input.trips.count,
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                os: ProcessInfo.processInfo.operatingSystemVersionString)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifestURL = directory.appending(path: "\(name)-manifest.json")
            let outputURL = directory.appending(path: "\(name).jsonl")
            var finished = Set<UUID>()
            if FileManager.default.fileExists(atPath: outputURL.path) {
                guard try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL)) == manifest else {
                    throw EvaluationError.changedInput
                }
                let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
                finished = Set(try lines.map { try decoder.decode(PCCEvaluationOutcome.self, from: Data($0.utf8)).id })
            } else {
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                try Data().write(to: outputURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            total = input.trips.count
            completed = finished.count
            status = "Using Private Cloud Compute"
            let provider = FoundationModelsSuggestionProvider(record: { _ in }, preferPrivateCloudCompute: true)
            let events = input.events.map(\.candidate)
            var consecutiveErrors = 0
            for trip in input.trips where !finished.contains(trip.id) {
                try Task.checkCancellation()
                let candidates = events.filter {
                    $0.startDate <= trip.endDate.addingTimeInterval(14_400)
                        && $0.endDate >= trip.startDate.addingTimeInterval(-14_400)
                }
                let request = TripSuggestionRequest(trip: trip, businessPurposePresets: input.businessPurposePresets,
                    calendarEvidenceEnabled: true, localeIdentifier: "en_US", contactEvidenceEnabled: false)
                let outcome = await provider.evaluatePrivateCloudCompute(request: request, candidates: candidates)
                try Task.checkCancellation()
                try handle.write(contentsOf: encoder.encode(outcome) + Data([10]))
                try handle.synchronize()
                completed += 1
                consecutiveErrors = outcome.error == nil ? 0 : consecutiveErrors + 1
                print("[pcc-evaluation] \(name) \(completed)/\(total) suggestion=\(outcome.actual ?? "abstain") error=\(outcome.error != nil) seconds=\(Int(outcome.duration))")
                if consecutiveErrors >= 3 {
                    status = "Paused after three model errors. Results saved."
                    print("[pcc-evaluation] paused-errors")
                    return
                }
            }
            status = "Complete. Results saved for scoring."
            print("[pcc-evaluation] complete \(name)")
        } catch {
            status = "Test stopped: \(error.localizedDescription)"
            print("[pcc-evaluation] stopped \(error)")
        }
    }

    private enum EvaluationError: Error {
        case invalidInput, changedInput
    }
}
#endif
