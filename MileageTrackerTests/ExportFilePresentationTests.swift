import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MileageTracker

/// The Mac save-panel layer over the temp-file writers: URL → content type,
/// suggested filename, and the file-backed Transferable handed to SwiftUI.
final class ExportFilePresentationTests: XCTestCase {
    func testEveryExportFormatProvidesATransferFilename() {
        // SwiftUI asks Transferable for this name before it displays the Mac
        // save panel. The panel's defaultFilename does not supply it.
        for filename in [
            "Mileage-2026-05.pdf",
            "Mileage-2026-05.csv",
            "diagnostics.zip",
            "export.bin",
            "Mileage – Montréal.PDF"
        ] {
            let item = ActivityShareItem(
                url: URL(fileURLWithPath: "/tmp/exports").appendingPathComponent(filename)
            )

            XCTAssertEqual(item.suggestedFilename, filename)
        }
    }

    func testContentTypeMapping() {
        XCTAssertEqual(
            ExportFilePresentation.contentType(for: URL(fileURLWithPath: "/tmp/Mileage-2026-05.csv")),
            .commaSeparatedText
        )
        XCTAssertEqual(
            ExportFilePresentation.contentType(for: URL(fileURLWithPath: "/tmp/Mileage-2026-05.PDF")),
            .pdf
        )
        XCTAssertEqual(
            ExportFilePresentation.contentType(for: URL(fileURLWithPath: "/tmp/diagnostics.zip")),
            .zip
        )
        XCTAssertEqual(
            ExportFilePresentation.contentType(for: URL(fileURLWithPath: "/tmp/mystery.bin")),
            .data
        )
    }

    func testDefaultFilenameDropsExtensionOnly() {
        XCTAssertEqual(
            ExportFilePresentation.defaultFilename(for: URL(fileURLWithPath: "/tmp/x/Mileage-2026-05.csv")),
            "Mileage-2026-05"
        )
        XCTAssertEqual(
            ExportFilePresentation.defaultFilename(for: URL(fileURLWithPath: "/tmp/Mileage-Trip-2026-05-01-0930-abcd1234.pdf")),
            "Mileage-Trip-2026-05-01-0930-abcd1234"
        )
    }

    func testShareItemUsesOriginalFileRepresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportFilePresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Mileage-2026-05.csv")
        try Data("Date,Miles\n2026-05-01,10".utf8).write(to: url)

        let item = ActivityShareItem(url: url)
        let transferred = try item.transferredFile()

        XCTAssertEqual(item.contentType, .commaSeparatedText)
        XCTAssertEqual(transferred.file, url)
        XCTAssertTrue(transferred.allowAccessingOriginalFile)
    }

    func testShareItemRejectsMissingSourceBeforePresentation() {
        let item = ActivityShareItem(
            url: URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID()).csv")
        )
        XCTAssertThrowsError(try item.validateSource()) { error in
            XCTAssertEqual(error as? ActivityShareItemError, .sourceUnavailable)
        }
    }

    func testLargeSparseSourceProducesFileRepresentationWithoutReadingContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-export-\(UUID().uuidString).zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 512 * 1_048_576)
        try handle.close()

        let item = ActivityShareItem(url: url)
        let transferred = try item.transferredFile()

        XCTAssertEqual(item.contentType, .zip)
        XCTAssertEqual(transferred.file, url)
        XCTAssertEqual(
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            512 * 1_048_576
        )
    }

    func testPresentationFailureRetainsEverySourceUntilTerminalCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csvURL = directory.appendingPathComponent("Mileage.csv")
        let pdfURL = directory.appendingPathComponent("Mileage.pdf")
        try Data("csv".utf8).write(to: csvURL)
        try Data("pdf".utf8).write(to: pdfURL)
        let item = ActivityShareItem(url: csvURL, cleanupURLs: [csvURL, pdfURL])
        var lifecycle = ExportPresentationLifecycle()

        lifecycle.begin(itemID: item.id)
        XCTAssertTrue(lifecycle.isPresented)

        // SwiftUI dismissing the panel is not a terminal outcome.
        lifecycle.presentationChanged(false)
        XCTAssertFalse(lifecycle.isPresented)
        XCTAssertEqual(lifecycle.itemID, item.id)

        lifecycle.retainAfterFailure(itemID: item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertTrue(lifecycle.retry(itemID: item.id))
        XCTAssertTrue(lifecycle.isPresented)

        XCTAssertTrue(lifecycle.finish(itemID: item.id))
        item.removeOwnedSources()
        XCTAssertNil(lifecycle.itemID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertFalse(lifecycle.finish(itemID: item.id))
        item.removeOwnedSources() // A repeated terminal signal remains harmless.
        XCTAssertFalse(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))
    }

    func testCapturedStaleCompletionCannotFinishReplacementItem() {
        let firstID = UUID()
        let replacementID = UUID()
        var lifecycle = ExportPresentationLifecycle()
        lifecycle.begin(itemID: firstID)
        lifecycle.begin(itemID: replacementID)

        // The old panel callback carries firstID rather than consulting the
        // lifecycle's live replacement identity.
        XCTAssertFalse(lifecycle.finish(itemID: firstID))
        XCTAssertEqual(lifecycle.itemID, replacementID)
        XCTAssertTrue(lifecycle.isPresented)
    }
}
