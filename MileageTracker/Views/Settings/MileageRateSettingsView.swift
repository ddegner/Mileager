import AppCore
import SwiftUI

private struct MileageRateEditorRequest: Identifiable {
    enum Kind {
        case base
        case rule(MileageRateRule)
        case newRule
    }

    let id = UUID()
    var kind: Kind
}

struct MileageRateSettingsView: View {
    @Environment(MileageAppModel.self) private var model
    @State private var editor: MileageRateEditorRequest?
    @State private var hasRequestedIRS = false
    @State private var setupTask: Task<Void, Never>?

    var body: some View {
        Form {
            if model.currencyCode == "USD" {
                rateSourceSection
            }

            Section {
                if !model.mileageRateSchedule.requiresCustomRate {
                    LabeledContent("Current Rate", value: rateLabel(model.mileageRateSchedule.rate(on: model.irsRateNow())))
                        .accessibilityIdentifier(isFollowingIRS ? "settingsIRSCurrentRate" : "settingsCustomCurrentRate")
                }
                if !isFollowingIRS {
                    Button(model.mileageRateSchedule.requiresCustomRate ? String(localized: "Set Rate") : String(localized: "Edit Rate")) {
                        requestEdit(MileageRateEditorRequest(kind: .newRule))
                    }
                    .accessibilityIdentifier("settingsEditMileageRate")
                }
            }

            if let status = model.irsRateStatusMessage {
                Section {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settingsIRSRateStatus")
                }
            }
            if model.irsRateHasConflicts {
                irsConflictSection
            }

            if !model.mileageRateSchedule.requiresCustomRate {
                Section {
                    DisclosureGroup {
                        historyRows
                    } label: {
                        Text("Rate History")
                            .accessibilityIdentifier("settingsMileageRateHistory")
                    }
                }
            }

            if model.currencyCode == "USD",
               isFollowingIRS || hasRequestedIRS || model.irsRateIsChecking || model.irsRateStatusMessage != nil {
                Section {
                    DisclosureGroup {
                        irsCheckRows
                    } label: {
                        Text("Update Details")
                            .accessibilityIdentifier("settingsIRSUpdateDetails")
                    }
                }
            }
        }
        .navigationTitle("Mileage Rates")
        .navigationBarTitleDisplayMode(.inline)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .sheet(item: $editor) { request in
            NavigationStack {
                MileageRateEditorView(
                    request: request,
                    schedule: model.mileageRateSchedule,
                    currencyCode: model.currencyCode,
                    distanceUnit: model.distanceUnit,
                    historyStartDate: model.mileageRateHistoryStartDate,
                    now: model.irsRateNow(),
                    onSave: save
                )
            }
            .mileageEditorPresentation(macSize: .compact, detents: [.medium, .large])
        }
        .onDisappear {
            setupTask?.cancel()
            setupTask = nil
        }
        .onChange(of: model.currencyCode) { _, currency in
            if currency != "USD" { cancelPendingIRSSelection() }
        }
    }

