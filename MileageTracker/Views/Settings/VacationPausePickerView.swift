import SwiftUI

struct VacationPausePickerView: View {
    @Binding var restartDate: Date
    var onConfirm: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Restart date",
                    selection: $restartDate,
                    in: minimumRestartDate...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Restart date")
            .navigationBarTitleDisplayMode(.inline)
            .mileageGroupedBackground(MileageTheme.settingsGroupedBackground)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CheckmarkConfirmationButton(
                        action: {
                            onConfirm(Calendar.current.startOfDay(for: restartDate))
                        },
                        accessibilityLabel: String(localized: "Set")
                    )
                }
            }
        }
    }

    private var minimumRestartDate: Date {
        Calendar.current.startOfDay(for: Date().addingTimeInterval(24 * 60 * 60))
    }
}
