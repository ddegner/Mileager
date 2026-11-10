import AppCore
import Foundation

@MainActor
final class IntentDataStack {
    let persistence: PersistenceController
    let pendingDriveStartSignalStore: PendingDriveStartSignalStore
    let captureEventStore: DriveCaptureEventStore
    let vehicleStore: VehicleStore

    init(mode: PersistenceMode = .localOnly, storeDirectory: URL? = nil) throws {
        let persistence = try PersistenceController(mode: mode, storeDirectory: storeDirectory)
        self.persistence = persistence
        let context = persistence.container.viewContext
        pendingDriveStartSignalStore = PendingDriveStartSignalStore(context: context)
        captureEventStore = DriveCaptureEventStore(context: context)
        vehicleStore = VehicleStore(context: context)
    }
}

@MainActor
enum IntentDataProvider {
    static var stackFactory: () throws -> IntentDataStack = {
        try IntentDataStack(mode: .localOnly)
    }

    static func makeStack() throws -> IntentDataStack {
        try stackFactory()
    }

    static func resetFactoryForTesting() {
        stackFactory = {
            try IntentDataStack(mode: .localOnly)
        }
    }
}
