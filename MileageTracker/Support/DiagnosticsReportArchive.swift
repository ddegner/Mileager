import AppCore
import Foundation

struct DiagnosticsReportItem: Identifiable, Sendable {
    let id = UUID()
    var url: URL
    var fileName: String
    var subject: String = "Mileager diagnostics report"
    var messageBody: String = "Diagnostics are attached as a zip file."
    var cleanupDirectory: URL?

    func removeTemporaryFiles() {
        let directory = cleanupDirectory ?? url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }
}

enum DiagnosticsReportArchive {
    /// Fixed upper bound for every source/output validation read. ZIP metadata
    /// remains small; store contents never become one proportional `Data`.
    static let streamingChunkSize = 1_048_576

    static func makeSupportReport(from bundle: DiagnosticsSupportStoreBundle, now: Date = Date()) throws -> DiagnosticsReportItem {
        defer { try? FileManager.default.removeItem(at: bundle.directoryURL) }

        let timestamp = timestampFormatter.string(from: now)
        let fileName = "MileagerSupport-\(timestamp).zip"
        var entries = bundle.storeFileURLs.map { url in
            StoredZipArchive.Entry(
                fileName: url.lastPathComponent,
                source: .file(url),
                modifiedAt: now
            )
        }
        entries.append(StoredZipArchive.Entry(
            fileName: "manifest.json",
            source: .data(bundle.manifestData),
            modifiedAt: now
        ))
        entries.append(StoredZipArchive.Entry(
            fileName: "support_questions.txt",
            source: .data(Data(bundle.supportQuestionsText.utf8)),
            modifiedAt: now
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MileagerSupport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            let layout = try StoredZipArchive.writeArchive(
                entries: entries,
                to: url,
                chunkSize: streamingChunkSize
            )
            try StoredZipArchive.validateArchive(
                at: url,
                layout: layout,
                chunkSize: streamingChunkSize
            )
            return DiagnosticsReportItem(
                url: url,
                fileName: fileName,
                subject: "Mileager support report - last \(bundle.selectedDays) \(bundle.selectedDays == 1 ? "day" : "days")",
                messageBody: bundle.supportQuestionsText,
                cleanupDirectory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private enum StoredZipArchive {
    enum Source {
        case file(URL)
        case data(Data)

        func forEachChunk(
            ofSize chunkSize: Int,
            _ body: (Data) throws -> Void
        ) throws {
            precondition(chunkSize > 0)
            switch self {
            case .file(let url):
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                    try body(chunk)
                }
            case .data(let data):
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    try body(data.subdata(in: offset..<end))
                    offset = end
                }
            }
        }
    }

    struct Entry {
        var fileName: String
        var source: Source
        var modifiedAt: Date
    }

    struct ArchiveLayout {
        var entries: [CentralDirectoryEntry]
        var centralDirectoryOffset: UInt32
        var centralDirectorySize: UInt32
        var totalSize: UInt64
    }

    static func writeArchive(
        entries: [Entry],
        to url: URL,
        chunkSize: Int
    ) throws -> ArchiveLayout {
        guard !entries.isEmpty,
              entries.count <= Int(UInt16.max),
              chunkSize > 0 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.complete
        ]
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: attributes
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var writer = ArchiveWriter(handle: handle)
        var centralDirectoryEntries: [CentralDirectoryEntry] = []

        for entry in entries {
            let fileNameData = Data(entry.fileName.utf8)
            guard !fileNameData.isEmpty,
                  fileNameData.count <= Int(UInt16.max),
                  writer.offset <= UInt64(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }

            let summary = try summarize(entry.source, chunkSize: chunkSize)
            let (dosTime, dosDate) = dosDateTime(from: entry.modifiedAt)
            let localFileHeaderOffset = UInt32(writer.offset)

            try writer.write(localFileHeader(
                fileNameData: fileNameData,
                crc: summary.crc,
                size: summary.size,
                dosTime: dosTime,
                dosDate: dosDate
            ))

            var writtenCRC = CRC32()
            var writtenSize: UInt64 = 0
            try entry.source.forEachChunk(ofSize: chunkSize) { chunk in
                guard writtenSize + UInt64(chunk.count) <= UInt64(UInt32.max) else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try writer.write(chunk)
                writtenCRC.update(chunk)
                writtenSize += UInt64(chunk.count)
            }
            // Detect a source file changing between the sizing/CRC pass and the
            // write pass rather than emitting internally inconsistent headers.
            guard writtenSize == UInt64(summary.size),
                  writtenCRC.finalized == summary.crc else {
                throw CocoaError(.fileReadCorruptFile)
            }

            centralDirectoryEntries.append(CentralDirectoryEntry(
                fileNameData: fileNameData,
                crc: summary.crc,
                size: summary.size,
                dosTime: dosTime,
                dosDate: dosDate,
                localFileHeaderOffset: localFileHeaderOffset
            ))
        }

        guard writer.offset <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let centralDirectoryOffset = UInt32(writer.offset)

        for entry in centralDirectoryEntries {
            try writer.write(centralDirectoryHeader(entry))
        }

        let centralDirectoryByteCount = writer.offset - UInt64(centralDirectoryOffset)
        guard centralDirectoryByteCount <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let centralDirectorySize = UInt32(centralDirectoryByteCount)
        try writer.write(endOfCentralDirectory(
            entryCount: UInt16(centralDirectoryEntries.count),
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset
        ))
        try handle.synchronize()
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)

        return ArchiveLayout(
            entries: centralDirectoryEntries,
            centralDirectoryOffset: centralDirectoryOffset,
            centralDirectorySize: centralDirectorySize,
            totalSize: writer.offset
        )
    }

    static func validateArchive(
        at url: URL,
        layout: ArchiveLayout,
        chunkSize: Int
    ) throws {
        guard chunkSize > 0,
              FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              UInt64(fileSize) == layout.totalSize,
              layout.totalSize >= 22 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Validate every local header and payload with a bounded CRC pass.
        for expected in layout.entries {
            let header = try readExactly(
                from: handle,
                at: UInt64(expected.localFileHeaderOffset),
                count: 30
            )
            guard uint32(header, at: 0) == 0x0403_4B50,
                  uint16(header, at: 6) == 0,
                  uint16(header, at: 8) == 0,
                  uint32(header, at: 14) == expected.crc,
                  uint32(header, at: 18) == expected.size,
                  uint32(header, at: 22) == expected.size else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameLength = Int(uint16(header, at: 26))
            let extraLength = Int(uint16(header, at: 28))
            let name = try readExactly(
                from: handle,
                at: UInt64(expected.localFileHeaderOffset) + 30,
                count: nameLength
            )
            guard name == expected.fileNameData else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let dataOffset = UInt64(expected.localFileHeaderOffset)
                + 30 + UInt64(nameLength + extraLength)
            guard dataOffset + UInt64(expected.size) <= UInt64(layout.centralDirectoryOffset) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try handle.seek(toOffset: dataOffset)
            var remaining = UInt64(expected.size)
            var crc = CRC32()
            while remaining > 0 {
                let requested = min(chunkSize, Int(remaining))
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard UInt64(chunk.count) <= remaining else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                crc.update(chunk)
                remaining -= UInt64(chunk.count)
            }
            guard crc.finalized == expected.crc else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        // EOCD has no comment in archives emitted here, so it is the final 22
        // bytes and can be checked without scanning the whole file.
        let end = try readExactly(
            from: handle,
            at: layout.totalSize - 22,
            count: 22
        )
        let expectedCount = UInt16(layout.entries.count)
        guard uint32(end, at: 0) == 0x0605_4B50,
              uint16(end, at: 4) == 0,
              uint16(end, at: 6) == 0,
              uint16(end, at: 8) == expectedCount,
              uint16(end, at: 10) == expectedCount,
              uint32(end, at: 12) == layout.centralDirectorySize,
              uint32(end, at: 16) == layout.centralDirectoryOffset,
              uint16(end, at: 20) == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var centralOffset = UInt64(layout.centralDirectoryOffset)
        for expected in layout.entries {
            let header = try readExactly(from: handle, at: centralOffset, count: 46)
            guard uint32(header, at: 0) == 0x0201_4B50,
                  uint16(header, at: 8) == 0,
                  uint16(header, at: 10) == 0,
                  uint32(header, at: 16) == expected.crc,
                  uint32(header, at: 20) == expected.size,
                  uint32(header, at: 24) == expected.size,
                  uint32(header, at: 42) == expected.localFileHeaderOffset else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameLength = Int(uint16(header, at: 28))
            let extraLength = Int(uint16(header, at: 30))
            let commentLength = Int(uint16(header, at: 32))
            let name = try readExactly(from: handle, at: centralOffset + 46, count: nameLength)
            guard name == expected.fileNameData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            centralOffset += UInt64(46 + nameLength + extraLength + commentLength)
        }
        guard centralOffset == UInt64(layout.centralDirectoryOffset)
                + UInt64(layout.centralDirectorySize),
              centralOffset + 22 == layout.totalSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    fileprivate struct CentralDirectoryEntry {
        var fileNameData: Data
        var crc: UInt32
        var size: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
        var localFileHeaderOffset: UInt32
    }

    private struct SourceSummary {
        var crc: UInt32
        var size: UInt32
    }

    private struct ArchiveWriter {
        var handle: FileHandle
        var offset: UInt64 = 0

        mutating func write(_ data: Data) throws {
            guard offset + UInt64(data.count) <= UInt64(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
    }

    private static func summarize(_ source: Source, chunkSize: Int) throws -> SourceSummary {
        var crc = CRC32()
        var size: UInt64 = 0
        try source.forEachChunk(ofSize: chunkSize) { chunk in
            guard size + UInt64(chunk.count) <= UInt64(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            crc.update(chunk)
            size += UInt64(chunk.count)
        }
        return SourceSummary(crc: crc.finalized, size: UInt32(size))
    }

    private static func localFileHeader(
        fileNameData: Data,
        crc: UInt32,
        size: UInt32,
        dosTime: UInt16,
        dosDate: UInt16
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x0403_4B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(dosTime)
        data.appendLittleEndian(dosDate)
        data.appendLittleEndian(crc)
        data.appendLittleEndian(size)
        data.appendLittleEndian(size)
        data.appendLittleEndian(UInt16(fileNameData.count))
        data.appendLittleEndian(UInt16(0))
        data.append(fileNameData)
        return data
    }

    private static func centralDirectoryHeader(_ entry: CentralDirectoryEntry) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x0201_4B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entry.dosTime)
        data.appendLittleEndian(entry.dosDate)
        data.appendLittleEndian(entry.crc)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(entry.fileNameData.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(entry.localFileHeaderOffset)
        data.append(entry.fileNameData)
        return data
    }

    private static func endOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x0605_4B50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(centralDirectorySize)
        data.appendLittleEndian(centralDirectoryOffset)
        data.appendLittleEndian(UInt16(0))
        return data
    }

    private static func readExactly(
        from handle: FileHandle,
        at offset: UInt64,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: offset)
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count),
                  !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(chunk)
        }
        return result
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func dosDateTime(from date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current,
            from: date
        )
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private struct CRC32 {
    private var checksum: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xff)
            checksum = Self.table[index] ^ (checksum >> 8)
        }
    }

    var finalized: UInt32 { checksum ^ 0xffff_ffff }

    private static let table: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
