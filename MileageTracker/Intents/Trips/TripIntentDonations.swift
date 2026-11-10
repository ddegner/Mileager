import AppCore
import AppIntents
import Foundation
import OSLog

/// Serializes donations and deletion so an in-flight donation cannot survive
/// a later opt-out, trip deletion, or expiration of a current-drive identity.
@MainActor
final class TripIntentDonations {
    enum Event {
        case completed(TripAppEntity, TripClassificationAppEnum)
        case current(CurrentDriveAppEntity, TripClassificationAppEnum)
        case removeTrip(UUID)
        case removeCurrentDrive(UUID)
        case removeAll
    }

    private var enabled = false
    private var generation = 0
    private var pending: Task<Void, Never>?
    private let send: @MainActor (Event) async throws -> Void
    private static let logger = Logger(subsystem: "com.daviddegner.MileageTracker", category: "IntentDonations")

    init(send: (@MainActor (Event) async throws -> Void)? = nil) {
        self.send = send ?? { event in
            guard !MileageAppModel.isRunningHostedUnitTests else { return }
            try await Self.sendToSystem(event)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { removeAll() }
    }

    func classifiedTrip(_ trip: TripAppEntity) {
        guard enabled, let category = trip.summary.classification else { return }
        enqueue(.completed(trip, TripClassificationAppEnum(category)))
    }

    func classifiedCurrentDrive(_ drive: CurrentDriveSummary) {
        guard enabled, let category = drive.classification else { return }
        enqueue(.current(CurrentDriveAppEntity(drive), TripClassificationAppEnum(category)))
    }

    func removeTrip(_ id: UUID) { enqueue(.removeTrip(id)) }
    func removeCurrentDrive(_ id: UUID) { enqueue(.removeCurrentDrive(id)) }
    func removeAll() {
        generation += 1
        enqueue(.removeAll)
    }

    func waitForPendingOperations() async { await pending?.value }

    private func enqueue(_ event: Event) {
        let previous = pending
        let send = send
        let scheduledGeneration = generation
        let isDonation: Bool
        switch event {
        case .current, .completed: isDonation = true
        default: isDonation = false
        }
        pending = Task { @MainActor [weak self] in
            await previous?.value
            // An opt-out/reset invalidates work that has not reached the
            // system yet. Already-started donations are followed by deletion.
            if isDonation {
                guard let self, self.enabled, self.generation == scheduledGeneration else { return }
            }
            do { try await send(event) }
            catch { Self.logger.error("Siri action context update failed: \(String(describing: type(of: error)), privacy: .public)") }
        }
    }

    private static func sendToSystem(_ event: Event) async throws {
        let manager = IntentDonationManager.shared
        switch event {
        case let .completed(trip, category):
            let intent = SetTripClassificationIntent()
            intent.trip = trip
            intent.classification = category
            try await manager.donate(intent: intent)
        case let .current(drive, category):
            let intent = ClassifyCurrentDriveIntent(classification: category)
            intent.drive = drive
            try await manager.donate(intent: intent)
        case let .removeTrip(id):
            try await manager.deleteDonations(matching: .entityIdentifier(.init(for: TripAppEntity.self, identifier: id)))
        case let .removeCurrentDrive(id):
            try await manager.deleteDonations(matching: .entityIdentifier(.init(for: CurrentDriveAppEntity.self, identifier: id)))
        case .removeAll:
            for type in [SetTripClassificationIntent.self, ClassifyCurrentDriveIntent.self] as [any AppIntent.Type] {
                try await manager.deleteDonations(matching: .intentType(type))
            }
        }
    }
}
