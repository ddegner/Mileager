import AppCore
import Foundation
import XCTest
@testable import MileageTracker

final class DiagnosticsReportArchiveTests: XCTestCase {
    func testSupportReportArchiveWritesStoresManifestAndQuestions() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsReportArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let tripStore = sourceDirectory.appendingPathComponent("MileageTracker.sqlite")
        let rawStore = sourceDirectory.appendingPathComponent("MileageTrackerRaw.sqlite")
        try Data("trip-store".utf8).write(to: tripStore)
        try Data("raw-store".utf8).write(to: rawStore)
        let now = try XCTUnwrap(Calendar.utc.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5
        )))
        let bundle = DiagnosticsSupportStoreBundle(
            directoryURL: sourceDirectory,
            storeFileURLs: [tripStore, rawStore],
            manifestData: Data(#"{"selectedDays":7}"#.utf8),
            supportQuestionsText: "Please answer these before sending.",
            selectedDays: 7,
            startDate: now.addingTimeInterval(-7 * 24 * 60 * 60),
            endDate: now,
            rowCounts: ["TripEntity": 1]
        )

        let report = try DiagnosticsReportArchive.makeSupportReport(from: bundle, now: now)

        XCTAssertEqual(report.fileName, "MileagerSupport-20260102-030405.zip")
        XCTAssertEqual(report.subject, "Mileager support report - last 7 days")
        XCTAssertEqual(report.messageBody, "Please answer these before sending.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))
        let entries = try MultiEntryZipReader.read(from: try Data(contentsOf: report.url))
        XCTAssertEqual(entries["MileageTracker.sqlite"]?.data, Data("trip-store".utf8))
        XCTAssertEqual(entries["MileageTrackerRaw.sqlite"]?.data, Data("raw-store".utf8))
        XCTAssertEqual(entries["manifest.json"]?.data, Data(#"{"selectedDays":7}"#.utf8))
        XCTAssertEqual(entries["support_questions.txt"]?.data, Data("Please answer these before sending.".utf8))
        for entry in entries.values {
            XCTAssertEqual(entry.crc32, TestCRC32.checksum(entry.data))
        }
        try assertFileProtectionComplete(at: report.url)

        report.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.url.path))
    }

    func testSupportReportStreamsStoreLargerThanFixedChunk() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsReportArchiveLarge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let store = sourceDirectory.appendingPathComponent("MileageTracker.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: store.path, contents: nil))
        let handle = try FileHandle(forWritingTo: store)
        let chunk = Data(repeating: 0xa5, count: DiagnosticsReportArchive.streamingChunkSize)
        try handle.write(contentsOf: chunk)
        try handle.write(contentsOf: chunk)
        try handle.write(contentsOf: chunk)
        try handle.write(contentsOf: Data(repeating: 0x5a, count: 127))
        try handle.close()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bundle = DiagnosticsSupportStoreBundle(
            directoryURL: sourceDirectory,
            storeFileURLs: [store],
            manifestData: Data("{}".utf8),
            supportQuestionsText: "Questions",
            selectedDays: 1,
            startDate: now.addingTimeInterval(-86_400),
            endDate: now,
            rowCounts: [:]
        )

        let report = try DiagnosticsReportArchive.makeSupportReport(from: bundle, now: now)
        defer { report.removeTemporaryFiles() }

        let archivedStore = try StreamingStoredZipReader.readEntry(
            named: "MileageTracker.sqlite",
            from: report.url,
            chunkSize: DiagnosticsReportArchive.streamingChunkSize
        )
        let expectedSize = DiagnosticsReportArchive.streamingChunkSize * 3 + 127
        var expectedCRC = TestCRC32()
        expectedCRC.update(chunk)
        expectedCRC.update(chunk)
        expectedCRC.update(chunk)
        expectedCRC.update(Data(repeating: 0x5a, count: 127))

        XCTAssertEqual(archivedStore.size, expectedSize)
        XCTAssertEqual(archivedStore.prefix, Data(repeating: 0xa5, count: 16))
        XCTAssertEqual(archivedStore.suffix, Data(repeating: 0x5a, count: 16))
        XCTAssertEqual(archivedStore.storedCRC32, expectedCRC.finalized)
        XCTAssertEqual(archivedStore.computedCRC32, expectedCRC.finalized)
        let archiveSize = try XCTUnwrap(
            report.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThan(archiveSize, expectedSize)
        XCTAssertLessThan(archiveSize, expectedSize + 2_048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))
        try assertFileProtectionComplete(at: report.url)
    }
}

