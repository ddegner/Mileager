import Foundation
import XCTest
@testable import AppCore

final class PendingSignalSpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingSignalSpoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveAndDrainRoundTripsAndDeletes() throws {
        let spool = PendingSignalSpool(directory: directory)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        try spool.save(trigger: .vehicleBluetooth, at: createdAt)

        let drained = try XCTUnwrap(spool.drain(now: createdAt.addingTimeInterval(60)))
        XCTAssertEqual(drained.trigger, .vehicleBluetooth)
        XCTAssertEqual(
            drained.createdAt.timeIntervalSince1970,
            createdAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertNil(spool.drain(now: createdAt.addingTimeInterval(61)), "drain must consume the record")
    }

    func testLatestWriteWins() throws {
        let spool = PendingSignalSpool(directory: directory)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        try spool.save(trigger: .vehicleBluetooth, at: createdAt)
        try spool.save(trigger: .charger, at: createdAt.addingTimeInterval(30))

        let drained = try XCTUnwrap(spool.drain(now: createdAt.addingTimeInterval(60)))
        XCTAssertEqual(drained.trigger, .charger)
    }

    func testStaleRecordIsDiscardedOnDrain() throws {
        let spool = PendingSignalSpool(directory: directory)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        try spool.save(trigger: .vehicleBluetooth, at: createdAt)

        XCTAssertNil(spool.drain(now: createdAt.addingTimeInterval(31 * 60)))
        XCTAssertNil(spool.drain(now: createdAt.addingTimeInterval(60)), "stale drain must still delete the file")
    }

    func testDrainWithNoFileReturnsNil() {
        XCTAssertNil(PendingSignalSpool(directory: directory).drain())
    }
}
