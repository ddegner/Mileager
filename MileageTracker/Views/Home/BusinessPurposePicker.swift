import AppCore
import SwiftUI

/// Single component that replaces the three near-identical purpose pickers.
/// Pass `.menu` for a settings-row-style Menu, `.list` for the inline button
/// list used by the quick-entry sheet.
struct BusinessPurposePicker: View {
    enum Presentation { case menu, list }

    @Environment(MileageAppModel.self) private var model

    @Binding var purpose: String
    var presentation: Presentation
    var onSelect: ((String) -> Void)?

    @State private var showingCustom = false

    init(
        purpose: Binding<String>,
        presentation: Presentation,
        onSelect: ((String) -> Void)? = nil
    ) {
        self._purpose = purpose
        self.presentation = presentation
        self.onSelect = onSelect
    }

    var body: some View {
        switch presentation {
        case .menu:
            Menu { optionButtons } label: { menuLabel }
                .buttonStyle(.plain)
                .tint(.primary)
                .accessibilityValue(trimmedPurpose.isEmpty ? String(localized: "None") : trimmedPurpose)
                .sheet(isPresented: $showingCustom) { customSheet }
        case .list:
            Group { optionButtons }
                .sheet(isPresented: $showingCustom) { customSheet }
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        ForEach(availablePurposes, id: \.self) { option in
            Button {
                apply(option)
            } label: {
                optionLabel(for: option)
            }
        }

        if presentation == .menu, !availablePurposes.isEmpty {
            Divider()
        }

        Button {
            showingCustom = true
        } label: {
            Label("Custom...", systemImage: "square.and.pencil")
        }

        if !trimmedPurpose.isEmpty {
            Button(role: .destructive) {
                apply("")
            } label: {
                Label("Clear Purpose", systemImage: "xmark.circle.fill")
            }
        }
    }

    @ViewBuilder
    private func optionLabel(for option: String) -> some View {
        switch presentation {
        case .menu:
            if isSelected(option) {
                Label(option, systemImage: "checkmark")
            } else {
                Text(option)
            }
        case .list:
            HStack {
                Text(option).foregroundStyle(.primary)
                Spacer()
                if isSelected(option) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(MileageTheme.appTint)
                }
            }
        }
    }

    private var menuLabel: some View {
        HStack {
            Text("Purpose")
            Spacer()
            Text(trimmedPurpose.isEmpty ? String(localized: "None") : trimmedPurpose)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private var customSheet: some View {
        BusinessPurposeCustomEntryView(initialPurpose: purpose) { selected in
            apply(selected)
        }
        .environment(model)
    }

    private var trimmedPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var availablePurposes: [String] {
        BusinessPurposePresetStore.normalized([trimmedPurpose] + model.businessPurposePresets)
    }

    private func apply(_ selected: String) {
        purpose = selected
        onSelect?(selected)
    }

    private func isSelected(_ option: String) -> Bool {
        option.caseInsensitiveCompare(trimmedPurpose) == .orderedSame
    }
}

struct BusinessPurposeCustomEntryView: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var onSave: (String) -> Void
    var onAddToPresets: ((String) -> Void)?

    @State private var purpose: String
    @State private var addToPresets = true
    @FocusState private var isFocused: Bool

    init(
        initialPurpose: String,
        onAddToPresets: ((String) -> Void)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.onSave = onSave
        self.onAddToPresets = onAddToPresets
        _purpose = State(initialValue: initialPurpose)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Purpose", text: $purpose)
                        .textInputAutocapitalization(.sentences)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            isFocused = false
                        }
                    ForEach(completionSuggestions, id: \.self) { suggestion in
                        Button {
                            purpose = suggestion
                        } label: {
                            Label(suggestion, systemImage: "text.cursor")
                        }
                        .accessibilityIdentifier("businessPurposeCompletion-\(suggestion)")
                    }
                    Toggle("Add to presets", isOn: $addToPresets)
                }
            }
            .navigationTitle("Custom Purpose")
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground()
            .onAppear { isFocused = true }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: save,
                        isDisabled: trimmedPurpose.isEmpty,
                        accessibilityLabel: String(localized: "Save"),
                        accessibilityIdentifier: "businessPurposeCustomConfirm"
                    )
                }
            }
        }
        .mileageEditorPresentation(
            macSize: .compact,
            detents: [.height(230)],
            dragIndicator: .visible
        )
    }

    private var trimmedPurpose: String {
        purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var completionSuggestions: [String] {
        guard !trimmedPurpose.isEmpty else { return [] }
        return BusinessPurposePresetStore.completionSuggestions(
            for: trimmedPurpose,
            in: model.businessPurposePresets,
            limit: 3
        )
    }

    private func save() {
        guard !trimmedPurpose.isEmpty else { return }
        if addToPresets {
            if let onAddToPresets {
                onAddToPresets(trimmedPurpose)
            } else {
                model.addBusinessPurposePreset(trimmedPurpose)
            }
        }
        onSave(trimmedPurpose)
        dismiss()
    }
}
