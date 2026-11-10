import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share surface every export lands in. Report generation is async and
/// `@MainActor`, so the URL only exists after the file is written; that is why
/// this is a presented sheet rather than a `ShareLink`.
struct ActivityShareItem: Identifiable, Sendable, Transferable {
    let id = UUID()
    var url: URL
    var notice: String?
    /// Files (or a containing temporary directory) owned by this presentation.
    /// The default is the represented file; report exports override this with
    /// both generated siblings, and diagnostics owns its whole report folder.
    private(set) var cleanupURLs: [URL]

    init(url: URL, cleanupURLs: [URL]? = nil, notice: String? = nil) {
        self.url = url
        self.notice = notice
        self.cleanupURLs = cleanupURLs ?? [url]
    }

    var contentType: UTType {
        ExportFilePresentation.contentType(for: url)
    }

    /// `FileRepresentation` hands the already-generated file to the system
    /// without materializing it as `Data`. The URL remains owned by the
    /// presentation flow until success or explicit dismissal, so the transfer
    /// can safely use the original app-owned temporary file.
    /// Each representation also needs a filename: SwiftUI's Mac exporter
    /// creates its temporary file wrapper before applying the save panel's
    /// `defaultFilename`, and an empty preferred filename raises an exception.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            try item.transferredFile()
        }
        .exportingCondition { $0.contentType == .pdf }
        .suggestedFileName { $0.url.lastPathComponent }

        FileRepresentation(exportedContentType: .commaSeparatedText) { item in
            try item.transferredFile()
        }
        .exportingCondition { $0.contentType == .commaSeparatedText }
        .suggestedFileName { $0.url.lastPathComponent }

        FileRepresentation(exportedContentType: .zip) { item in
            try item.transferredFile()
        }
        .exportingCondition { $0.contentType == .zip }
        .suggestedFileName { $0.url.lastPathComponent }

        FileRepresentation(exportedContentType: .data) { item in
            try item.transferredFile()
        }
        .exportingCondition { $0.contentType == .data }
        .suggestedFileName { $0.url.lastPathComponent }
    }

    func validateSource() throws {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw ActivityShareItemError.sourceUnavailable
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ActivityShareItemError.sourceUnavailable
        }
    }

    func transferredFile() throws -> SentTransferredFile {
        // Revalidate inside the representation as well as before presentation:
        // the source may disappear while the save panel is open.
        try validateSource()
        return SentTransferredFile(url, allowAccessingOriginalFile: true)
    }

    /// Best-effort and intentionally idempotent: terminal callbacks can race,
    /// and removing an already-removed temporary source is still success.
    func removeOwnedSources() {
        var removedPaths: Set<String> = []
        for cleanupURL in cleanupURLs where cleanupURL.isFileURL {
            let standardizedURL = cleanupURL.standardizedFileURL
            guard removedPaths.insert(standardizedURL.path).inserted else { continue }
            try? FileManager.default.removeItem(at: standardizedURL)
        }
    }
}

enum ActivityShareItemError: LocalizedError, Equatable {
    case sourceUnavailable

    var errorDescription: String? {
        String(localized: "Couldn't read the export file. Try exporting again.")
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    var onComplete: (@MainActor () -> Void)? = nil

    final class Coordinator {
        private var didComplete = false

        func complete(_ action: (@MainActor () -> Void)?) {
            guard !didComplete else { return }
            didComplete = true
            guard let action else { return }
            Task { @MainActor in
                action()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.complete(onComplete)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
