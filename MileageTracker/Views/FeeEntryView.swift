import AppCore
import SwiftUI

struct FeeEntryRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case trip(UUID)
        case draft(UUID)
    }

    var target: Target
    var category: TripFeeCategory
    var fee: TripFee?

    var id: String {
        let targetID = switch target {
        case .trip(let tripID):
            "trip-\(tripID.uuidString)"
        case .draft(let draftID):
            "draft-\(draftID.uuidString)"
        }
        return [
            targetID,
            category.rawValue,
            fee?.id.uuidString ?? "new"
        ].joined(separator: "-")
    }

    var tripID: UUID? {
        guard case .trip(let tripID) = target else { return nil }
        return tripID
    }

    var isDraft: Bool {
        guard case .draft = target else { return false }
        return true
    }

    static func trip(_ trip: TripSummary, category: TripFeeCategory = .toll, fee: TripFee? = nil) -> FeeEntryRequest {
        FeeEntryRequest(target: .trip(trip.id), category: fee?.category ?? category, fee: fee)
    }

    static func draft(category: TripFeeCategory = .toll, fee: TripFee? = nil) -> FeeEntryRequest {
        FeeEntryRequest(target: .draft(fee?.id ?? UUID()), category: fee?.category ?? category, fee: fee)
    }
}

struct FeeEntryView: View {
    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var request: FeeEntryRequest
    var onSaveDraft: ((TripFee) -> Void)?

    @State private var category: TripFeeCategory
    @State private var amountText: String
    @State private var label: String
    @State private var occurredAt: Date
    /// New fees focus the amount immediately, so start tall enough that the
    /// preset list stays visible above the keyboard; edits open at medium.
    @State private var detent: PresentationDetent
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case amount
        case label
    }

    init(request: FeeEntryRequest, onSaveDraft: ((TripFee) -> Void)? = nil) {
        self.request = request
        self.onSaveDraft = onSaveDraft
        _category = State(initialValue: request.fee?.category ?? request.category)
        _amountText = State(initialValue: request.fee.map { Self.amountText($0.amount) } ?? "")
        _label = State(initialValue: request.fee?.label ?? "")
        _occurredAt = State(initialValue: request.fee?.occurredAt ?? Date())
        _detent = State(initialValue: request.fee == nil ? .large : .medium)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $category) {
                        ForEach(TripFeeCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Spacer(minLength: 0)
                        Text(CurrencyFormatting.symbol(code: model.currencyCode))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: true, vertical: false)
                            .focused($focusedField, equals: .amount)
                            .accessibilityLabel(String(localized: "Amount"))
                            .accessibilityIdentifier("feeEntryAmount")
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)

                    TextField("Notes", text: $label)
                        .focused($focusedField, equals: .label)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("feeEntryLabel")

                    DatePicker("Date", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                }

                if request.fee == nil, !matchingPresets.isEmpty {
                    Section("Presets") {
                        ForEach(matchingPresets) { preset in
                            Button {
                                apply(preset)
                            } label: {
                                LabeledContent(preset.label, value: preset.amount, format: .currency(code: model.currencyCode))
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(request.fee == nil ? String(localized: "Add Fee") : String(localized: "Edit Fee"))
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground()
            .onAppear {
                focusedField = request.fee == nil ? .amount : nil
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: save,
                        isDisabled: amount == nil,
                        accessibilityLabel: String(localized: "Save Fee"),
                        accessibilityIdentifier: "feeEntrySave"
                    )
                }
            }
        }
        .mileageEditorPresentation(
            detents: [.medium, .large],
            selection: $detent,
            dragIndicator: .visible
        )
    }

    private var matchingPresets: [TripFeePreset] {
        model.feePresets
            .filter { $0.category == category }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var amount: Double? {
        NumericTextInput.positiveDouble(amountText)
    }

    private func save() {
        guard let amount else { return }
        if request.isDraft {
            onSaveDraft?(draftFee(amount: amount, source: request.fee?.source ?? .manual, presetID: request.fee?.presetID))
        } else if let existing = request.fee {
            var edited = existing
            edited.category = category
            edited.amount = amount
            edited.label = normalizedLabel
            edited.occurredAt = occurredAt
            _ = model.updateFee(edited)
        } else if let tripID = request.tripID, let trip = model.trip(id: tripID) {
            _ = model.addFee(
                to: trip,
                category: category,
                amount: amount,
                occurredAt: occurredAt,
                label: normalizedLabel,
                source: .manual
            )
        }
        dismiss()
    }

    private func apply(_ preset: TripFeePreset) {
        if request.isDraft {
            onSaveDraft?(draftFee(amount: preset.amount, label: preset.label, source: .preset, presetID: preset.id))
        } else if let tripID = request.tripID, let trip = model.trip(id: tripID) {
            model.applyFeePreset(preset, to: trip)
        }
        dismiss()
    }

    private var normalizedLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func draftFee(
        amount: Double,
        label overrideLabel: String? = nil,
        source: TripFeeSource,
        presetID: UUID?
    ) -> TripFee {
        TripFee(
            id: request.fee?.id ?? UUID(),
            tripID: nil,
            category: category,
            amount: amount,
            occurredAt: occurredAt,
            label: overrideLabel ?? normalizedLabel,
            source: source,
            presetID: presetID
        )
    }

    private static func amountText(_ amount: Double) -> String {
        NumericTextInput.fixedTwoDecimals(amount)
    }
}
