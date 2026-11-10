import SwiftUI

/// The shared "what is this car" setup UI — name plus color/icon appearance —
/// rendered as two `Section`s inside a `Form`. Used by both the Settings vehicle
/// editor (`VehicleDetailView`) and first-run onboarding so the two stay in
/// lockstep. It only mutates the bindings; when and how the values are persisted
/// is the caller's concern.
struct VehicleSetupSections: View {
    @Binding var name: String
    @Binding var colorHex: String
    @Binding var symbolName: String
    var nameFocus: FocusState<Bool>.Binding

    var body: some View {
        Section("Vehicle") {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused(nameFocus)
                .accessibilityIdentifier("vehicleNameField")
                .onSubmit { nameFocus.wrappedValue = false }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a name for this vehicle.")
                    .font(.caption)
                    .foregroundStyle(MileageTheme.personalAccent)
            }
        }

        Section("Appearance") {
            LabeledContent("Icon") {
                HStack(spacing: 14) {
                    ForEach(VehicleAppearance.symbolOptions, id: \.self) { symbol in
                        symbolButton(symbol)
                    }
                }
            }
            LabeledContent("Color") {
                HStack(spacing: 10) {
                    ForEach(VehicleAppearance.colorHexOptions, id: \.self) { hex in
                        swatch(hex)
                    }
                }
            }
        }
    }

    private func swatch(_ hex: String) -> some View {
        Button {
            colorHex = hex
        } label: {
            Circle()
                .fill(Color(vehicleHex: hex) ?? MileageTheme.appTint)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: colorHex == hex ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
    }

    private func symbolButton(_ symbol: String) -> some View {
        Button {
            symbolName = symbol
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(symbolName == symbol ? VehicleAppearance.color(forHex: colorHex) : Color.secondary)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
    }
}
