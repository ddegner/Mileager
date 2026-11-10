import AppCore
import SwiftUI

/// A settings-row-style Menu for choosing a trip's vehicle, modeled on
/// `BusinessPurposePicker`'s `.menu` presentation. Renders nothing when no
/// vehicles exist, so call sites don't need their own guards.
struct VehiclePicker: View {
    @Environment(MileageAppModel.self) private var model

    @Binding var selection: UUID?
    var accessibilityIdentifier: String
    var onSelect: ((UUID?) -> Void)?

    init(
        selection: Binding<UUID?>,
        accessibilityIdentifier: String = "tripDetailVehicle",
        onSelect: ((UUID?) -> Void)? = nil
    ) {
        self._selection = selection
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
    }

    var body: some View {
        if model.vehicles.isEmpty {
            EmptyView()
        } else {
            Menu { optionButtons } label: { menuLabel }
                .buttonStyle(.plain)
                .tint(.primary)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityValue(selectedName ?? String(localized: "None"))
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        ForEach(model.vehicles) { vehicle in
            Button {
                apply(vehicle.id)
            } label: {
                if vehicle.id == selection {
                    Label(vehicle.name, systemImage: "checkmark")
                } else {
                    Text(vehicle.name)
                }
            }
        }

        Divider()

        Button {
            apply(nil)
        } label: {
            if selection == nil {
                Label(String(localized: "None"), systemImage: "checkmark")
            } else {
                Text("None")
            }
        }
    }

    private var menuLabel: some View {
        HStack {
            Text("Vehicle")
            Spacer()
            Text(selectedName ?? String(localized: "None"))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private var selectedName: String? {
        guard let selection else { return nil }
        return model.vehicles.first { $0.id == selection }?.name
    }

    private func apply(_ id: UUID?) {
        selection = id
        onSelect?(id)
    }
}
