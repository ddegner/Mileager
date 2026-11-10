import SwiftUI

/// Drill-in editor for the business-purpose presets. Always in edit mode —
/// on a dedicated edit screen the delete/reorder chrome is expected, unlike
/// on the main Settings page. Drafts are saved when the page disappears
/// (pop or sheet dismissal), matching the previous save-on-Done behavior.
struct TripPurposesSettingsView: View {
    @Environment(MileageAppModel.self) private var model
    @State private var drafts: [BusinessPurposeDraft] = []
    @State private var editMode: EditMode = .active
    @FocusState private var focusedDraftID: UUID?

    var body: some View {
        Form {
            Section {
                ForEach($drafts) { $draft in
                    HStack {
                        TextField("Purpose", text: $draft.text)
                            .textInputAutocapitalization(.sentences)
                            .focused($focusedDraftID, equals: draft.id)
                            .submitLabel(.done)
                            .accessibilityIdentifier("settingsPurposeField")
                            .accessibilityValue(draft.text)
                            .onSubmit {
                                focusedDraftID = nil
                            }

                        if drafts.first?.id == draft.id {
                            Text("Default")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { drafts.remove(atOffsets: $0) }
                .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    drafts.append(BusinessPurposeDraft(text: nextPurposeName()))
                } label: {
                    Label("Add Purpose", systemImage: "plus.circle.fill")
                }
                .accessibilityLabel("Add Purpose")
                .accessibilityIdentifier("settingsAddPurposeButton")
                .fullWidthListRowSeparator()
            } footer: {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("The first purpose is the default for new business trips. Drag to reorder.")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Trip Purposes")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .onAppear {
            drafts = model.businessPurposePresets.map(BusinessPurposeDraft.init(text:))
        }
        .onDisappear(perform: save)
    }

    private var validationMessage: String? {
        let trimmed = drafts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.contains(where: \.isEmpty) {
            return String(localized: "Purpose names cannot be empty.")
        }

        let uniqueCount = Set(trimmed.map { $0.lowercased() }).count
        if uniqueCount != trimmed.count {
            return String(localized: "Purpose names must be unique.")
        }

        return nil
    }

    private func save() {
        guard validationMessage == nil else { return }
        let purposes = drafts.map(\.text)
        guard purposes != model.businessPurposePresets else { return }
        model.saveBusinessPurposePresets(purposes)
    }

    private func nextPurposeName() -> String {
        let existing = Set(drafts.map { $0.text.lowercased() })
        let base = String(localized: "New purpose")
        guard !existing.contains(base.lowercased()) else {
            var index = 2
            while existing.contains("\(base) \(index)".lowercased()) {
                index += 1
            }
            return "\(base) \(index)"
        }

        return base
    }
}

struct BusinessPurposeDraft: Identifiable, Equatable {
    var id = UUID()
    var text: String

    init(text: String) {
        self.text = text
    }
}
