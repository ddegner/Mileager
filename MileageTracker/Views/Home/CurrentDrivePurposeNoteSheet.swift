import AppCore
import SwiftUI

/// A detented quick-entry sheet for a recording business drive's purpose and note.
struct CurrentDrivePurposeNoteSheet: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let summary: CurrentDriveSummary

    @State private var purpose: String
    @State private var note: String
    @State private var showingNoteField: Bool
    @State private var noteEdited = false
    @FocusState private var noteFocused: Bool

    init(summary: CurrentDriveSummary) {
        self.summary = summary
        let existing = summary.note ?? ""
        _purpose = State(initialValue: summary.businessPurpose ?? "")
        _note = State(initialValue: existing)
        _showingNoteField = State(
            initialValue: !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purpose") {
                    BusinessPurposePicker(purpose: purposeBinding, presentation: .list)
                }

                Section("Note") {
                    if showingNoteField {
                        TextField("Note", text: $note, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                            .textInputAutocapitalization(.sentences)
                            .focused($noteFocused)
                            .accessibilityIdentifier("currentDriveNoteField")
                    } else {
                        Button("Add Note", systemImage: "note.text") {
                            revealNoteField()
                        }
                            .accessibilityIdentifier("currentDriveBarAddNote")
                    }
                }
            }
            .navigationTitle("Business Drive")
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: saveAndDismiss,
                        isDisabled: false,
                        accessibilityLabel: String(localized: "Done"),
                        accessibilityIdentifier: "currentDriveDetailsConfirm"
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
        .onChange(of: note) { _, _ in noteEdited = true }
        .onDisappear { commitNote() }
    }

    private var purposeBinding: Binding<String> {
        Binding(
            get: { purpose },
            set: { updatePurpose($0) }
        )
    }

    private func updatePurpose(_ newValue: String) {
        purpose = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCurrentDriveBusinessPurpose(trimmed.isEmpty ? nil : trimmed)
    }

    private func revealNoteField() {
        showingNoteField = true
        noteFocused = true
    }

    private func saveAndDismiss() {
        commitNote()
        dismiss()
    }

    private func commitNote() {
        guard noteEdited else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCurrentDriveNote(trimmed.isEmpty ? nil : trimmed)
    }
}
