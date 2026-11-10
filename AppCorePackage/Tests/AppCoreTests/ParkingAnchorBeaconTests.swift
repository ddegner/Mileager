import XCTest
@testable import AppCore

final class ParkingAnchorBeaconTests: XCTestCase {
    private func makeBeacon() throws -> (ParkingAnchorBeacon, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beacon-tests-\(UUID().uuidString)", isDirectory: true)
        return (ParkingAnchorBeacon(directory: directory), directory)
    }

    private func sample() -> LocationSample {
        LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            latitude: 41.0804198,
            longitude: -73.4617609,
            horizontalAccuracy: 4.2
        )
    }

    func testSaveLoadRoundTripPreservesAnchorAndRadius() throws {
        let (beacon, directory) = try makeBeacon()
        defer { try? FileManager.default.removeItem(at: directory) }

        beacon.save(anchor: sample(), radius: 250)
        let stored = try XCTUnwrap(beacon.load())

        XCTAssertEqual(stored.latitude, 41.0804198, accuracy: 0.0000001)
        XCTAssertEqual(stored.longitude, -73.4617609, accuracy: 0.0000001)
        XCTAssertEqual(stored.radius, 250, accuracy: 0.001)
        XCTAssertEqual(stored.horizontalAccuracy, 4.2, accuracy: 0.001)
        XCTAssertEqual(stored.timestamp, sample().timestamp)
        // The rebuilt anchor must match the original closely enough for the
        // idle-wake monitor's `matchesIdleWakeAnchor` (1e-6 / 1s tolerance).
        XCTAssertEqual(stored.anchorSample.latitude, sample().latitude, accuracy: 0.0000001)
    }

    func testClearRemovesThePersistedRecord() throws {
        let (beacon, directory) = try makeBeacon()
        defer { try? FileManager.default.removeItem(at: directory) }

        beacon.save(anchor: sample(), radius: 250)
        XCTAssertNotNil(beacon.load())

        beacon.clear()
        XCTAssertNil(beacon.load())
    }

    func testSaveOverwritesPreviousRecord() throws {
        let (beacon, directory) = try makeBeacon()
        defer { try? FileManager.default.removeItem(at: directory) }

        beacon.save(anchor: sample(), radius: 250)
        let updated = LocationSample(
            timestamp: Date(timeIntervalSince1970: 1_800_009_999),
            latitude: 42.3682954,
            longitude: -71.1046248,
            horizontalAccuracy: 8.0
        )
        beacon.save(anchor: updated, radius: 300)

        let stored = try XCTUnwrap(beacon.load())
        XCTAssertEqual(stored.latitude, 42.3682954, accuracy: 0.0000001)
        XCTAssertEqual(stored.radius, 300, accuracy: 0.001)
    }

    func testLoadReturnsNilWhenNothingSaved() throws {
        let (beacon, directory) = try makeBeacon()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(beacon.load())
    }

    #if os(iOS)
    func testSavedFileUsesNoFileProtection() throws {
        let (beacon, directory) = try makeBeacon()
        defer { try? FileManager.default.removeItem(at: directory) }

        beacon.save(anchor: sample(), radius: 250)
        let fileURL = directory.appendingPathComponent("parking-anchor-beacon.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, FileProtectionType.none)
    }
    #endif
}
