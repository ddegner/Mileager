import AppCore
import SwiftUI

/// Currency chooser for reimbursement amounts. The rate is user-entered, so
/// picking a currency only changes symbols and formatting — never the numbers.
struct CurrencyPickerView: View {
    let selectedCode: String
    var confirmsChanges = true
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingCode: String?

    var body: some View {
        List {
            Section("Common") {
                ForEach(commonCodes, id: \.self) { code in
                    row(for: code)
                }
            }
            Section("All Currencies") {
                ForEach(allCodes, id: \.self) { code in
                    row(for: code)
                }
            }
        }
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("currencyPickerList")
        .alert("Change Currency?", isPresented: showingCurrencyConfirmation) {
            Button("Change Currency") {
                guard let pendingCode else { return }
                onSelect(pendingCode)
                self.pendingCode = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                pendingCode = nil
            }
        } message: {
            Text("Existing mileage rates and fee amounts will keep their numbers. Review them after changing the currency.")
        }
    }

    private func row(for code: String) -> some View {
        Button {
            guard code != selectedCode else {
                dismiss()
                return
            }
            if confirmsChanges {
                pendingCode = code
            } else {
                onSelect(code)
                dismiss()
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currencyName(for: code))
                        .foregroundStyle(.primary)
                    Text("\(code) · \(CurrencyFormatting.symbol(code: code))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if code == selectedCode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("currencyOption-\(code)")
        .accessibilityAddTraits(code == selectedCode ? [.isSelected] : [])
    }

    private var showingCurrencyConfirmation: Binding<Bool> {
        Binding(
            get: { pendingCode != nil },
            set: { if !$0 { pendingCode = nil } }
        )
    }

    private var commonCodes: [String] {
        CurrencyCatalog.commonCodes(selectedCode: selectedCode)
    }

    private var allCodes: [String] {
        CurrencyCatalog.allCodes()
    }

    private func currencyName(for code: String) -> String {
        CurrencyCatalog.displayName(for: code)
    }
}
