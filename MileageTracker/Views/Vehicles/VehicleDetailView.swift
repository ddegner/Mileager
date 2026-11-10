import AppCore
import SwiftUI

/// The single vehicle setup screen, used in three flows:
/// - `.create` — Settings "Add Vehicle" (toolbar checkmark confirms).
/// - `.edit` — Settings vehicle row (live-saves; adds Connections/Shortcut/Delete).
/// - `.onboarding` — first-run (bottom "Done" confirms, calls `onComplete`).
///
/// Name, appearance, and odometer are identical across all three. The
/// post-creation extras (car connections, Shortcuts setup, and
/// Delete) only appear once the vehicle exists, in edit mode.
struct VehicleDetailView: View {
    enum Mode {
        case create
        case edit(Vehicle)
        case onboarding
    }

    @Environment(MileageAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode
    private let vehicleID: UUID?
    /// Name at the moment the edit screen opened. The save-on-pop below only
    /// renames when the field actually changed from this, so an untouched
    /// dismissal never writes back a stale snapshot (which would revert a
    /// rename that synced in from another device while the screen was open).
    private let originalName: String
    /// Invoked instead of `dismiss()` after a successful create — onboarding uses
    /// it to finish the wizard and close its sheet.
    private let onComplete: (() -> Void)?

    @State private var name: String
    @State private var colorHex: String
    @State private var symbolName: String
    @State private var connectionRows: [VehicleConnectionRow] = []
    /// SwiftUI presents one dialog per view, so the connection actions and the
    /// delete confirmation share a single slot rather than stacking two
    /// `.confirmationDialog` modifiers whose precedence is undefined.
    @State private var pendingConfirmation: PendingConfirmation?
    @State private var didDelete = false
    @State private var odometerText = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var odometerFocused: Bool

    init(mode: Mode, onComplete: (() -> Void)? = nil) {
        self.mode = mode
        self.onComplete = onComplete
        switch mode {
        case .create:
            vehicleID = nil
            originalName = ""
            _name = State(initialValue: "")
            _colorHex = State(initialValue: VehicleAppearance.defaultColorHex)
            _symbolName = State(initialValue: VehicleAppearance.defaultSymbol)
        case .onboarding:
            vehicleID = nil
            originalName = ""
            _name = State(initialValue: String(localized: "My Car"))
            _colorHex = State(initialValue: VehicleAppearance.defaultColorHex)
            _symbolName = State(initialValue: VehicleAppearance.defaultSymbol)
        case let .edit(vehicle):
            vehicleID = vehicle.id
            originalName = vehicle.name
            _name = State(initialValue: vehicle.name)
            _colorHex = State(initialValue: vehicle.colorHex ?? VehicleAppearance.defaultColorHex)
            _symbolName = State(initialValue: vehicle.symbolName ?? VehicleAppearance.defaultSymbol)
        }
    }

    var body: some View {
        Form {
            VehicleSetupSections(
                name: $name,
                colorHex: $colorHex,
                symbolName: $symbolName,
                nameFocus: $nameFocused
            )
            odometerSection
            if vehicleID != nil {
                attributionSection
                if model.platform.capturesDrives {
                    shortcutSection
                }
                if model.vehicles.count > 1 {
                    deleteSection
                }
            }
            if isOnboarding {
                moreVehiclesSection
            }
        }
        .accessibilityIdentifier(isOnboarding ? "onboardingForm" : "vehicleDetailForm")
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
        .toolbar {
            if isCreate {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: createAndComplete,
                        isDisabled: !canConfirm,
                        accessibilityLabel: String(localized: "Add Vehicle"),
                        accessibilityIdentifier: "vehicleAddConfirm"
                    )
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                if odometerFocused {
                    KeyboardActionBar {
                        if isEditing { saveOdometer(to: vehicleID) }
                        odometerFocused = false
                    }
                }
                if isOnboarding {
                    OnboardingPrimaryButton(
                        title: String(localized: "Done"),
                        identifier: "onboardingFinishButton",
                        disabled: !canConfirm,
                        action: createAndComplete
                    )
                }
            }
        }
        .task {
            reloadConnections()
        }
        .onAppear {
            if isCreate { nameFocused = true }
        }
        // Appearance changes persist immediately while editing (the picker only
        // mutates the bindings). A no-op in create/onboarding (no vehicle yet).
        .onChange(of: colorHex) { applyAppearanceIfEditing() }
        .onChange(of: symbolName) { applyAppearanceIfEditing() }
        .onDisappear(perform: persistEditsIfNeeded)
        .confirmationDialog(
            confirmationTitle,
            isPresented: pendingConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { confirmation in
            switch confirmation {
            case let .connection(action):
                Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                    perform(action)
                }
                .accessibilityIdentifier("vehicleConnectionActionConfirm")
            case .delete:
                Button("Remove Vehicle", role: .destructive) {
                    guard let vehicleID else { return }
                    didDelete = true
                    model.deleteVehicle(id: vehicleID)
                    dismiss()
                }
                .accessibilityIdentifier("vehicleDetailDeleteConfirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(message(for: confirmation))
        }
    }

    // MARK: - Sections

    private var odometerSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("Not set", text: $odometerText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($odometerFocused)
                        .accessibilityIdentifier("vehicleOdometerField")
                        .accessibilityValue(odometerText.isEmpty ? String(localized: "Not set") : "\(odometerText) \(distanceUnitSymbol)")
                        .frame(maxWidth: 100)
                    Text(distanceUnitSymbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Current odometer")
            }

            if let vehicleID {
                NavigationLink {
                    OdometerHistoryView(vehicleID: vehicleID)
                } label: {
                    LabeledContent("Odometer History", value: lastReadingText(for: vehicleID))
                }
                .accessibilityIdentifier("vehicleOdometerHistoryLink")
            }
        } header: {
            Text("Odometer")
        } footer: {
            odometerFooter
        }
    }

    @ViewBuilder
    private var odometerFooter: some View {
        if let message = odometerValidationMessage {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("vehicleOdometerValidation")
        } else if let vehicleID, let warning = lowerThanLastWarning(for: vehicleID) {
            Text(warning)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("vehicleOdometerWarning")
        } else if !isEditing {
            Text("Mileager saves this reading to your vehicle and uses occasional readings to estimate total vehicle miles and business-use percentage on reports. You can update it anytime in Settings → Vehicles.")
        }
    }

    private var attributionSection: some View {
        Section {
            if connectionRows.isEmpty {
                Text("No CarPlay or Bluetooth connections are saved for this vehicle yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connectionRows) { row in
                    connectionRow(row)
                }
            }
        } header: {
            Text("Car Connections")
        } footer: {
            Text("Confirmed connection names and vehicle choices sync through iCloud so another iPhone or iPad can suggest the same vehicle. Each iPhone or iPad asks before linking its own CarPlay or Bluetooth connection. Use the options button to move or remove a saved connection.")
        }
    }

    private var shortcutSection: some View {
        Section {
            // The receipt is device-wide; it cannot verify this particular car.
            ShortcutAutomationSetupLink(accessibilityPrefix: "vehicleDetail", showsReceipt: false)
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Remove Vehicle", role: .destructive) {
                pendingConfirmation = .delete
            }
            .accessibilityIdentifier("vehicleDetailDelete")
        }
    }