    private var rateSourceSection: some View {
        Section("Rate Source") {
            Button {
                if !isFollowingIRS { prepareIRSSetup() }
            } label: {
                sourceRow(title: String(localized: "IRS business rate"), selected: isFollowingIRS, isChecking: model.irsRateIsChecking) {
                    if isFollowingIRS {
                        Text("Updates automatically").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.irsRateIsChecking)
            .accessibilityIdentifier("settingsIRSMileageRateSource")
            .accessibilityAddTraits(isFollowingIRS ? [.isSelected] : [])

            Button {
                requestEdit(MileageRateEditorRequest(kind: .newRule))
            } label: {
                sourceRow(title: String(localized: "Custom"), selected: !isFollowingIRS) { EmptyView() }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settingsCustomMileageRateSource")
            .accessibilityAddTraits(!isFollowingIRS ? [.isSelected] : [])
        }
    }

    private func sourceRow<Detail: View>(title: String, selected: Bool, isChecking: Bool = false, @ViewBuilder detail: () -> Detail) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                detail()
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            } else if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var historyRows: some View {
        ForEach(historyRules.reversed()) { rule in
            if isFollowingIRS {
                historyLabel(date: rule.effectiveFrom, rate: rule.rate)
                    .accessibilityIdentifier(ruleIdentifier(rule))
            } else {
                Button {
                    requestEdit(MileageRateEditorRequest(kind: .rule(rule)))
                } label: {
                    historyLabel(date: rule.effectiveFrom, rate: rule.rate)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(ruleIdentifier(rule))
                .swipeActions {
                    Button("Delete", role: .destructive) { delete(rule) }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(rule) }
                }
            }
        }
        if showsInitialCustomRate {
            if isFollowingIRS {
                historyLabel(date: model.mileageRateHistoryStartDate, rate: model.mileageRateSchedule.baseRate)
            } else {
                Button {
                    requestEdit(MileageRateEditorRequest(kind: .base))
                } label: {
                    historyLabel(date: model.mileageRateHistoryStartDate, rate: model.mileageRateSchedule.baseRate)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsBaseMileageRate")
            }
        }
        if !isFollowingIRS {
            Button("Add Rate", systemImage: "plus") {
                requestEdit(MileageRateEditorRequest(kind: .newRule))
            }
            .accessibilityIdentifier("settingsAddMileageRate")
        }
    }

    private func historyLabel(date: MileageRateEffectiveDate, rate: MileageRate) -> some View {
        LabeledContent(effectiveDateLabel(date), value: rateLabel(rate))
    }

    private func ruleIdentifier(_ rule: MileageRateRule) -> String {
        "settingsMileageRateRule-\(rule.effectiveFrom.year)-\(rule.effectiveFrom.month)-\(rule.effectiveFrom.day)"
    }

    @ViewBuilder
    private var irsCheckRows: some View {
        HStack {
            Text("Last Checked")
            Spacer()
            Text(model.irsRateLastSuccessfulCheck.map {
                $0.formatted(date: .abbreviated, time: .omitted)
            } ?? String(localized: "Not Yet Checked"))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            Button {
                if isFollowingIRS {
                    Task { await model.checkIRSRateNow() }
                } else {
                    prepareIRSSetup()
                }
            } label: {
                Group {
                    if model.irsRateIsChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(model.irsRateIsChecking)
            .accessibilityLabel(Text("Check Now"))
            .accessibilityIdentifier("settingsCheckIRSRateNow")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsIRSLastChecked")

        Link(destination: URL(string: "https://www.irs.gov/tax-professionals/standard-mileage-rates")!) {
            Label {
                Text("IRS Standard Mileage Rates")
            } icon: {
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("settingsIRSRateSourceLink")
    }

    private var irsConflictSection: some View {
        Section("Review Rate Update") {
            Text("The IRS update overlaps custom rates. Choose which rates to use for the dates shown.")
            ForEach(model.irsRatePendingPeriods.sorted { $0.effectiveFrom < $1.effectiveFrom }, id: \.effectiveFrom) { period in
                LabeledContent(effectiveDateLabel(period.effectiveFrom), value: rateLabel(period.rate))
                    .accessibilityIdentifier("settingsIRSConflictPeriod-\(period.effectiveFrom.year)-\(period.effectiveFrom.month)-\(period.effectiveFrom.day)")
            }
            Text("Calculated values for existing trips from these dates will update. Saved PDFs do not change.")
                .foregroundStyle(.secondary)
            Button("Replace with IRS Rates") { model.resolveIRSRateConflicts(replaceManual: true) }
                .disabled(model.irsRateIsChecking)
                .accessibilityIdentifier("settingsReplaceCustomRatesWithIRS")
            Button("Keep Custom Rates") {
                hasRequestedIRS = false
                model.resolveIRSRateConflicts(replaceManual: false)
            }
            .disabled(model.irsRateIsChecking)
            .accessibilityIdentifier("settingsKeepCustomMileageRates")
        }
    }

    private func prepareIRSSetup() {
        setupTask?.cancel()
        hasRequestedIRS = true
        setupTask = Task { @MainActor in
            guard hasRequestedIRS, model.currencyCode == "USD" else { return }
            _ = await model.chooseIRSBusinessRate()
        }
    }

    private func cancelPendingIRSSelection() {
        hasRequestedIRS = false
        setupTask?.cancel()
        setupTask = nil
        if !isFollowingIRS { model.cancelIRSRateCheck(clearStatus: true) }
    }

    private var isFollowingIRS: Bool { model.mileageRateSchedule.irsFollowingFrom != nil }

    private func requestEdit(_ request: MileageRateEditorRequest) {
        cancelPendingIRSSelection()
        editor = request
    }

    private var showsInitialCustomRate: Bool {
        !model.mileageRateSchedule.normalizedRules.contains { $0.effectiveFrom <= model.mileageRateHistoryStartDate }
    }

    private var historyRules: [MileageRateRule] {
        let rules = model.mileageRateSchedule.normalizedRules
        let start = model.mileageRateHistoryStartDate
        let laterRules = rules.filter { $0.effectiveFrom > start }
        if let initialRule = rules.last(where: { $0.effectiveFrom <= start }) {
            return [initialRule] + laterRules
        }
        return laterRules
    }

    private func rateLabel(_ rate: MileageRate) -> String {
        CurrencyFormatting.rateText(rate, code: model.currencyCode, unit: model.distanceUnit, minimumFractionDigits: 2)
    }

    private func effectiveDateLabel(_ date: MileageRateEffectiveDate) -> String {
        let label = date.date()?.formatted(date: .abbreviated, time: .omitted) ?? "\(date.year)-\(date.month)-\(date.day)"
        return String(localized: "From \(label)")
    }

    private func save(_ request: MileageRateEditorRequest, amount: Double, currency: String, unit: DistanceUnit, date: Date) {
        let editedRule: MileageRateRule?
        let editingBase: Bool
        switch request.kind {
        case .base: editedRule = nil; editingBase = true
        case .rule(let rule): editedRule = rule; editingBase = false
        case .newRule: editedRule = nil; editingBase = false
        }
        if model.saveCustomMileageRate(amount: amount, currency: currency, unit: unit, effectiveFrom: date,
                                       editingRuleID: editedRule?.id, expectedEditingRule: editedRule, editingBase: editingBase) {
            hasRequestedIRS = false
            editor = nil
        }
    }

    private func delete(_ rule: MileageRateRule) {
        // A synced source change must not turn a history deletion into an implicit opt-out.
        guard !isFollowingIRS else { return }
        var schedule = model.mileageRateSchedule
        schedule.rules.removeAll { $0.id == rule.id }
        model.saveMileageRateSchedule(schedule)
    }

    static func rowSummary(for model: MileageAppModel) -> String {
        guard !model.mileageRateSchedule.requiresCustomRate else { return String(localized: "Set Rate") }
        let rate = CurrencyFormatting.rateText(model.mileageRateSchedule.rate(on: model.irsRateNow()),
            code: model.currencyCode, unit: model.distanceUnit, minimumFractionDigits: 2)
        return model.mileageRateSchedule.irsFollowingFrom != nil ? String(localized: "IRS · \(rate)") : rate
    }
}

private struct MileageRateEditorView: View {
    let request: MileageRateEditorRequest
    let schedule: MileageRateSchedule
    let originalCurrency: String
    let onSave: (MileageRateEditorRequest, Double, String, DistanceUnit, Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var currencyCode: String
    @State private var distanceUnit: DistanceUnit
    @State private var effectiveDate: Date

    init(request: MileageRateEditorRequest, schedule: MileageRateSchedule, currencyCode: String,
         distanceUnit: DistanceUnit, historyStartDate: MileageRateEffectiveDate, now: Date,
         onSave: @escaping (MileageRateEditorRequest, Double, String, DistanceUnit, Date) -> Void) {
        self.request = request
        self.schedule = schedule
        originalCurrency = currencyCode
        self.onSave = onSave
        let rate: MileageRate
        let date: Date
        switch request.kind {
        case .base:
            rate = schedule.baseRate
            date = historyStartDate.date() ?? now
        case .newRule:
            rate = schedule.rate(on: now)
            date = schedule.requiresCustomRate ? historyStartDate.date() ?? now : now
        case .rule(let rule):
            rate = rule.rate
            date = rule.effectiveFrom.date() ?? now
        }
        _amountText = State(initialValue: schedule.requiresCustomRate ? "" : rate.converted(to: distanceUnit).amountPerUnit.formatted(.number.precision(.fractionLength(0...3))))
        _currencyCode = State(initialValue: currencyCode)
        _distanceUnit = State(initialValue: distanceUnit)
        _effectiveDate = State(initialValue: date)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Rate") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settingsMileageRateField")
                }
                NavigationLink {
                    CurrencyPickerView(selectedCode: currencyCode, confirmsChanges: false) { currencyCode = $0 }
                } label: {
                    LabeledContent("Currency", value: currencyCode)
                }
                .accessibilityIdentifier("settingsMileageRateCurrency")
                Picker("Per", selection: $distanceUnit) {
                    Text("Mile").tag(DistanceUnit.miles)
                    Text("Kilometer").tag(DistanceUnit.kilometers)
                }
                .accessibilityIdentifier("settingsMileageRateUnitPicker")
                if isBase || schedule.requiresCustomRate {
                    LabeledContent("Effective From", value: effectiveDate.formatted(date: .abbreviated, time: .omitted))
                } else {
                    DatePicker("Effective From", selection: $effectiveDate, displayedComponents: .date)
                        .accessibilityIdentifier("settingsMileageRateEffectiveDate")
                }
            } footer: {
                if currencyCode != originalCurrency {
                    Text("Existing rates and fees keep their numbers when you change currency. They are not converted.")
                }
            }
            if hasDuplicateDate {
                Text("Another rate already begins on this date.").foregroundStyle(.red)
            }
        }
        .navigationTitle("Mileage Rate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let amount else { return }
                    onSave(request, amount, currencyCode, distanceUnit, effectiveDate)
                }
                .disabled(amount == nil || hasDuplicateDate)
            }
        }
    }

    private var isBase: Bool {
        if case .base = request.kind { return true }
        return false
    }

    private var hasDuplicateDate: Bool {
        // Saving a new custom rate replaces the rule for that day. Moving a
        // historical custom rule must not overwrite a different manual entry.
        guard case .rule(let edited) = request.kind else { return false }
        let candidate = MileageRateEffectiveDate(effectiveDate)
        return schedule.normalizedRules.contains {
            $0.id != edited.id && $0.effectiveFrom == candidate && $0.irsSource == nil
        }
    }

    private var amount: Double? { NumericTextInput.nonnegativeDouble(amountText) }
}
