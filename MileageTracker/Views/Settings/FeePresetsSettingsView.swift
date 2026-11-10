import AppCore
import SwiftUI

/// Drill-in editor for toll and parking fee presets. Always in edit mode —
/// on a dedicated edit screen the delete/reorder chrome is expected, unlike
/// on the main Settings page. Drafts are saved when the page disappears
/// (pop or sheet dismissal), matching the trip-purposes editor.
///
/// Presets are Cloud-synced and the Mac edits them too, and the store
/// tombstones any key missing from a save. Saving therefore never writes the
/// draft list directly: user operations are computed against the baseline
/// captured at load and replayed onto the *current* list, so a preset that
/// synced in while this page was open is never clobbered or tombstoned.
struct FeePresetsSettingsView: View {
    @Environment(MileageAppModel.self) private var model
    @State private var drafts: [FeePresetDraft] = []
    @State private var baseline: [TripFeePreset] = []
    @State private var editMode: EditMode = .active
    @FocusState private var focusedField: FocusTarget?

    private enum FocusTarget: Hashable {
        case label(UUID)
        case amount(UUID)
    }

    var body: some View {
        Form {
            Section {
                ForEach($drafts) { $draft in
                    HStack(spacing: 8) {
                        Picker("Type", selection: $draft.category) {
                            ForEach(TripFeeCategory.allCases) { category in
                                Text(category.displayName).tag(category)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()

                        TextField("Label", text: $draft.label)
                            .textInputAutocapitalization(.words)
                            .focused($focusedField, equals: .label(draft.id))
                            .accessibilityIdentifier("settingsFeePresetLabelField")
                            .accessibilityValue(draft.label)

                        Text(CurrencyFormatting.symbol(code: model.currencyCode))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $draft.amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .amount(draft.id))
                            .frame(maxWidth: 72)
                            .accessibilityIdentifier("settingsFeePresetAmountField")
                            .accessibilityValue(draft.amountText)
                    }
                }
                .onDelete { drafts.remove(atOffsets: $0) }
                .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    let draft = FeePresetDraft()
                    drafts.append(draft)
                    focusedField = .label(draft.id)
                } label: {
                    Label("Add Preset", systemImage: "plus.circle.fill")
                }
                .accessibilityLabel("Add Preset")
                .accessibilityIdentifier("settingsAddFeePresetButton")
                .fullWidthListRowSeparator()
            } footer: {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("Presets appear as one-tap options when adding a fee to a trip. Drag to reorder.")
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .environment(\.editMode, $editMode)
        .navigationTitle("Fee Presets")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .onAppear(perform: reload)
        .onChange(of: model.feePresets) { _, _ in
            // A sync import landed while the page is open. If the user hasn't
            // touched anything, show the imported truth; if they have, leave
            // the editor alone — save() merges against the current list.
            if FeePresetMergePlan.resolved(drafts: drafts, baseline: baseline) == baseline {
                reload()
            }
        }
        .onDisappear(perform: save)
    }

    /// Advisory only — save() falls back per-row instead of discarding edits.
    private var validationMessage: String? {
        if drafts.contains(where: { NumericTextInput.positiveDouble($0.amountText) == nil }) {
            return String(localized: "Enter an amount greater than 0.")
        }
        if FeePresetMergePlan.hasDuplicateIdentity(drafts: drafts) {
            return String(localized: "Preset names must be unique within a category.")
        }
        return nil
    }

    private func reload() {
        baseline = model.feePresets.sorted { $0.sortOrder < $1.sortOrder }
        drafts = baseline.map(FeePresetDraft.init)
    }

    private func save() {
        let merged = FeePresetMergePlan.merge(
            drafts: drafts,
            baseline: baseline,
            current: model.feePresets.sorted { $0.sortOrder < $1.sortOrder }
        )
        guard let merged else { return }
        model.saveFeePresets(merged)
    }
}

struct FeePresetDraft: Identifiable, Equatable {
    var id = UUID()
    var category: TripFeeCategory = .toll
    var label = ""
    var amountText = ""

    init() {}

    init(_ preset: TripFeePreset) {
        id = preset.id
        category = preset.category
        label = preset.label
        amountText = NumericTextInput.fixedTwoDecimals(preset.amount)
    }
}

/// Pure merge logic for the fee-preset editor, separated for tests.
enum FeePresetMergePlan {
    /// Resolves drafts to concrete presets. A row whose amount doesn't parse
    /// falls back to its baseline preset (a botched edit never destroys the
    /// preset); an invalid row with no baseline (an abandoned Add) is dropped.
    /// An empty label falls back to the category name, matching how the old
    /// in-sheet "Save as preset" toggle labeled unlabeled fees.
    static func resolved(drafts: [FeePresetDraft], baseline: [TripFeePreset]) -> [TripFeePreset] {
        let baselineByID = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TripFeePreset] = []
        for draft in drafts {
            if let amount = NumericTextInput.positiveDouble(draft.amountText) {
                let trimmed = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(TripFeePreset(
                    id: draft.id,
                    category: draft.category,
                    label: trimmed.isEmpty ? draft.category.displayName : trimmed,
                    amount: amount,
                    sortOrder: result.count
                ))
            } else if let original = baselineByID[draft.id] {
                result.append(TripFeePreset(
                    id: original.id,
                    category: original.category,
                    label: original.label,
                    amount: original.amount,
                    sortOrder: result.count
                ))
            }
        }
        return result
    }

    static func hasDuplicateIdentity(drafts: [FeePresetDraft]) -> Bool {
        var seen = Set<String>()
        for draft in drafts {
            let trimmed = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmed.isEmpty ? draft.category.displayName : trimmed
            if !seen.insert("\(draft.category.rawValue)|\(label.lowercased())").inserted {
                return true
            }
        }
        return false
    }

    /// Replays the user's operations (baseline → drafts) onto `current`,
    /// which may have changed under the page via CloudKit. Returns nil when
    /// there is nothing to save: either the user changed nothing (a remote
    /// import alone must never trigger a save — the store would tombstone
    /// every key missing from the written list), or the merge result already
    /// equals `current`.
    static func merge(
        drafts: [FeePresetDraft],
        baseline: [TripFeePreset],
        current: [TripFeePreset]
    ) -> [TripFeePreset]? {
        let local = resolved(drafts: drafts, baseline: baseline)
        guard !isEquivalent(local, baseline) else { return nil }

        let baselineByKey = byKey(baseline)
        let currentByKey = byKey(current)
        let localKeys = Set(local.map(identityKey))

        var result: [TripFeePreset] = []
        for item in local {
            let key = identityKey(item)
            if let baselineVersion = baselineByKey[key],
               valueEquals(item, baselineVersion) {
                // Untouched by the user: defer to the current list — pick up
                // a remote edit, or honor a remote deletion by dropping it.
                if let currentVersion = currentByKey[key] {
                    result.append(currentVersion)
                }
            } else {
                result.append(item)
            }
        }
        // Presets that appeared remotely while the page was open (keys the
        // user never saw) are preserved, appended after the user's ordering.
        for item in current where baselineByKey[identityKey(item)] == nil && !localKeys.contains(identityKey(item)) {
            result.append(item)
        }
        let renumbered = result.enumerated().map { index, preset in
            TripFeePreset(id: preset.id, category: preset.category, label: preset.label, amount: preset.amount, sortOrder: index)
        }
        guard !isEquivalent(renumbered, current) else { return nil }
        return renumbered
    }

    private static func byKey(_ presets: [TripFeePreset]) -> [String: TripFeePreset] {
        Dictionary(presets.map { (identityKey($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Mirrors TripFeePresetStore's sync identity (category + case-folded label).
    private static func identityKey(_ preset: TripFeePreset) -> String {
        "\(preset.category.rawValue)|\(preset.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func valueEquals(_ lhs: TripFeePreset, _ rhs: TripFeePreset) -> Bool {
        lhs.category == rhs.category && lhs.label == rhs.label && lhs.amount == rhs.amount
    }

    /// Order-sensitive equality ignoring sortOrder renumbering and draft IDs.
    private static func isEquivalent(_ lhs: [TripFeePreset], _ rhs: [TripFeePreset]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { valueEquals($0, $1) }
    }
}