    private var moreVehiclesSection: some View {
        Section {
            Text("Want to track more than one car? You can add more anytime in Settings → Vehicles.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboardingMoreVehiclesHint")
        }
    }

    // MARK: - Rows

    private func connectionRow(_ row: VehicleConnectionRow) -> some View {
        Menu {
            ForEach(model.vehicles.filter { $0.id != vehicleID }) { vehicle in
                Button {
                    pendingConfirmation = .connection(PendingConnectionAction(row: row, operation: .move(vehicle)))
                } label: {
                    Label("Move to \(vehicle.name)", systemImage: VehicleAppearance.symbol(vehicle.symbolName))
                }
            }

            if model.vehicles.count > 1 {
                Divider()
            }

            Button(role: .destructive) {
                pendingConfirmation = .connection(PendingConnectionAction(row: row, operation: .remove))
            } label: {
                Label("Remove Connection", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.connectionKind.systemImage)
                    .foregroundStyle(MileageTheme.appTint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .foregroundStyle(.primary)
                    Text(row.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Shows options to move or remove this connection")
        .accessibilityIdentifier("vehicleConnectionRow")
    }

    // MARK: - Actions

    private func perform(_ action: PendingConnectionAction) {
        switch action.operation {
        case .remove:
            if let alias = action.row.alias {
                model.removeConnectionAlias(alias)
            } else if let hint = action.row.hint {
                model.clearVehicleConnection(for: hint)
            }
        case .move(let vehicle):
            if let alias = action.row.alias {
                model.reassignConnectionAlias(alias, to: vehicle.id)
            } else if let hint = action.row.hint {
                model.setVehicle(for: hint, vehicleID: vehicle.id)
            }
        }
        reloadConnections()
    }

    /// Creates the vehicle from the current fields, attaches the odometer
    /// reading, and finishes — used by both Settings "Add Vehicle" and onboarding.
    private func createAndComplete() {
        guard canConfirm else { return }
        let vehicle = model.createVehicle(
            name: trimmedName,
            colorHex: colorHex,
            symbolName: symbolName
        )
        saveOdometer(to: vehicle?.id)
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    private func applyAppearanceIfEditing() {
        guard let vehicleID else { return }
        model.updateVehicleAppearance(id: vehicleID, colorHex: colorHex, symbolName: symbolName)
    }

    private func persistEditsIfNeeded() {
        // Dismissal after a delete must not re-save the dead vehicle (it would
        // surface a "Couldn't Save Changes" alert for vehicleNotFound). Only
        // edit mode saves on disappear; create/onboarding save via confirm.
        // Appearance needs no save here — the onChange handlers above persist
        // every color/symbol change the moment it happens.
        guard let vehicleID, isEditing, !didDelete else { return }
        saveOdometer(to: vehicleID)
        if !trimmedName.isEmpty, trimmedName != originalName {
            model.renameVehicle(id: vehicleID, name: trimmedName)
        }
    }

    // MARK: - Odometer

    private var distanceUnitSymbol: String {
        DistanceFormatting.unitSymbol(model.distanceUnit)
    }

    private var odometerValidationMessage: String? {
        let trimmed = odometerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard NumericTextInput.nonnegativeDouble(trimmed) != nil else {
            return String(localized: "Odometer must be 0 or greater.")
        }
        return nil
    }

    private func lastReadingText(for vehicleID: UUID) -> String {
        guard let last = model.latestOdometerCheckpoint(for: vehicleID) else {
            return String(localized: "No readings")
        }
        return "\(readingText(last.odometerMiles)) \(distanceUnitSymbol) · \(Self.readingDateFormatter.string(from: last.date))"
    }

    private func lowerThanLastWarning(for vehicleID: UUID) -> String? {
        guard let entered = NumericTextInput.nonnegativeDouble(odometerText),
              let last = model.latestOdometerCheckpoint(for: vehicleID),
              entered < displayValue(last.odometerMiles) else {
            return nil
        }
        return String(localized: "Lower than your last reading (\(readingText(last.odometerMiles)) \(distanceUnitSymbol) on \(Self.readingDateFormatter.string(from: last.date))). Check for a typo — it will still save.")
    }

    /// Converts a stored odometer value (always miles) into the display unit.
    private func displayValue(_ odometerMiles: Double) -> Double {
        DistanceConversion.value(meters: DistanceConversion.meters(fromMiles: odometerMiles), in: model.distanceUnit)
    }

    private func readingText(_ odometerMiles: Double) -> String {
        OdometerFormatting.readingText(displayValue(odometerMiles))
    }

    /// Saves the buffered reading against `vehicleID` (the current vehicle when
    /// editing, or the freshly created one). No-ops when blank or invalid.
    private func saveOdometer(to vehicleID: UUID?) {
        guard let vehicleID,
              !odometerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entered = NumericTextInput.nonnegativeDouble(odometerText) else {
            return
        }
        // Odometer storage is always miles; entry follows the display unit.
        let meters = DistanceConversion.meters(value: entered, in: model.distanceUnit)
        model.addOdometerCheckpoint(DistanceConversion.miles(fromMeters: meters), vehicleID: vehicleID)
        odometerText = ""
    }

    private static let readingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func reloadConnections() {
        guard let vehicleID else {
            connectionRows = []
            return
        }
        let hints = model.learnedBluetoothDevices.filter { $0.vehicleID == vehicleID }
        let aliases = model.connectionAliases(for: vehicleID)
        var hintsByAliasID: [UUID: BluetoothDriveHint] = [:]
        for hint in hints {
            guard let aliasID = hint.connectionAliasID,
                  hintsByAliasID[aliasID] == nil else { continue }
            hintsByAliasID[aliasID] = hint
        }
        let aliasedHintIDs = Set(hintsByAliasID.values.map(\.id))
        connectionRows = (
            aliases.map { alias in
                VehicleConnectionRow(alias: alias, hint: hintsByAliasID[alias.id])
            }
            + hints.filter { !aliasedHintIDs.contains($0.id) }.map {
                VehicleConnectionRow(alias: nil, hint: $0)
            }
        ).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private var isEditing: Bool { vehicleID != nil }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var isOnboarding: Bool {
        if case .onboarding = mode { return true }
        return false
    }

    /// Create/onboarding confirm gate: a named vehicle and a valid (or blank)
    /// odometer entry.
    private var canConfirm: Bool {
        !trimmedName.isEmpty && odometerValidationMessage == nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayVehicleName: String {
        trimmedName.isEmpty ? originalName : trimmedName
    }

    private var deletePrompt: VehicleRemovalPrompt {
        VehicleRemovalPrompt.make(
            removedVehicleID: vehicleID ?? UUID(),
            removedVehicleName: trimmedName.isEmpty ? originalName : trimmedName,
            vehicles: model.vehicles,
            primaryVehicleID: model.primaryVehicleID
        )
    }

    private var navigationTitle: String {
        switch mode {
        case .create: return String(localized: "New Vehicle")
        case .onboarding: return String(localized: "Your Vehicle")
        case .edit: return trimmedName
        }
    }

    private var pendingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    private var confirmationTitle: String {
        guard let pendingConfirmation else { return "" }
        switch pendingConfirmation {
        case let .connection(action): return action.title
        case .delete: return deletePrompt.title
        }
    }

    private func message(for confirmation: PendingConfirmation) -> String {
        switch confirmation {
        case let .connection(action): action.message(currentVehicleName: displayVehicleName)
        case .delete: deletePrompt.message
        }
    }

    /// The one thing this screen is currently asking the user to confirm.
    private enum PendingConfirmation {
        case connection(PendingConnectionAction)
        case delete
    }

    private struct VehicleConnectionRow: Identifiable {
        var alias: VehicleConnectionAlias?
        var hint: BluetoothDriveHint?

        var id: UUID { alias?.id ?? hint?.id ?? UUID() }

        var displayName: String {
            alias?.displayName
                ?? hint?.displayName
                ?? String(localized: "Unknown Car Connection")
        }

        var connectionKind: VehicleConnectionKind {
            alias?.connectionKind ?? hint?.connectionKind ?? .unknown
        }

        var detailText: String {
            if hint != nil {
                return String(localized: "\(connectionKind.title) · Confirmed on This Device")
            }
            return String(localized: "\(connectionKind.title) · From iCloud")
        }

        var accessibilityLabel: String {
            "\(displayName), \(detailText)"
        }
    }

    private struct PendingConnectionAction: Identifiable {
        enum Operation {
            case remove
            case move(Vehicle)
        }

        let id = UUID()
        var row: VehicleConnectionRow
        var operation: Operation

        var isDestructive: Bool {
            if case .remove = operation { return true }
            return false
        }

        var confirmTitle: String {
            switch operation {
            case .remove:
                String(localized: "Remove Connection")
            case .move(let vehicle):
                String(localized: "Move to \(vehicle.name)")
            }
        }

        var title: String {
            switch operation {
            case .remove:
                String(localized: "Remove \(row.displayName)?")
            case .move(let vehicle):
                String(localized: "Move \(row.displayName) to \(vehicle.name)?")
            }
        }

        func message(currentVehicleName: String) -> String {
            switch operation {
            case .remove:
                String(localized: "This removes the saved connection between \(row.displayName) and this vehicle. Mileager can ask you to assign it again when the connection is detected.")
            case .move(let vehicle):
                String(localized: "Future trips using \(row.displayName) will be assigned to \(vehicle.name) instead of \(currentVehicleName).")
            }
        }
    }
}

private extension VehicleConnectionKind {
    var title: String {
        switch self {
        case .carPlay: String(localized: "CarPlay")
        case .bluetooth: String(localized: "Bluetooth")
        case .unknown: String(localized: "Car connection")
        }
    }

    var systemImage: String {
        switch self {
        case .carPlay: "car.side.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .unknown: "car.fill"
        }
    }
}
