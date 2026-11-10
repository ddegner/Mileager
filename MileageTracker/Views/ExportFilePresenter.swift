import SwiftUI
import UniformTypeIdentifiers

/// Pure URL → save-panel presentation mapping, split out for tests.
enum ExportFilePresentation {
    static func contentType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "csv": .commaSeparatedText
        case "pdf": .pdf
        case "zip": .zip
        default: .data
        }
    }

    /// The exporter re-appends the extension from the content type, so the
    /// suggested name is the base filename (`Mileage-2026-07`, already
    /// correct via `ReportExportNaming`/the trip slug).
    static func defaultFilename(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Pure presentation state used by the modifier and focused tests. A panel
/// dismissal retains the item until an explicit success/cancel/discard outcome;
/// `finish` is the exactly-once gate shared by those terminal paths.
struct ExportPresentationLifecycle: Equatable {
    private enum Phase: Equatable {
        case idle
        case presenting(UUID)
        case retained(UUID)
    }

    private var phase: Phase = .idle

    var itemID: UUID? {
        switch phase {
        case .idle: nil
        case .presenting(let id), .retained(let id): id
        }
    }

    var isPresented: Bool {
        if case .presenting = phase { return true }
        return false
    }

    mutating func begin(itemID: UUID) {
        phase = .presenting(itemID)
    }

    mutating func presentationChanged(_ presented: Bool) {
        switch (phase, presented) {
        case (.presenting(let id), false):
            phase = .retained(id)
        case (.retained(let id), true):
            phase = .presenting(id)
        default:
            break
        }
    }

    mutating func retainAfterFailure(itemID: UUID) {
        guard self.itemID == itemID else { return }
        phase = .retained(itemID)
    }

    @discardableResult
    mutating func retry(itemID: UUID) -> Bool {
        guard self.itemID == itemID else { return false }
        phase = .presenting(itemID)
        return true
    }

    @discardableResult
    mutating func finish(itemID: UUID) -> Bool {
        guard self.itemID == itemID else { return false }
        phase = .idle
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}

/// One modifier for every export destination. The Mac save panel receives the
/// generated URL through `Transferable.FileRepresentation`; it never builds a
/// `Data`/`FileWrapper` copy of the source. Elsewhere the same URL continues to
/// use the activity sheet.
struct ExportShareModifier: ViewModifier {
    @Environment(MileageAppModel.self) private var model

    @Binding var item: ActivityShareItem?
    var onComplete: (@MainActor () -> Void)? = nil

    @State private var lifecycle = ExportPresentationLifecycle()
    /// The item currently owned by the save panel. Keep it separate from the
    /// caller's binding so a replacement can wait without changing the source
    /// or callback identity of an in-flight presentation.
    @State private var activePresentation: ActivityShareItem?
    @State private var exportFailure: ExportFailure?

    private struct ExportFailure: Identifiable {
        var itemID: UUID
        var message: String
        var id: UUID { itemID }
    }

    func body(content: Content) -> some View {
        if model.platform.exportsThroughSavePanel {
            // This local value is captured by the callbacks registered for this
            // presentation. A late callback for A therefore still carries A's
            // identity after the binding has moved on to B.
            let presentation = activePresentation
            content
                .overlay(alignment: .bottom) {
                    if let notice = presentation?.notice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                            .accessibilityIdentifier("exportIRSRateFreshness")
                    }
                }
                .fileExporter(
                    isPresented: Binding(
                        get: { lifecycle.isPresented },
                        set: { lifecycle.presentationChanged($0) }
                    ),
                    item: presentation,
                    contentTypes: presentation.map { [$0.contentType] } ?? [.data],
                    defaultFilename: presentation.map {
                        ExportFilePresentation.defaultFilename(for: $0.url)
                    }
                ) { result in
                    guard let presentation else { return }
                    switch result {
                    case .success:
                        finish(presentation: presentation)
                    case .failure(let error) where error.isUserCancellation:
                        finish(presentation: presentation)
                    case .failure(let error):
                        // Keep both the item and its source file. The user can
                        // retry the same transfer or explicitly discard it.
                        lifecycle.retainAfterFailure(itemID: presentation.id)
                        exportFailure = ExportFailure(
                            itemID: presentation.id,
                            message: error.localizedDescription
                        )
                    }
                } onCancellation: {
                    guard let presentation else { return }
                    finish(presentation: presentation)
                }
                .alert(item: $exportFailure) { failure in
                    Alert(
                        title: Text("Couldn't Save File"),
                        message: Text(failure.message),
                        primaryButton: .default(Text("Retry")) {
                            retry(itemID: failure.itemID)
                        },
                        secondaryButton: .destructive(Text("Discard")) {
                            guard let presentation = activePresentation,
                                  presentation.id == failure.itemID else { return }
                            finish(presentation: presentation)
                        }
                    )
                }
                .onChange(of: item?.id, initial: true) { _, _ in
                    syncPresentation()
                }
        } else {
            content.sheet(item: $item) { presented in
                VStack(spacing: 0) {
                    if let notice = presented.notice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .padding()
                            .accessibilityIdentifier("exportIRSRateFreshness")
                        Divider()
                    }
                    ActivityShareSheet(items: [presented.url]) {
                        finishActivityShare(presentation: presented)
                    }
                }
            }
        }
    }

    private func syncPresentation() {
        guard activePresentation == nil else { return }
        guard let item else {
            lifecycle.reset()
            exportFailure = nil
            return
        }
        activePresentation = item
        lifecycle.begin(itemID: item.id)
        do {
            // Metadata-only preflight. The representation repeats this check
            // when the system actually requests the file, closing the race if
            // a temporary source disappears while the panel is open.
            try item.validateSource()
        } catch {
            model.present(error, .export)
            finish(presentation: item)
        }
    }

    private func retry(itemID: UUID) {
        guard let item = activePresentation, item.id == itemID else { return }
        do {
            try item.validateSource()
            exportFailure = nil
            _ = lifecycle.retry(itemID: itemID)
        } catch {
            model.present(error, .export)
            finish(presentation: item)
        }
    }

    private func finish(presentation: ActivityShareItem) {
        // Completion, cancellation, and explicit discard can race the binding's
        // presentation reset. The captured item identity is the exactly-once
        // gate and prevents a stale A callback from finishing replacement B.
        guard activePresentation?.id == presentation.id,
              lifecycle.finish(itemID: presentation.id) else { return }
        activePresentation = nil
        exportFailure = nil
        presentation.removeOwnedSources()

        // Never clear or run completion work against a replacement item.
        if item?.id == presentation.id {
            item = nil
            onComplete?()
        }
        // A replacement set while the prior panel was open can now present.
        syncPresentation()
    }

    private func finishActivityShare(presentation: ActivityShareItem) {
        presentation.removeOwnedSources()
        let hasReplacement = item.map { $0.id != presentation.id } ?? false
        if item?.id == presentation.id {
            item = nil
        }
        if !hasReplacement {
            onComplete?()
        }
    }
}

private extension Error {
    /// The save panel's Cancel surfaces as `NSUserCancelledError`; treating it
    /// as a failure would alert on every backed-out export.
    var isUserCancellation: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

extension View {
    func exportShare(
        item: Binding<ActivityShareItem?>,
        onComplete: (@MainActor () -> Void)? = nil
    ) -> some View {
        modifier(ExportShareModifier(item: item, onComplete: onComplete))
    }
}
