import Foundation
import PDFKit
import XCTest

@MainActor
@discardableResult
func assertReportFooters(
    in document: PDFDocument,
    file: StaticString = #filePath,
    line: UInt = #line
) -> [CGRect] {
    var result: [CGRect] = []

    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex) else {
            XCTFail("Missing PDF page \(pageIndex + 1)", file: file, line: line)
            continue
        }
        let expected = "Page \(pageIndex + 1) of \(document.pageCount)"
        guard let selection = selection(for: expected, on: page, in: document) else {
            XCTFail("Missing footer '\(expected)'", file: file, line: line)
            continue
        }

        let bounds = selection.bounds(for: page)
        let mediaBox = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.minX, mediaBox.minX + 42, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(bounds.minY, mediaBox.minY + 26, file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.maxY, mediaBox.minY + 36, file: file, line: line)

        for pageLine in page.selection(for: mediaBox)?.selectionsByLine() ?? [] {
            let lineText = pageLine.string?
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ") ?? ""
            guard !lineText.isEmpty, lineText != expected else { continue }

            // Text living entirely inside the footer band is footer content,
            // not body overflow — the trip receipt's "Notes continue…" and
            // "Trip ID …" legitimately share the page-label baseline.
            let lineBounds = pageLine.bounds(for: page)
            if lineBounds.minY >= mediaBox.minY + 26 - 0.5,
               lineBounds.maxY <= mediaBox.minY + 36 + 0.5 {
                continue
            }

            XCTAssertGreaterThanOrEqual(
                lineBounds.minY,
                bounds.maxY + 8,
                "PDF body line entered the footer safety gap: \(lineText)",
                file: file,
                line: line
            )
        }
        result.append(bounds)
    }

    return result
}

@MainActor
func reportSelectionBounds(
    for text: String,
    on page: PDFPage,
    in document: PDFDocument
) -> CGRect? {
    selection(for: text, on: page, in: document)?.bounds(for: page)
}

@MainActor
private func selection(
    for text: String,
    on page: PDFPage,
    in document: PDFDocument
) -> PDFSelection? {
    document.findString(text, withOptions: []).first { selection in
        selection.pages.contains { $0 === page }
    }
}
