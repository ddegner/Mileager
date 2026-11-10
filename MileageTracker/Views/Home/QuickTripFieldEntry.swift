import AppCore
import SwiftUI

enum QuickTripField: String, CaseIterable, Identifiable {
    case purpose
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .purpose: String(localized: "Purpose")
        case .notes: String(localized: "Notes")
        }
    }

    var systemImage: String {
        switch self {
        case .purpose: "tag"
        case .notes: "note.text"
        }
    }

    var placeholder: String {
        switch self {
        case .purpose: String(localized: "Purpose")
        case .notes: String(localized: "Add a note")
        }
    }

    var usesKeyboardEntry: Bool {
        switch self {
        case .purpose: false
        case .notes: true
        }
    }
}

struct QuickTripEntryRequest: Identifiable {
    var trip: TripSummary
    var field: QuickTripField

    var id: String {
        "\(trip.id.uuidString)-\(field.rawValue)"
    }
}

struct QuickTripFieldEntryView: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var trip: TripSummary
    var field: QuickTripField

    @State private var text: String
    @State private var didCommit = false
    /// Set only by an explicit user edit (picking a purpose, typing a note).
    /// The default-purpose prefill assigns `text` directly and must not flip
    /// this, so dismissing the sheet without choosing anything commits nothing.
    @State private var userDidEdit = false
    @FocusState private var isFocused: Bool

    init(trip: TripSummary, field: QuickTripField) {
        self.trip = trip
        self.field = field
        _text = State(initialValue: Self.initialText(for: trip, field: field))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    editor
                }
            }
            .accessibilityIdentifier("quickTripEntryForm")
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground()
            .onAppear {
                applyDefaultPurposeIfNeeded()
                if field.usesKeyboardEntry {
                    isFocused = true
                }
            }
            .onSubmit {
                saveAndDismiss()
            }
            .safeAreaBar(edge: .bottom) {
                if isFocused {
                    KeyboardActionBar(onDone: saveAndDismiss)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: saveAndDismiss,
                        accessibilityLabel: String(localized: "Save"),
                        accessibilityIdentifier: "quickEntryConfirm"
                    )
                }
            }
        }
        .mileageEditorPresentation(
            macSize: field == .purpose ? .standard : .compact,
            detents: [.height(presentationHeight)],
            dragIndicator: .visible
        )
        // Persist a real edit even when the sheet is swiped/tapped away rather
        // than confirmed — but only a real edit, never the auto-prefilled default.
        .onDisappear { commitIfNeeded(force: false) }
    }

    @ViewBuilder
    private var editor: some View {
        if field == .purpose {
            BusinessPurposePicker(
                purpose: Binding(get: { text }, set: { markEdited($0) }),
                presentation: .list,
                onSelect: { markEdited($0) }
            )
        } else {
            TextField(
                field.placeholder,
                text: Binding(get: { text }, set: { markEdited($0) }),
                axis: .vertical
            )
            .lineLimit(4, reservesSpace: true)
            .focused($isFocused)
            .accessibilityIdentifier("quickTripText")
        }
    }

    private func markEdited(_ newValue: String) {
        if newValue != text { userDidEdit = true }
        text = newValue
    }

    private var presentationHeight: CGFloat {
        switch field {
        case .purpose: 430
        case .notes: 260
        }
    }

    /// Commits the current value. `force` is the explicit-confirm path (checkmark
    /// or keyboard Done), which accepts the prefilled default; an implicit
    /// dismiss passes `force: false` and only commits when the user edited,
    /// so opening and swiping the sheet away never reclassifies the trip.
    private func commitIfNeeded(force: Bool) {
        guard !didCommit, force || userDidEdit else { return }
        didCommit = true
        switch field {
        case .purpose:
            model.updateQuickPurpose(trip, purpose: text)
        case .notes:
            model.updateQuickNotes(trip, notes: text)
        }
    }

    private func saveAndDismiss() {
        isFocused = false
        commitIfNeeded(force: true)
        dismiss()
    }

    private func applyDefaultPurposeIfNeeded() {
        guard field == .purpose else { return }
        text = model.defaultBusinessPurposeIfNeeded(
            currentPurpose: text,
            classification: .business
        )
    }

    private static func initialText(for trip: TripSummary, field: QuickTripField) -> String {
        switch field {
        case .purpose: trip.businessPurpose ?? ""
        case .notes: trip.notes ?? ""
        }
    }
}
