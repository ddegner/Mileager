import AppCore
import AVFoundation
import XCTest

@MainActor
final class BluetoothDriveSignalServiceThreadingTests: XCTestCase {
    func testDisabledRefreshDoesNotPublishSyntheticDisconnect() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = BluetoothDriveSignalService(
            store: BluetoothDriveHintStore(context: persistence.container.viewContext)
        )
        var connectionChanges: [Bool] = []
        service.onVehicleConnectionChanged = { active, _, _ in
            connectionChanges.append(active)
        }

        service.refreshConnectedHints(forceNotify: true)

        XCTAssertTrue(connectionChanges.isEmpty)
    }

    func testDisablingHintsDoesNotPublishSyntheticDisconnect() throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = BluetoothDriveSignalService(
            store: BluetoothDriveHintStore(context: persistence.container.viewContext),
            enabled: true
        )
        var connectionChanges: [Bool] = []
        service.onVehicleConnectionChanged = { active, _, _ in
            connectionChanges.append(active)
        }

        service.setEnabled(false)

        XCTAssertTrue(connectionChanges.isEmpty)
    }

    func testSecondaryThreadRouteNotificationRefreshesOnMainActor() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let service = BluetoothDriveSignalService(
            store: BluetoothDriveHintStore(context: persistence.container.viewContext),
            enabled: true
        )
        let refreshed = expectation(description: "Route refreshed on MainActor")
        var didFulfill = false
        service.onConnectedHintsChanged = { _ in
            XCTAssertTrue(Thread.isMainThread)
            guard !didFulfill else { return }
            didFulfill = true
            refreshed.fulfill()
        }

        DispatchQueue.global().async {
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance()
            )
        }

        await fulfillment(of: [refreshed], timeout: 2)
        service.setEnabled(false)
    }
}
