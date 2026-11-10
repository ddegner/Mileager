import AppCoreModels
import Foundation

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var category: String
    public var message: String
    public var sample: LocationSample?

    public init(date: Date = Date(), category: String, message: String, sample: LocationSample? = nil) {
        self.date = date
        self.category = category
        self.message = message
        self.sample = sample
    }
}

public struct DiagnosticsExport: Codable, Equatable, Sendable {
    public var exportedAt: Date
    public var health: TrackingHealth
    public var activeDriveState: DriveCaptureState?
    public var events: [DiagnosticEvent]
    public var diagnosticSamples: [DiagnosticLocationSample]
    public var captureEvents: [DriveCaptureJournalEntry]
    public var pendingDriveStartSignals: [PendingDriveStartSignal]
    public var sampleBursts: [DiagnosticSampleBurstSummary]
    public var possibleDriveCandidates: [PossibleDriveCandidate]
}

public final class DiagnosticsService {
    private let limit: Int
    private var events: [DiagnosticEvent] = []
    private let encoder = JSONEncoder()

    public init(limit: Int = 500) {
        self.limit = limit
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
    }

    public func export(
        health: TrackingHealth,
        activeDriveState: DriveCaptureState? = nil,
        diagnosticSamples: [DiagnosticLocationSample] = [],
        captureEvents: [DriveCaptureJournalEntry] = [],
        pendingDriveStartSignals: [PendingDriveStartSignal] = [],
        sampleBursts: [DiagnosticSampleBurstSummary] = [],
        possibleDriveCandidates: [PossibleDriveCandidate] = []
    ) throws -> Data {
        try encoder.encode(DiagnosticsExport(
            exportedAt: Date(),
            health: health,
            activeDriveState: activeDriveState,
            events: events,
            diagnosticSamples: diagnosticSamples,
            captureEvents: captureEvents,
            pendingDriveStartSignals: pendingDriveStartSignals,
            sampleBursts: sampleBursts,
            possibleDriveCandidates: possibleDriveCandidates
        ))
    }
}
