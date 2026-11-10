import XCTest
@testable import AppCore

#if os(iOS)
@MainActor
final class BluetoothDriveSignalServiceAuthorizationTests: XCTestCase {
    func testRequestWaitsForAuthorizationCallbackBeforeMarkingAllowed() throws {
        let fakeRequester = FakeBluetoothAuthorizationRequester(status: .notDetermined)
        let service = try makeService(authorizationRequester: fakeRequester)

        service.requestBluetoothAuthorization()

        XCTAssertEqual(fakeRequester.requestCount, 1)
        XCTAssertEqual(service.authorizationStatus, .notDetermined)

        fakeRequester.emit(.allowed)

        XCTAssertEqual(service.authorizationStatus, .allowed)
    }

    func testDeniedAuthorizationDoesNotStartRequest() throws {
        let fakeRequester = FakeBluetoothAuthorizationRequester(status: .denied)
        let service = try makeService(authorizationRequester: fakeRequester)

        service.requestBluetoothAuthorization()

        XCTAssertEqual(fakeRequester.requestCount, 0)
        XCTAssertEqual(service.authorizationStatus, .denied)
    }

    func testRestrictedAuthorizationDoesNotStartRequest() throws {
        let fakeRequester = FakeBluetoothAuthorizationRequester(status: .restricted)
        let service = try makeService(authorizationRequester: fakeRequester)

        service.requestBluetoothAuthorization()

        XCTAssertEqual(fakeRequester.requestCount, 0)
        XCTAssertEqual(service.authorizationStatus, .restricted)
    }

    private func makeService(
        authorizationRequester: FakeBluetoothAuthorizationRequester
    ) throws -> BluetoothDriveSignalService {
        let persistence = try PersistenceController(inMemory: true)
        return BluetoothDriveSignalService(
            store: BluetoothDriveHintStore(context: persistence.container.viewContext),
            authorizationRequester: authorizationRequester
        )
    }
}

@MainActor
private final class FakeBluetoothAuthorizationRequester: VehicleBluetoothAuthorizationRequesting {
    var onAuthorizationChanged: ((VehicleBluetoothAuthorizationStatus) -> Void)?
    private var status: VehicleBluetoothAuthorizationStatus
    private(set) var requestCount = 0

    init(status: VehicleBluetoothAuthorizationStatus) {
        self.status = status
    }

    func currentAuthorizationStatus() -> VehicleBluetoothAuthorizationStatus {
        status
    }

    func requestAuthorization() {
        requestCount += 1
    }

    func emit(_ status: VehicleBluetoothAuthorizationStatus) {
        self.status = status
        onAuthorizationChanged?(status)
    }
}
#endif