private struct ZipEntry {
    var fileName: String
    var data: Data
    var crc32: UInt32
}

private enum MultiEntryZipReader {
    static func read(from archive: Data) throws -> [String: ZipEntry] {
        let bytes = [UInt8](archive)
        var offset = 0
        var entries: [String: ZipEntry] = [:]
        while offset + 4 <= bytes.count, readUInt32(bytes, at: offset) == 0x0403_4B50 {
            XCTAssertEqual(readUInt16(bytes, at: offset + 8), 0)

            let crc32 = readUInt32(bytes, at: offset + 14)
            let compressedSize = Int(readUInt32(bytes, at: offset + 18))
            let uncompressedSize = Int(readUInt32(bytes, at: offset + 22))
            let localNameLength = Int(readUInt16(bytes, at: offset + 26))
            let localExtraLength = Int(readUInt16(bytes, at: offset + 28))
            let localNameStart = offset + 30
            let dataStart = localNameStart + localNameLength + localExtraLength
            let dataEnd = dataStart + compressedSize

            XCTAssertEqual(compressedSize, uncompressedSize)
            XCTAssertGreaterThanOrEqual(bytes.count, dataEnd)

            let fileName = try XCTUnwrap(String(
                data: Data(bytes[localNameStart..<(localNameStart + localNameLength)]),
                encoding: .utf8
            ))
            let fileData = Data(bytes[dataStart..<dataEnd])
            entries[fileName] = ZipEntry(fileName: fileName, data: fileData, crc32: crc32)
            offset = dataEnd
        }

        XCTAssertEqual(readUInt32(bytes, at: offset), 0x0201_4B50)
        return entries
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }
}

private enum StreamingStoredZipReader {
    struct EntrySummary {
        var size: Int
        var storedCRC32: UInt32
        var computedCRC32: UInt32
        var prefix: Data
        var suffix: Data
    }

    static func readEntry(
        named expectedName: String,
        from archiveURL: URL,
        chunkSize: Int
    ) throws -> EntrySummary {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        while true {
            let signature = try readExactly(from: handle, count: 4)
            guard readUInt32(signature, at: 0) == 0x0403_4B50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var header = signature
            header.append(try readExactly(from: handle, count: 26))
            guard readUInt16(header, at: 6) == 0,
                  readUInt16(header, at: 8) == 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let storedCRC32 = readUInt32(header, at: 14)
            let compressedSize = Int(readUInt32(header, at: 18))
            let uncompressedSize = Int(readUInt32(header, at: 22))
            let nameLength = Int(readUInt16(header, at: 26))
            let extraLength = Int(readUInt16(header, at: 28))
            guard compressedSize == uncompressedSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameData = try readExactly(from: handle, count: nameLength)
            let name = try XCTUnwrap(String(data: nameData, encoding: .utf8))
            if extraLength > 0 {
                _ = try readExactly(from: handle, count: extraLength)
            }

            guard name == expectedName else {
                try handle.seek(toOffset: handle.offsetInFile + UInt64(compressedSize))
                continue
            }

            var remaining = compressedSize
            var crc = TestCRC32()
            var prefix = Data()
            var suffix = Data()
            while remaining > 0 {
                let data = try readExactly(from: handle, count: min(chunkSize, remaining))
                crc.update(data)
                if prefix.count < 16 {
                    prefix.append(data.prefix(16 - prefix.count))
                }
                if data.count >= 16 {
                    suffix = Data(data.suffix(16))
                } else {
                    suffix.append(data)
                    if suffix.count > 16 {
                        suffix = Data(suffix.suffix(16))
                    }
                }
                remaining -= data.count
            }
            return EntrySummary(
                size: uncompressedSize,
                storedCRC32: storedCRC32,
                computedCRC32: crc.finalized,
                prefix: prefix,
                suffix: suffix
            )
        }
    }

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count),
                  !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(chunk)
        }
        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

private struct TestCRC32 {
    private var checksum: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xff)
            checksum = Self.table[index] ^ (checksum >> 8)
        }
    }

    var finalized: UInt32 {
        checksum ^ 0xffff_ffff
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = Self()
        crc.update(data)
        return crc.finalized
    }

    private static let table: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
